// harness main.m — headless driver for GAV1Player (macOS CLI).
// Exercises the exact paths that crash on device:
//   1. open + full decode (frame count, PTS, pixel checksum)
//   2. mid-decode requestStop + close race (the use-after-free suspect)
//   3. reopen + seek + decode-to-end (the watcdog/deadlock suspect area)
// Prints RESULT lines; exit 0 = clean.
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "GAV1Player.h"

static int gVideo = 0, gAudio = 0;
static uint64_t gSum = 0;
static double gFirstPTS[5];
static int gFirstCount = 0;
static double gLastPTS = -1;

static void resetCounters(void) {
    gVideo = 0; gAudio = 0; gSum = 0; gFirstCount = 0; gLastPTS = -1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s <file>\n", argv[0]); return 2; }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSURL *url = [NSURL fileURLWithPath:path];

        // ---- 1. open + full decode ----
        GAV1Player *p = [[GAV1Player alloc] initWithURL:url headers:nil];
        if (!p) { printf("FAIL init\n"); return 1; }
        NSError *err = nil;
        if (![p open:&err]) { printf("FAIL open %s\n", err.description.UTF8String); return 1; }
        printf("INFO %dx%d fps=%.2f dur=%.2f audio=%d\n",
               p.videoWidth, p.videoHeight, p.fps, p.durationSeconds, p.hasAudio);
        resetCounters();
        [p decodeWithVideo:^(__unused CVPixelBufferRef pb, CMTime pts, BOOL *stop) {
            double s = CMTimeGetSeconds(pts);
            if (gFirstCount < 5) gFirstPTS[gFirstCount++] = s;
            gLastPTS = s;
            // Cheap deterministic checksum over the Y plane.
            CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            size_t w = CVPixelBufferGetWidth(pb);
            size_t h = CVPixelBufferGetHeight(pb);
            size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
            uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
            uint64_t acc = 0;
            for (size_t y = 0; y < h; y += 16)
                for (size_t x = 0; x < w; x += 16)
                    acc += base[y * stride + x];
            gSum += acc;
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            gVideo++;
            (void)stop;
        } audio:^(__unused CMSampleBufferRef sb, BOOL *stop) {
            gAudio++;
            (void)stop;
        } completion:^(__unused NSError *e) {
            printf("INFO decode done err=%s\n", e ? e.description.UTF8String : "nil");
        }];
        printf("RESULT full video=%d audio=%d sum=%llu lastPTS=%.3f firstPTS=",
               gVideo, gAudio, gSum, gLastPTS);
        for (int i = 0; i < gFirstCount; i++) printf("%.3f,", gFirstPTS[i]);
        printf("\n");
        [p close];

        // ---- 2. stop+close race x3 ----
        for (int round = 1; round <= 3; round++) {
            GAV1Player *q = [[GAV1Player alloc] initWithURL:url headers:nil];
            NSError *e2 = nil;
            if (![q open:&e2]) { printf("FAIL reopen %d\n", round); return 1; }
            resetCounters();
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                [q decodeWithVideo:^(__unused CVPixelBufferRef pb, CMTime pts, BOOL *stop) {
                    gVideo++;
                    if (gVideo == 50) {
                        // Ask for stop from the decode thread, then ALSO
                        // close from here: stresses teardown ordering.
                        [q requestStop];
                        *stop = YES;
                    }
                    (void)pts;
                } audio:^(__unused CMSampleBufferRef sb, BOOL *stop) {
                    gAudio++;
                    (void)stop;
                } completion:^(__unused NSError *e) {}];
            });
            // Give the pump a moment to get mid-frame, then close
            // concurrently (main thread closes while decode runs).
            [NSThread sleepForTimeInterval:0.3];
            [q requestStop];
            [NSThread sleepForTimeInterval:0.3];
            [q close];
            [NSThread sleepForTimeInterval:0.5];
            printf("RESULT race%d survived video=%d audio=%d\n", round, gVideo, gAudio);
        }

        // ---- 3. reopen + seek + decode to end ----
        GAV1Player *r = [[GAV1Player alloc] initWithURL:url headers:nil];
        NSError *e3 = nil;
        if (![r open:&e3]) { printf("FAIL reopen3\n"); return 1; }
        if (![r seekToTime:2.0]) { printf("WARN seek failed\n"); }
        resetCounters();
        [r decodeWithVideo:^(__unused CVPixelBufferRef pb, CMTime pts, BOOL *stop) {
            gVideo++;
            gLastPTS = CMTimeGetSeconds(pts);
            (void)stop;
        } audio:^(__unused CMSampleBufferRef sb, BOOL *stop) {
            gAudio++;
            (void)stop;
        } completion:^(__unused NSError *e) {}];
        printf("RESULT seek video=%d audio=%d lastPTS=%.3f\n", gVideo, gAudio, gLastPTS);
        [r close];

        printf("RESULT ALL-CLEAN\n");
    }
    return 0;
}
