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

// Poll position for ~4s of normal playback.
for i in 1...4 {
    let end = Date().addingTimeInterval(1.0)
    while Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    print("INFO t=\(i)s pos=\(player.getPlaybackPosition())ms playing=\(player.isPlaying())")
}

// Single seek mid-playback (the normal user flow): clock must re-anchor.
let sema = DispatchSemaphore(value: 0)
player.seekTo(position: 2000) { sema.signal() }
if !spinWait(sema, timeout: 10) {
    print("FAIL seek completion timeout")
    exit(1)
}
let p0 = player.getPlaybackPosition()
print("INFO post-seek pos=\(p0)ms")
if p0 < 1500 || p0 > 2500 {
    print("FAIL post-seek clock not re-anchored: \(p0)ms")
    exit(1)
}
let playEnd = Date().addingTimeInterval(2.0)
while Date() < playEnd {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
let p1 = player.getPlaybackPosition()
print("INFO after-seek pos=\(p1)ms playing=\(player.isPlaying())")
if !player.isPlaying() || p1 < 3500 || p1 > 4500 {
    print("FAIL playback did not resume after seek: pos=\(p1) playing=\(player.isPlaying())")
    exit(1)
}

let sema2 = DispatchSemaphore(value: 0)
player.stop { sema2.signal() }
if !spinWait(sema2, timeout: 10) {
    print("FAIL stop completion timeout")
    exit(1)
}
print("RESULT SWIFT-CLEAN")
