// GAV1Probe.m — AV1 codec probe via libavformat with custom AVIO.
//
// Reads only the container header (open + find_stream_info, no decode).
// Bytes come from NSURLSession (network, honouring caller headers) or from
// a plain file read (local files), fed to libavformat through
// avio_alloc_context. FFmpeg is built --disable-network, so nothing here
// can regress: on any failure we return NO/nil and the caller falls back
// to the native AVPlayer path.

#import "GAV1Probe.h"

#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>

// ---------------------------------------------------------------------------
// Byte source: NSURLSession (network) or NSFileHandle (local file),
// exposed to libavformat as a seekable AVIOContext.
// ---------------------------------------------------------------------------

typedef struct {
    // network
    NSURLSession *session;
    NSURL *url;
    NSDictionary *headers;
    int64_t length;      // -1 if unknown
    int64_t position;
    // local
    NSFileHandle *file;
    int64_t fileLength;
    BOOL isLocal;
    uint8_t *tmp;
} GAV1IO;

static int gav1_read(void *opaque, uint8_t *buf, int buf_size) {
    GAV1IO *io = (GAV1IO *)opaque;
    if (io->isLocal) {
        @try {
            [io->file seekToFileOffset:(unsigned long long)io->position];
            NSData *d = [io->file readDataOfLength:(NSUInteger)buf_size];
            if (d.length == 0) return AVERROR_EOF;
            memcpy(buf, d.bytes, d.length);
            io->position += d.length;
            return (int)d.length;
        } @catch (NSException *e) {
            return AVERROR(EIO);
        }
    }
    // Network: single Range request per read. Probing only touches the head
    // of the file, so this performs a handful of small requests.
    NSString *range = [NSString stringWithFormat:@"bytes=%lld-%lld",
                       (long long)io->position, (long long)(io->position + buf_size - 1)];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:io->url];
    [req setValue:range forHTTPHeaderField:@"Range"];
    for (NSString *k in io->headers) {
        [req setValue:io->headers[k] forHTTPHeaderField:k];
    }
    __block NSData *out = nil;
    __block NSError *err = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [io->session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
            out = data; err = e;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                status = ((NSHTTPURLResponse *)resp).statusCode;
                // Capture total length for seeking.
                NSString *cr = ((NSHTTPURLResponse *)resp).allHeaderFields[@"Content-Range"];
                if (cr) {
                    NSArray *parts = [cr componentsSeparatedByString:@"/"];
                    if (parts.count == 2) io->length = [parts[1] longLongValue];
                } else {
                    NSString *cl = ((NSHTTPURLResponse *)resp).allHeaderFields[@"Content-Length"];
                    if (cl && io->position == 0) io->length = [cl longLongValue];
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

static int64_t gav1_seek(void *opaque, int64_t offset, int whence) {
    GAV1IO *io = (GAV1IO *)opaque;
    if (whence == AVSEEK_SIZE) {
        if (io->isLocal) return io->fileLength;
        // Trigger a 0-byte range request to learn the length.
        if (io->length < 0) {
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:io->url];
            [req setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
            for (NSString *k in io->headers) {
                [req setValue:io->headers[k] forHTTPHeaderField:k];
            }
            __block int64_t len = -1;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            NSURLSessionDataTask *task = [io->session dataTaskWithRequest:req
                completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                    if ([r isKindOfClass:[NSHTTPURLResponse class]]) {
                        NSString *cr = ((NSHTTPURLResponse *)r).allHeaderFields[@"Content-Range"];
                        NSArray *parts = [cr componentsSeparatedByString:@"/"];
                        if (parts.count == 2) len = [parts[1] longLongValue];
                    }
                    dispatch_semaphore_signal(sem);
                }];
            [task resume];
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
    if (pos < 0) return -1;
    if (base >= 0 && pos > base) return -1;
    io->position = pos;
    return pos;
}

// Open an AVFormatContext over our byte source. Caller must
// avformat_close_input() it. Returns NULL on any error.
static AVFormatContext *gav1_open(NSURL *url, NSDictionary *headers) {
    GAV1IO *io = calloc(1, sizeof(GAV1IO));
    if (!io) return NULL;
    io->length = -1;

    if (url.isFileURL) {
        NSFileHandle *fh = nil;
        @try {
            fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
        } @catch (NSException *e) { fh = nil; }
        if (!fh) { free(io); return NULL; }
        unsigned long long len = [fh seekToEndOfFile];
        [fh seekToFileOffset:0];
        io->isLocal = YES;
        io->file = fh;
        io->fileLength = (int64_t)len;
        io->position = 0;
    } else {
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 15;
        cfg.timeoutIntervalForResource = 30;
        io->session = [NSURLSession sessionWithConfiguration:cfg];
        io->url = url;
        io->headers = headers ?: @{};
        io->position = 0;
    }

    const int avioSize = 64 * 1024;
    uint8_t *avioBuf = av_malloc(avioSize);
    if (!avioBuf) {
        if (io->isLocal) [io->file closeFile]; else [io->session invalidateAndCancel];
        free(io);
        return NULL;
    }
    AVIOContext *avio = avio_alloc_context(
        avioBuf, avioSize, 0 /* write_flag */, io, gav1_read, NULL, gav1_seek);
    if (!avio) {
        av_free(avioBuf);
        if (io->isLocal) [io->file closeFile]; else [io->session invalidateAndCancel];
        free(io);
        return NULL;
    }

    AVFormatContext *fmt = avformat_alloc_context();
    if (!fmt) {
        avio_context_free(&avio); // frees buffer + calls nothing on opaque
        if (io->isLocal) [io->file closeFile]; else [io->session invalidateAndCancel];
        free(io);
        return NULL;
    }
    fmt->pb = avio;
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;

    // Only the codecs we ship decoders for are probed.
    const char *fname = url.isFileURL ? url.path.UTF8String : url.absoluteString.UTF8String;
    if (avformat_open_input(&fmt, fname, NULL, NULL) < 0) {
        avformat_free_context(fmt);
        avio_context_free(&avio);
        if (io->isLocal) [io->file closeFile]; else [io->session invalidateAndCancel];
        free(io);
        return NULL;
    }
    // Stash the byte source on the context so close can release it.
    fmt->opaque = io;

    if (avformat_find_stream_info(fmt, NULL) < 0) {
        GAV1IO *rel = fmt->opaque;
        AVIOContext *pb = fmt->pb;
        avformat_close_input(&fmt);
        avio_context_free(&pb);
        if (rel) {
            if (rel->isLocal) [rel->file closeFile]; else [rel->session invalidateAndCancel];
            free(rel);
        }
        return NULL;
    }
    return fmt;
}

static void gav1_close(AVFormatContext *fmt) {
    if (!fmt) return;
    GAV1IO *io = fmt->opaque;
    AVIOContext *pb = fmt->pb;
    fmt->pb = NULL;
    fmt->opaque = NULL;
    avformat_close_input(&fmt);
    avio_context_free(&pb);
    if (io) {
        if (io->isLocal) [io->file closeFile]; else [io->session invalidateAndCancel];
        free(io);
    }
}

static int gav1_video_stream(AVFormatContext *fmt) {
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        if (fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) return (int)i;
    }
    return -1;
}

@implementation GAV1Probe

+ (BOOL)isAV1AtURL:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers {
    if (!url) return NO;
    AVFormatContext *fmt = gav1_open(url, headers);
    if (!fmt) return NO;
    int vi = gav1_video_stream(fmt);
    BOOL av1 = vi >= 0 && fmt->streams[vi]->codecpar->codec_id == AV_CODEC_ID_AV1;
    gav1_close(fmt);
    return av1;
}

+ (NSDictionary *)videoInfoAtURL:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers {
    if (!url) return nil;
    AVFormatContext *fmt = gav1_open(url, headers);
    if (!fmt) return nil;
    int vi = gav1_video_stream(fmt);
    NSDictionary *out = nil;
    if (vi >= 0) {
        AVCodecParameters *par = fmt->streams[vi]->codecpar;
        AVRational tb = fmt->streams[vi]->time_base;
        double dur = 0;
        if (fmt->streams[vi]->duration != AV_NOPTS_VALUE && tb.den) {
            dur = fmt->streams[vi]->duration * av_q2d(tb);
        } else if (fmt->duration != AV_NOPTS_VALUE) {
            dur = fmt->duration / (double)AV_TIME_BASE;
        }
        double fps = 0;
        AVRational fr = fmt->streams[vi]->avg_frame_rate;
        if (fr.den) fps = av_q2d(fr);
        out = @{
            @"width": @(par->width),
            @"height": @(par->height),
            @"durationMs": @((long long)(dur * 1000.0)),
            @"fps": @(fps),
            @"codecId": @(par->codec_id),
        };
    }
    gav1_close(fmt);
    return out;
}

@end
