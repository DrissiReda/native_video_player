// GAV1Player.h — AV1 (+AAC/Opus) software decode engine.
//
// ADDITIVE file: used only for sources the native AVPlayer cannot decode
// (AV1 without hardware support). All other formats keep using AVPlayer,
// untouched.
//
// Threading: the caller runs -decodeWithVideo:audio:completion: on a
// background thread; handlers are invoked on that same thread. Call
// -requestStop from any thread to interrupt.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Called for each decoded video frame. `stop` may be set to YES to end
/// decoding early (seek, teardown).
typedef void (^GAV1VideoFrameHandler)(CVPixelBufferRef _Nullable pixelBuffer,
                                      CMTime pts, BOOL * _Nonnull stop);
/// Called for each decoded audio buffer (PCM in a CMSampleBuffer).
typedef void (^GAV1AudioFrameHandler)(CMSampleBufferRef _Nullable sampleBuffer,
                                      BOOL * _Nonnull stop);

@interface GAV1Player : NSObject

- (nullable instancetype)initWithURL:(NSURL *)url
                             headers:(nullable NSDictionary<NSString *, NSString *> *)headers;

/// Opens the container and the video (+audio, if present) decoders.
/// Only AV1 video is accepted here; anything else returns NO so the caller
/// falls back to the native player. (The probe normally guarantees AV1.)
- (BOOL)open:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) int videoWidth;
@property (nonatomic, readonly) int videoHeight;
@property (nonatomic, readonly) double durationSeconds;
@property (nonatomic, readonly) double fps;
@property (nonatomic, readonly) BOOL hasAudio;

/// Seek to `seconds` (flushes decoders, seeks to the nearest keyframe at or
/// before the target). Returns NO on failure.
- (BOOL)seekToTime:(double)seconds;

/// Decode from the current position until EOF, error, or -requestStop.
/// `completion` is always invoked exactly once. Blocking call.
- (void)decodeWithVideo:(GAV1VideoFrameHandler)videoHandler
                  audio:(GAV1AudioFrameHandler)audioHandler
             completion:(void (^)(NSError * _Nullable error))completion;

- (void)requestStop;
- (void)close;

@end

NS_ASSUME_NONNULL_END
