// GAV1Probe.h — minimal AV1 codec probe backed by libavformat.
//
// ADDITIVE file: used only to decide whether a source needs the software
// AV1 path. Never touches the AVPlayer pipeline.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GAV1Probe : NSObject

/// Returns YES if the video stream at `url` is AV1.
/// `url` may be a file URL or an http(s) URL (bytes are fetched through
/// NSURLSession with the given headers; FFmpeg itself is built without
/// network protocols). Returns NO on any error — callers treat "unknown"
/// as "not AV1" and use the native player, so probing can never regress
/// existing formats.
+ (BOOL)isAV1AtURL:(NSURL *)url headers:(nullable NSDictionary<NSString *, NSString *> *)headers;

/// Video stream metadata for a source. Populated on success, nil otherwise.
+ (nullable NSDictionary *)videoInfoAtURL:(NSURL *)url headers:(nullable NSDictionary<NSString *, NSString *> *)headers;

@end

NS_ASSUME_NONNULL_END
