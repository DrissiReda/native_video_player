// GAV1FileLog.h — append-only on-device debug log for the AV1 software path.
//
// The phone has no USB/Mac attached, so NSLog is invisible. This writes the
// same diagnostics to Documents/av1debug.log, which the user can pull out of
// the app via the Files app (UIFileSharingEnabled) or Filza and send back.
// ADDITIVE: no effect on playback; tiny bounded file.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GAV1FileLog : NSObject
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
/// Absolute path of the log file (for "reveal in Files" UI, if ever needed).
+ (NSString *)logPath;
+ (void)line:(NSString *)line;
@end

NS_ASSUME_NONNULL_END
