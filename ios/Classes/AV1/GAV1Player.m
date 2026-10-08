#import "GAV1Player.h"

#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libswscale/swscale.h>
#import <libswresample/swresample.h>

@implementation GAV1Player {
    NSURL *_url;
    NSDictionary *_headers;
    int64_t _length;
    int64_t _position;
    AVFormatContext *_fmt;
    AVIOContext *_pb;
    AVCodecContext *_vdec;
    AVCodecContext *_adec;
    int _vstream;
    int _astream;
    struct SwsContext *_sws;
    SwrContext *_swr;
    CMAudioFormatDescriptionRef _adesc;
}

static NSData *gav1_get(GAV1Player *p, int64_t from, int64_t to) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:p->_url];
    [req setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", from, to] forHTTPHeaderField:@"Range"];
    for (NSString *k in p->_headers) [req setValue:p->_headers[k] forHTTPHeaderField:k];
    __block NSData *out = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        NSArray *range = [http.allHeaderFields[@"Content-Range"] componentsSeparatedByString:@"/"];
        if (range.count == 2) p->_length = [range[1] longLongValue];
        if (!error && (http.statusCode == 200 || http.statusCode == 206)) out = data ?: [NSData data];
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return out;
}

static int gav1_read(void *opaque, uint8_t *buf, int size) {
    GAV1Player *p = (__bridge GAV1Player *)opaque;
    NSData *data = gav1_get(p, p->_position, p->_position + size - 1);
    if (!data) return AVERROR(EIO);
    if (!data.length) return AVERROR_EOF;
    int n = (int)MIN(data.length, (NSUInteger)size);
    memcpy(buf, data.bytes, n);
    p->_position += n;
    return n;
}

static int64_t gav1_seek(void *opaque, int64_t offset, int whence) {
    GAV1Player *p = (__bridge GAV1Player *)opaque;
    if (whence == AVSEEK_SIZE) {
        if (p->_length < 0) gav1_get(p, 0, 0);
        return p->_length;
    }
    if (whence != SEEK_SET) return -1;
    p->_position = offset;
    return offset;
}

static AVCodecContext *gav1_open_codec(AVFormatContext *fmt, int stream, const AVCodec *codec) {
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    ctx->thread_count = 0;
    if (avcodec_parameters_to_context(ctx, fmt->streams[stream]->codecpar) < 0 || avcodec_open2(ctx, codec, NULL) < 0) avcodec_free_context(&ctx);
    return ctx;
}

static CMTime gav1_pts(AVFrame *f, AVStream *s) {
    return CMTimeMake(f->best_effort_timestamp * s->time_base.num, s->time_base.den);
}

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary *)headers {
    if ((self = [super init])) {
        _url = url;
        _headers = headers;
        _length = -1;
    }
    return self;
}

- (BOOL)open {
    if (!_url.isFileURL) {
        _pb = avio_alloc_context(av_malloc(128 * 1024), 128 * 1024, 0, (__bridge void *)self, gav1_read, NULL, gav1_seek);
        _fmt = avformat_alloc_context();
        _fmt->pb = _pb;
    }
    const char *name = _url.isFileURL ? _url.path.UTF8String : _url.absoluteString.UTF8String;
    if (avformat_open_input(&_fmt, name, NULL, NULL) < 0 || avformat_find_stream_info(_fmt, NULL) < 0) return NO;

    const AVCodec *vcodec = NULL, *acodec = NULL;
    _vstream = av_find_best_stream(_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &vcodec, 0);
    if (_vstream < 0 || vcodec->id != AV_CODEC_ID_AV1 || !(_vdec = gav1_open_codec(_fmt, _vstream, vcodec))) return NO;

    _astream = av_find_best_stream(_fmt, AVMEDIA_TYPE_AUDIO, -1, _vstream, &acodec, 0);
    if (_astream >= 0 && (_adec = gav1_open_codec(_fmt, _astream, acodec))) {
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        if (swr_alloc_set_opts2(&_swr, &stereo, AV_SAMPLE_FMT_S16, _adec->sample_rate, &_adec->ch_layout, _adec->sample_fmt, _adec->sample_rate, 0, NULL) < 0 || swr_init(_swr) < 0) {
            swr_free(&_swr);
            avcodec_free_context(&_adec);
            return YES;
        }
        AudioStreamBasicDescription asbd = {_adec->sample_rate, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &_adesc);
    }
    return YES;
}

- (int)videoWidth { return _vdec->width; }
- (int)videoHeight { return _vdec->height; }

- (double)durationSeconds { return _fmt->duration != AV_NOPTS_VALUE ? _fmt->duration / (double)AV_TIME_BASE : 0; }

- (void)seekToTime:(double)seconds {
    int64_t ts = seconds / av_q2d(_fmt->streams[_vstream]->time_base);
    if (avformat_seek_file(_fmt, _vstream, INT64_MIN, ts, ts, AVSEEK_FLAG_BACKWARD) < 0) return;
    avcodec_flush_buffers(_vdec);
    if (_adec) avcodec_flush_buffers(_adec);
}

- (CMSampleBufferRef)videoSampleFromFrame:(AVFrame *)frame {
    if (!_sws) _sws = sws_getContext(frame->width, frame->height, frame->format, frame->width, frame->height, AV_PIX_FMT_NV12, SWS_BILINEAR, NULL, NULL, NULL);
    CVPixelBufferRef px = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    if (!_sws || CVPixelBufferCreate(kCFAllocatorDefault, frame->width, frame->height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)attrs, &px) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(px, 0);
    uint8_t *dst[4] = {CVPixelBufferGetBaseAddressOfPlane(px, 0), CVPixelBufferGetBaseAddressOfPlane(px, 1)};
    int stride[4] = {(int)CVPixelBufferGetBytesPerRowOfPlane(px, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(px, 1)};
    sws_scale(_sws, (const uint8_t * const *)frame->data, frame->linesize, 0, frame->height, dst, stride);
    CVPixelBufferUnlockBaseAddress(px, 0);
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sb = NULL;
    CMSampleTimingInfo timing = {kCMTimeInvalid, gav1_pts(frame, _fmt->streams[_vstream]), kCMTimeInvalid};
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, px, &format);
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, px, format, &timing, &sb);
    CFRelease(format);
    CFRelease(px);
    return sb;
}

- (CMSampleBufferRef)audioSampleFromFrame:(AVFrame *)frame {
    int max = swr_get_out_samples(_swr, frame->nb_samples) + 256;
    uint8_t *pcm = av_malloc(max * 4);
    int got = swr_convert(_swr, &pcm, max, (const uint8_t **)frame->data, frame->nb_samples);
    CMBlockBufferRef block = NULL;
    if (got <= 0 || CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, pcm, got * 4, kCFAllocatorDefault, NULL, 0, got * 4, 0, &block) != noErr) {
        av_free(pcm);
        return NULL;
    }
    CMSampleTimingInfo timing = {CMTimeMake(got, _adec->sample_rate), gav1_pts(frame, _fmt->streams[_astream]), kCMTimeInvalid};
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReady(kCFAllocatorDefault, block, _adesc, got, 1, &timing, 0, NULL, &sb);
    CFRelease(block);
    return sb;
}

- (void)drain:(AVCodecContext *)dec frame:(AVFrame *)frame handler:(void (^)(CMSampleBufferRef, BOOL))handler {
    while (!self.stop && avcodec_receive_frame(dec, frame) >= 0) {
        CMSampleBufferRef sb = dec == _vdec ? [self videoSampleFromFrame:frame] : [self audioSampleFromFrame:frame];
        if (sb) handler(sb, dec == _vdec);
        if (sb) CFRelease(sb);
        av_frame_unref(frame);
    }
}

- (void)decode:(void (^)(CMSampleBufferRef, BOOL))handler completion:(void (^)(NSError *))completion {
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    NSError *err = nil;
    while (!self.stop) {
        int r = av_read_frame(_fmt, pkt);
        if (r < 0 && r != AVERROR_EOF) {
            err = [NSError errorWithDomain:@"GAV1Player" code:r userInfo:nil];
            break;
        }
        AVPacket *p = r < 0 ? NULL : pkt;
        if ((!p || pkt->stream_index == _vstream) && avcodec_send_packet(_vdec, p) >= 0) {
            [self drain:_vdec frame:frame handler:handler];
        }
        if (_adec && (!p || pkt->stream_index == _astream) && avcodec_send_packet(_adec, p) >= 0) {
            [self drain:_adec frame:frame handler:handler];
        }
        av_packet_unref(pkt);
        if (!p) break;
    }
    av_packet_free(&pkt);
    av_frame_free(&frame);
    completion(err);
}

- (void)dealloc {
    sws_freeContext(_sws);
    swr_free(&_swr);
    avcodec_free_context(&_vdec);
    avcodec_free_context(&_adec);
    avformat_close_input(&_fmt);
    if (_pb) av_freep(&_pb->buffer);
    avio_context_free(&_pb);
    if (_adesc) CFRelease(_adesc);
}

@end
