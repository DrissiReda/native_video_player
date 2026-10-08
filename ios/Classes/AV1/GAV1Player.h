#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface GAV1Player : NSObject

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers;
- (BOOL)open;
- (void)seekToTime:(double)seconds;
- (void)decode:(void (^)(CMSampleBufferRef sample, BOOL video))handler completion:(void (^)(NSError * _Nullable error))completion;

@property (atomic) BOOL stop;
@property (nonatomic, readonly) int videoWidth;
@property (nonatomic, readonly) int videoHeight;
@property (nonatomic, readonly) double durationSeconds;

@end

NS_ASSUME_NONNULL_END
