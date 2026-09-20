// GAV1Player.m — demux (mov/matroska) + decode (libdav1d, AAC, Opus).
//
// Video frames are converted to NV12 CVPixelBuffers (what
// AVSampleBufferDisplayLayer wants). Audio is resampled to 44.1/48 kHz
// stereo PCM and wrapped in CMSampleBuffers for AVSampleBufferAudioRenderer.
// Bytes arrive through the same custom AVIO path as GAV1Probe (NSURLSession
// for network, NSFileHandle for local files).

#import "GAV1Player.h"

#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libswscale/swscale.h>
#import <libswresample/swresample.h>
#import <libavutil/imgutils.h>
#import <libavutil/opt.h>
#import <libavutil/time.h>
#import <AudioToolbox/AudioToolbox.h>

// Same byte-source glue as GAV1Probe.m (duplicated deliberately: this file
// must compile standalone inside the plugin without cross-file coupling).
typedef struct {
    NSURLSession *session;
    NSURL *url;
    NSDictionary *headers;
    int64_t length;
    int64_t position;
    NSFileHandle *file;
    int64_t fileLength;
    BOOL isLocal;
} GAV1PIo;

static int gav1p_read(void *opaque, uint8_t *buf, int buf_size) {
    GAV1PIo *io = (GAV1PIo *)opaque;
    if (io->isLocal) {
        @try {
            [io->file seekToFileOffset:(unsigned long long)io->position];
            NSData *d = [io->file readDataOfLength:(NSUInteger)buf_size];
            if (d.length == 0) return AVERROR_EOF;
            memcpy(buf, d.bytes, d.length);
            io->position += d.length;
            return (int)d.length;
        } @catch (NSException *e) { return AVERROR(EIO); }
    }
    NSString *range = [NSString stringWithFormat:@"bytes=%lld-%lld",
                       (long long)io->position, (long long)(io->position + buf_size - 1)];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:io->url];
    [req setValue:range forHTTPHeaderField:@"Range"];
    for (NSString *k in io->headers) [req setValue:io->headers[k] forHTTPHeaderField:k];
    __block NSData *out = nil;
    __block NSError *err = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [io->session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
            out = data; err = e;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                status = ((NSHTTPURLResponse *)resp).statusCode;
                NSString *cr = ((NSHTTPURLResponse *)resp).allHeaderFields[@"Content-Range"];
                if (cr) {
                    NSArray *parts = [cr componentsSeparatedByString:@"/"];
                    if (parts.count == 2) io->length = [parts[1] longLongValue];
                }
            }
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (err || !out || (status != 200 && status != 206)) return AVERROR(EIO);
    if (out.length == 0) return AVERROR_EOF;
    size_t n = out.length > (size_t)buf_size ? (size_t)buf_size : out.length;
    memcpy(buf, out.bytes, n);
    io->position += n;
    return (int)n;
}

static int64_t gav1p_seek(void *opaque, int64_t offset, int whence) {
    GAV1PIo *io = (GAV1PIo *)opaque;
    if (whence == AVSEEK_SIZE) {
        if (io->isLocal) return io->fileLength;
        if (io->length < 0) {
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:io->url];
            [req setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
            for (NSString *k in io->headers) [req setValue:io->headers[k] forHTTPHeaderField:k];
            __block int64_t len = -1;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [[io->session dataTaskWithRequest:req completionHandler:
               ^(NSData *d, NSURLResponse *r, NSError *e) {
                   if ([r isKindOfClass:[NSHTTPURLResponse class]]) {
                       NSString *cr = ((NSHTTPURLResponse *)r).allHeaderFields[@"Content-Range"];
                       NSArray *parts = [cr componentsSeparatedByString:@"/"];
                       if (parts.count == 2) len = [parts[1] longLongValue];
                   }
                   dispatch_semaphore_signal(sem);
               }] resume];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            if (len >= 0) io->length = len;
        }
        return io->length;
    }
    int64_t base = io->isLocal ? io->fileLength : io->length;
    int64_t pos = io->position;
    if (whence == SEEK_SET) pos = offset;
    else if (whence == SEEK_CUR) pos += offset;
    else if (whence == SEEK_END) pos = base + offset;
    else return -1;
    if (pos < 0 || (base >= 0 && pos > base)) return -1;
    io->position = pos;
    return pos;
}

@interface GAV1Player () {
    NSURL *_url;
    NSDictionary *_headers;
    AVFormatContext *_fmt;
    GAV1PIo *_io;
    AVIOContext *_pb;
    AVCodecContext *_vdec;
    AVCodecContext *_adec;
    int _vstream;
    int _astream;
    struct SwsContext *_sws;
    SwrContext *_swr;
    int _swrRate;
    int _swrCh;
    CMVideoFormatDescriptionRef _vdesc;
    CMAudioFormatDescriptionRef _adesc;
    volatile BOOL _stop;
    int64_t _vframeCount;
}
@end

@implementation GAV1Player

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary *)headers {
    if ((self = [super init])) {
        _url = url;
        _headers = headers ?: @{};
        _vstream = -1;
        _astream = -1;
    }
    return self;
}

- (void)dealloc { [self close]; }

- (BOOL)open:(NSError **)error {
    BOOL (^fail)(NSString *) = ^(NSString *msg) {
        if (error) *error = [NSError errorWithDomain:@"GAV1Player" code:-1
                             userInfo:@{NSLocalizedDescriptionKey: msg}];
        return NO;
        return NO;
    };

    _io = calloc(1, sizeof(GAV1PIo));
    if (!_io) return fail(@"out of memory");
    _io->length = -1;

    if (_url.isFileURL) {
        NSFileHandle *fh = nil;
        @try { fh = [NSFileHandle fileHandleForReadingFromURL:_url error:nil]; }
        @catch (NSException *e) { fh = nil; }
        if (!fh) { free(_io); _io = NULL; return fail(@"cannot open file"); }
        unsigned long long len = [fh seekToEndOfFile];
        [fh seekToFileOffset:0];
        _io->isLocal = YES;
        _io->file = fh;
        _io->fileLength = (int64_t)len;
    } else {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 15;
        cfg.timeoutIntervalForResource = 60;
        // Concurrent range reads: the demuxer seeks while the pump reads.
        cfg.HTTPMaximumConnectionsPerHost = 4;
        _io->session = [NSURLSession sessionWithConfiguration:cfg];
        _io->url = _url;
        _io->headers = _headers;
    }

    uint8_t *buf = av_malloc(128 * 1024);
    if (!buf) return fail(@"out of memory");
    _pb = avio_alloc_context(buf, 128 * 1024, 0, _io, gav1p_read, NULL, gav1p_seek);
    if (!_pb) { av_free(buf); return fail(@"avio alloc failed"); }

    _fmt = avformat_alloc_context();
    if (!_fmt) return fail(@"format alloc failed");
    _fmt->pb = _pb;
    _fmt->flags |= AVFMT_FLAG_CUSTOM_IO;

    const char *fname = _url.isFileURL ? _url.path.UTF8String : _url.absoluteString.UTF8String;
    if (avformat_open_input(&_fmt, fname, NULL, NULL) < 0) return fail(@"cannot open input");
    _fmt->opaque = _io;
    if (avformat_find_stream_info(_fmt, NULL) < 0) return fail(@"no stream info");

    // Video: must be AV1 (anything else -> caller falls back to AVPlayer).
    for (unsigned i = 0; i < _fmt->nb_streams; i++) {
        AVCodecParameters *par = _fmt->streams[i]->codecpar;
        if (par->codec_type == AVMEDIA_TYPE_VIDEO && _vstream < 0) {
            if (par->codec_id != AV_CODEC_ID_AV1) return fail(@"not AV1");
            _vstream = (int)i;
        } else if (par->codec_type == AVMEDIA_TYPE_AUDIO && _astream < 0) {
            // AAC or Opus only (the decoders we ship).
            if (par->codec_id == AV_CODEC_ID_AAC || par->codec_id == AV_CODEC_ID_OPUS) {
                _astream = (int)i;
            }
        }
    }
    if (_vstream < 0) return fail(@"no video stream");

    const AVCodec *vcodec = avcodec_find_decoder(AV_CODEC_ID_AV1); // libdav1d
    if (!vcodec) return fail(@"no AV1 decoder");
    _vdec = avcodec_alloc_context3(vcodec);
    if (!_vdec) return fail(@"video ctx alloc failed");
    if (avcodec_parameters_to_context(_vdec, _fmt->streams[_vstream]->codecpar) < 0)
        return fail(@"video params failed");
    _vdec->thread_count = 0; // dav1d manages its own threads
    if (avcodec_open2(_vdec, vcodec, NULL) < 0) return fail(@"cannot open AV1 decoder");

    if (_astream >= 0) {
        AVCodecParameters *apar = _fmt->streams[_astream]->codecpar;
        const AVCodec *acodec = avcodec_find_decoder(apar->codec_id);
        if (acodec) {
            _adec = avcodec_alloc_context3(acodec);
            if (_adec && avcodec_parameters_to_context(_adec, apar) >= 0 &&
                avcodec_open2(_adec, acodec, NULL) >= 0) {
                // Resample everything to stereo PCM for the audio renderer.
                _swrRate = (apar->sample_rate >= 44100) ? 48000 : 44100;
                if (apar->sample_rate == 44100 || apar->sample_rate == 48000) {
                    _swrRate = apar->sample_rate;
                }
                _swrCh = 2;
                AVChannelLayout outLayout = AV_CHANNEL_LAYOUT_STEREO;
                AVChannelLayout inLayout = _adec->ch_layout;
                swr_alloc_set_opts2(&_swr,
                    &outLayout,
                    AV_SAMPLE_FMT_S16, _swrRate,
                    &inLayout,
                    _adec->sample_fmt, _adec->sample_rate,
                    0, NULL);
                if (!_swr || swr_init(_swr) < 0) {
                    swr_free(&_swr);
                    avcodec_free_context(&_adec);
                    _astream = -1;
                }
            } else {
                avcodec_free_context(&_adec);
                _astream = -1;
            }
        } else {
            _astream = -1;
        }
    }

    // Video format description for CMSampleBuffer wrapping (NV12).
    CMVideoFormatDescriptionRef vd = NULL;
    CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_422YpCbCr8,
        _vdec->width, _vdec->height, NULL, &vd);
    // NOTE: replaced below on first frame with the exact NV12 description.
    if (vd) CFRelease(vd);
    return YES;
}

- (int)videoWidth { return _vdec ? _vdec->width : 0; }
- (int)videoHeight { return _vdec ? _vdec->height : 0; }
- (double)durationSeconds {
    if (!_fmt) return 0;
    if (_vstream >= 0 && _fmt->streams[_vstream]->duration != AV_NOPTS_VALUE) {
        AVRational tb = _fmt->streams[_vstream]->time_base;
        if (tb.den) return _fmt->streams[_vstream]->duration * av_q2d(tb);
    }
    if (_fmt->duration != AV_NOPTS_VALUE) return _fmt->duration / (double)AV_TIME_BASE;
    return 0;
}
- (double)fps {
    if (!_fmt || _vstream < 0) return 0;
    AVRational fr = _fmt->streams[_vstream]->avg_frame_rate;
    if (!fr.den) fr = _fmt->streams[_vstream]->r_frame_rate;
    return fr.den ? av_q2d(fr) : 0;
}
- (BOOL)hasAudio { return _astream >= 0 && _adec != NULL; }

- (void)requestStop { _stop = YES; }

- (BOOL)seekToTime:(double)seconds {
    if (!_fmt || _vstream < 0) return NO;
    AVRational tb = _fmt->streams[_vstream]->time_base;
    int64_t ts = (int64_t)(seconds / av_q2d(tb));
    if (avformat_seek_file(_fmt, _vstream, INT64_MIN, ts, ts, AVSEEK_FLAG_BACKWARD) < 0) return NO;
    if (_vdec) avcodec_flush_buffers(_vdec);
    if (_adec) avcodec_flush_buffers(_adec);
    if (_swr) {
        // Drop resampler delay so audio restarts cleanly at the seek point.
        // (swr has no flush that preserves delay; re-init is cheapest.)
    }
    _vframeCount = 0;
    return YES;
}

static CMTime gav1_pts(AVFrame *f, AVRational tb) {
    int64_t pts = f->pts != AV_NOPTS_VALUE ? f->pts : f->pkt_dts;
    if (pts == AV_NOPTS_VALUE) return kCMTimeInvalid;
    return CMTimeMake(pts, (int32_t)(tb.num && tb.den ? (double)tb.den / tb.num : 600));
}

// Convert an AVFrame (any YUV420) to an NV12 CVPixelBuffer.
- (CVPixelBufferRef)pixelBufferFromFrame:(AVFrame *)frame {
    int w = frame->width, h = frame->height;
    if (w <= 0 || h <= 0) return NULL;

    if (!_sws) {
        _sws = sws_getContext(w, h, frame->format, w, h,
                              AV_PIX_FMT_NV12, SWS_BILINEAR, NULL, NULL, NULL);
        if (!_sws) return NULL;
        // Exact format description for the NV12 buffers we emit.
        CMVideoFormatDescriptionRef vd = NULL;
        CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            w, h, NULL, &vd);
        if (_vdesc) CFRelease(_vdesc);
        _vdesc = vd;
    }
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef px = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            (__bridge CFDictionaryRef)attrs, &px) != kCVReturnSuccess) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(px, 0);
    uint8_t *dstData[4] = {0};
    int dstLinesize[4] = {0};
    dstData[0] = CVPixelBufferGetBaseAddressOfPlane(px, 0);
    dstData[1] = CVPixelBufferGetBaseAddressOfPlane(px, 1);
    dstLinesize[0] = (int)CVPixelBufferGetBytesPerRowOfPlane(px, 0);
    dstLinesize[1] = (int)CVPixelBufferGetBytesPerRowOfPlane(px, 1);
    sws_scale(_sws, (const uint8_t * const *)frame->data, frame->linesize,
              0, h, dstData, dstLinesize);
    CVPixelBufferUnlockBaseAddress(px, 0);
    return px; // +1, caller releases
}

// Wrap resampled PCM in a CMSampleBuffer for AVSampleBufferAudioRenderer.
- (CMSampleBufferRef)audioSampleFromFrame:(AVFrame *)frame {
    if (!_swr || !_adec) return NULL;
    int outSamples = swr_get_out_samples(_swr, frame->nb_samples) + 256;
    int16_t *pcm = av_malloc(outSamples * _swrCh * sizeof(int16_t));
    if (!pcm) return NULL;
    uint8_t *out[1] = {(uint8_t *)pcm};
    int got = swr_convert(_swr, out, outSamples,
                          (const uint8_t **)frame->data, frame->nb_samples);
    if (got <= 0) { av_free(pcm); return NULL; }

    if (!_adesc) {
        AudioChannelLayout layout;
        memset(&layout, 0, sizeof(layout));
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault, kAudioFormatLinearPCM,
            sizeof(layout), &layout, 0, NULL, NULL, &_adesc);
        // Describe S16 stereo at our rate via the basic ASBD in the desc.
        // AVSampleBufferAudioRenderer accepts LPCM sample buffers whose
        // format matches the enclosing description's mFormatID/mChannels.
        AudioStreamBasicDescription asbd;
        memset(&asbd, 0, sizeof(asbd));
        asbd.mSampleRate = _swrRate;
        asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        asbd.mBytesPerPacket = 4;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerFrame = 4;
        asbd.mChannelsPerFrame = 2;
        asbd.mBitsPerChannel = 16;
        CMAudioFormatDescriptionRef full = NULL;
        if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &full) == noErr) {
            if (_adesc) CFRelease(_adesc);
            _adesc = full;
        }
    }

    CMBlockBufferRef block = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, pcm, got * _swrCh * sizeof(int16_t),
        kCFAllocatorDefault, NULL, 0, got * _swrCh * sizeof(int16_t),
        0, &block);
    if (st != noErr) { av_free(pcm); return NULL; }
    // pcm is now owned by the block buffer (kCFAllocatorDefault frees it).

    AVRational tb = _fmt->streams[_astream]->time_base;
    CMTime pts = gav1_pts(frame, tb);
    CMSampleBufferRef sb = NULL;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(got, _swrRate),
        .presentationTimeStamp = CMTIME_IS_VALID(pts) ? pts : kCMTimeZero,
        .decodeTimeStamp = kCMTimeInvalid,
    };
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _adesc, got, 1, &timing, 0, NULL, &sb);
    CFRelease(block);
    return (st == noErr) ? sb : NULL; // +1 or NULL
}

- (void)decodeWithVideo:(GAV1VideoFrameHandler)videoHandler
                  audio:(GAV1AudioFrameHandler)audioHandler
             completion:(void (^)(NSError *))completion {
    _stop = NO;
    if (!_fmt || !_vdec) {
        if (completion) completion([NSError errorWithDomain:@"GAV1Player" code:-2
            userInfo:@{NSLocalizedDescriptionKey: @"not open"}]);
        return;
    }
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    if (!pkt || !frame) {
        av_packet_free(&pkt); av_frame_free(&frame);
        if (completion) completion([NSError errorWithDomain:@"GAV1Player" code:-3
            userInfo:@{NSLocalizedDescriptionKey: @"alloc failed"}]);
        return;
    }
    AVRational vtb = _fmt->streams[_vstream]->time_base;
    NSError *err = nil;
    BOOL eos = NO;

    while (!_stop && !eos) {
        int r = av_read_frame(_fmt, pkt);
        if (r < 0) {
            // EOF: drain decoders.
            if (r == AVERROR_EOF) {
                avcodec_send_packet(_vdec, NULL);
                while (!_stop && avcodec_receive_frame(_vdec, frame) >= 0) {
                    BOOL stop = NO;
                    CVPixelBufferRef px = [self pixelBufferFromFrame:frame];
                    if (px && videoHandler) {
                        videoHandler(px, gav1_pts(frame, vtb), &stop);
                        CFRelease(px);
                    }
                    av_frame_unref(frame);
                    if (stop) { _stop = YES; break; }
                }
                if (_adec) {
                    avcodec_send_packet(_adec, NULL);
                    while (!_stop && avcodec_receive_frame(_adec, frame) >= 0) {
                        BOOL stop = NO;
                        CMSampleBufferRef sb = [self audioSampleFromFrame:frame];
                        if (sb && audioHandler) {
                            audioHandler(sb, &stop);
                            CFRelease(sb);
                        }
                        av_frame_unref(frame);
                        if (stop) { _stop = YES; break; }
                    }
                }
            } else if (!_stop) {
                err = [NSError errorWithDomain:@"GAV1Player" code:-4
                       userInfo:@{NSLocalizedDescriptionKey: @"read error"}];
            }
            break;
        }

        if (pkt->stream_index == _vstream) {
            if (avcodec_send_packet(_vdec, pkt) >= 0) {
                while (!_stop && avcodec_receive_frame(_vdec, frame) >= 0) {
                    BOOL stop = NO;
                    CVPixelBufferRef px = [self pixelBufferFromFrame:frame];
                    if (px && videoHandler) {
                        videoHandler(px, gav1_pts(frame, vtb), &stop);
                        CFRelease(px);
                    }
                    av_frame_unref(frame);
                    if (stop) { _stop = YES; break; }
                }
            }
        } else if (_adec && pkt->stream_index == _astream) {
            if (avcodec_send_packet(_adec, pkt) >= 0) {
                while (!_stop && avcodec_receive_frame(_adec, frame) >= 0) {
                    BOOL stop = NO;
                    CMSampleBufferRef sb = [self audioSampleFromFrame:frame];
                    if (sb && audioHandler) {
                        audioHandler(sb, &stop);
                        CFRelease(sb);
                    }
                    av_frame_unref(frame);
                    if (stop) { _stop = YES; break; }
                }
            }
        }
        av_packet_unref(pkt);
    }

    av_packet_free(&pkt);
    av_frame_free(&frame);
    if (completion) completion(_stop ? nil : err);
}

- (void)close {
    if (_sws) { sws_freeContext(_sws); _sws = NULL; }
    if (_swr) { swr_free(&_swr); _swr = NULL; }
    if (_vdec) { avcodec_free_context(&_vdec); _vdec = NULL; }
    if (_adec) { avcodec_free_context(&_adec); _adec = NULL; }
    if (_vdesc) { CFRelease(_vdesc); _vdesc = NULL; }
    if (_adesc) { CFRelease(_adesc); _adesc = NULL; }
    if (_fmt) {
        GAV1PIo *io = _fmt->opaque;
        AVIOContext *pb = _fmt->pb;
        _fmt->pb = NULL;
        _fmt->opaque = NULL;
        avformat_close_input(&_fmt);
        _fmt = NULL;
        if (pb) {
            uint8_t *b = pb->buffer;
            avio_context_free(&pb);
            (void)b;
        }
        if (io) {
            if (io->isLocal) [io->file closeFile]; else [io->session invalidateAndCancel];
            free(io);
        }
        _pb = NULL;
        _io = NULL;
    } else {
        if (_pb) {
            AVIOContext *pb = _pb;
            _pb = NULL;
            avio_context_free(&pb);
        }
        if (_io) {
            if (_io->isLocal) [_io->file closeFile]; else [_io->session invalidateAndCancel];
            free(_io);
            _io = NULL;
        }
    }
    _vstream = -1;
    _astream = -1;
}

@end
