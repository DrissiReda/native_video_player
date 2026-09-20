// driver.swift — headless driver for AV1SoftwarePlayer (the Swift layer).
// Mirrors what the plugin controller does on device:
//   tryOpen -> delegate assign -> loadVideoSource -> play ->
//   poll position -> seek -> stop -> release (teardown wait).
// Prints RESULT lines; a crash anywhere fails the CI step.
import Foundation
import AVFoundation

final class StubMessenger: NSObject, FlutterBinaryMessenger {}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: driver <file>")
    exit(2)
}
let path = args[1]

let messenger = StubMessenger()
let api = NativeVideoPlayerApi(messenger: messenger, viewId: 1)
let player = AV1SoftwarePlayer(api: api)

let src = VideoSource(from: ["path": path, "type": "file", "headers": [:] as [String: String]])
guard let vs = src else {
    print("FAIL video-source-map")
    exit(1)
}

guard player.tryOpen(vs) else {
    print("FAIL tryOpen")
    exit(1)
}
print("INFO tryOpen ok")
api.delegate = player
player.loadVideoSource(videoSource: vs)
player.play()

// Poll position for ~8s (source is 6.85s; loop is off so it ends).
for i in 1...8 {
    Thread.sleep(forTimeInterval: 1.0)
    let pos = player.getPlaybackPosition()
    print("INFO t=\(i)s pos=\(pos)ms playing=\(player.isPlaying())")
}

// Seek back to 2s and play again briefly. Completions land on the main
// thread, so spin the runloop while waiting (blocking it deadlocks).
func spinWait(_ sema: DispatchSemaphore, timeout: TimeInterval) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while sema.wait(timeout: .now()) == .timedOut {
        if Date() > end { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return true
}
let sema = DispatchSemaphore(value: 0)
player.seekTo(position: 2000) { sema.signal() }
if !spinWait(sema, timeout: 10) {
    print("WARN seek completion timeout")
}
print("INFO post-seek pos=\(player.getPlaybackPosition())ms")
player.play()
// Let main-async completions run while waiting (sleep would stall them).
let playEnd = Date().addingTimeInterval(2.0)
while Date() < playEnd {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
print("INFO after-seek pos=\(player.getPlaybackPosition())ms playing=\(player.isPlaying())")

let sema2 = DispatchSemaphore(value: 0)
player.stop { sema2.signal() }
if !spinWait(sema2, timeout: 10) {
    print("WARN stop completion timeout")
}
print("RESULT SWIFT-CLEAN")
