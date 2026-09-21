// GAV1FileLog.m — see header. Truncates past ~2MB so it never grows wild.

#import "GAV1FileLog.h"

@implementation GAV1FileLog

+ (NSString *)logPath {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [dirs.firstObject stringByAppendingPathComponent:@"av1debug.log"];
}

+ (void)line:(NSString *)line {
    static NSObject *lock = nil;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        NSString *path = [self logPath];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:path]) {
            NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
            if ([attr fileSize] > 2 * 1024 * 1024) {
                [fm removeItemAtPath:path error:nil];
            }
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            } @finally {
                [fh closeFile];
            }
        }
    }
}

+ (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], msg];
    [self line:line];
}

@end
