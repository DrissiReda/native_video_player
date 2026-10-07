#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface GAV1Player : NSObject

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers;
- (BOOL)open;
- (void)seekToTime:(double)seconds;
- (void)decodeWithVideo:(void (^)(CVPixelBufferRef pixelBuffer, CMTime pts, BOOL *stop))videoHandler
                  audio:(void (^)(CMSampleBufferRef sampleBuffer, BOOL *stop))audioHandler
             completion:(void (^)(NSError * _Nullable error))completion;
- (void)requestStop;

@property (nonatomic, readonly) int videoWidth;
@property (nonatomic, readonly) int videoHeight;
@property (nonatomic, readonly) double durationSeconds;
@property (nonatomic, readonly) BOOL hasAudio;

@end

NS_ASSUME_NONNULL_END
