// AV1SoftwarePlayer.swift — software AV1 playback backend.
//
// ADDITIVE file. Implements the same NativeVideoPlayerApiDelegate contract as
// the AVPlayer-based controller, but decodes with dav1d (via GAV1Player) and
// renders through AVSampleBufferDisplayLayer. Audio, when present, goes
// through AVSampleBufferAudioRenderer.
//
// It is engaged ONLY when BOTH hold:
//   1. the source's video stream is AV1 (probed with GAV1Probe), and
//   2. the device has no AV1 hardware decoder (AV1Capability).
// Every other format keeps using the existing AVPlayer code path, byte for
// byte unchanged.
//
// CLOCK DESIGN (this was the source of black frames / audio-only playback):
// a render sink only presents enqueued sample buffers while the timebase that
// drives it is RUNNING. AVSampleBufferRenderSynchronizer advances its clock
// only while it hosts at least one renderer, and on iOS 15 AVSampleBufferDisplay
// Layer cannot be added to it (addRenderer crashes). Therefore the display
// layer is bound to a timebase that THIS CLASS owns and drives explicitly:
// it runs on the host clock and we set start time / rate ourselves on
// play/pause/seek. Audio is driven by a separate synchronizer that we keep in
// step with the same values. Neither depends on the other to make progress,
// so video-only and audio-only sources both work.

import AVFoundation
import CoreMedia

final class AV1SoftwarePlayer: NSObject, NativeVideoPlayerApiDelegate {

    // MARK: - plumbing back to Flutter (mirrors the AVPlayer controller)

    private let api: NativeVideoPlayerApi

    // MARK: - render pipeline

    private let displayLayer = AVSampleBufferDisplayLayer()

    /// Audio renderer + the synchronizer that hosts it. Kept separate from the
    /// display layer's clock because the display layer cannot join it on older
    /// iOS. `nil` until the source is known to have audio.
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var audioSynchronizer: AVSampleBufferRenderSynchronizer?

    /// The clock that drives `displayLayer`. Owned and driven by us.
    private var videoTimebase: CMTimebase?

    // MARK: - decode engine

    private var engine: GAV1Player?
    private var sourceURL: URL?
    private var sourceHeaders: [String: String] = [:]
    private let pumpQueue = DispatchQueue(label: "av1.software.pump", qos: .userInitiated)
    // All AVSampleBuffer* enqueue calls go through this serial queue. Using
    // DispatchQueue.main.sync from the decode callbacks risked deadlocking
    // with the main thread (play/seek/teardown), which the watchdog kills; a
    // private queue removes that coupling entirely.
    private let enqueueQueue = DispatchQueue(label: "av1.software.enqueue", qos: .userInitiated)
    private var pumping = false
    private var atEOF = false
    private var lastEnqueuedPTS = CMTime.zero
    // Frames enqueued since load/seek. Used to synthesize PTS when the
    // decoder emits frames with invalid timestamps (dav1d can do this for
    // the first frames due to internal delay): without this, every frame
    // stamps at zero, flashes by instantly, then the screen goes black
    // while audio (which has valid PTS) plays normally.
    private var videoFrameCount: Int64 = 0
    private var videoFPS: Double = 0
    // Set when teardown/stop is requested; read on the pump thread to break
    // out of the backpressure waits below. NSLock-guarded: written from the
    // main thread (stopPump/teardown/load), read from the pump thread.
    private var stopFlag = false
    private var pumpActive = false
    private let stopLock = NSLock()

    // MARK: - state (mirrors AVPlayer controller semantics)

    private var loop = false
    private var rate: Float = 0
    private var speed: Double = 1
    private var volume: Float = 1
    private var info = VideoInfo(height: 0, width: 0, duration: 0)
    private var endedNotified = false
    /// Clock time the current play/pause segment started from. Used to read
    /// the presentation position without the synchronizer.
    private var anchorTime: CMTime = .zero
    /// Rate the user asked for. The clock is only actually started once the
    /// first frame after a load/seek has been enqueued: starting it earlier
    /// lets host-clock time run past the first frame's PTS (which is ~0), so
    /// the layer treats every early frame as late and drops them all —
    /// black picture with a running clock, i.e. a spinner that never clears.
    private var desiredRate: Float = 0
    private var clockPrimed = false

    init(api: NativeVideoPlayerApi) {
        GAV1FileLog.line("sw init enter")
        self.api = api

        // Own timebase on the host clock: always advances while rate != 0,
        // with no reliance on any renderer being attached anywhere.
        var tb: CMTimebase?
        let st = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb)
        if st == noErr, let tb = tb {
            videoTimebase = tb
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 0)
            displayLayer.controlTimebase = tb
            GAV1FileLog.line("sw init timebase ok")
        } else {
            // Without a clock nothing presents; report rather than show black.
            GAV1FileLog.line(String(format: "sw init timebase FAILED st=%d", Int(st)))
        }

        super.init()

        // NOTE: the controller assigns api.delegate = self only after
        // tryOpen succeeds, so a failed probe never hijacks callbacks.
        displayLayer.videoGravity = .resizeAspect
        GAV1FileLog.line("sw init done")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayLayerFailed(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode,
            object: displayLayer
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        engine?.requestStop()
        engine?.close()
        engine = nil
    }

    /// The layer the platform view must display instead of the AVPlayerLayer.
    var layer: CALayer { displayLayer }

    // MARK: - clock control

    /// Start/stop the video clock. `rate` is the synchronizer-style rate:
    /// 1 = normal speed, 0 = paused, N = N× speed.
    private func setVideoClockRate(_ newRate: Float) {
        desiredRate = newRate
        rate = newRate
        // Until the first frame of this segment is on the layer there is
        // nothing to present; running the clock now would race past it.
        guard clockPrimed else { return }
        applyClockRate(newRate)
    }

    /// Actually push a rate onto the timebases. Only call once primed.
    private func applyClockRate(_ newRate: Float) {
        guard let tb = videoTimebase else { return }
        // Anchor "now" so the clock continues from wherever it is instead of
        // snapping back to a stale start time when the rate changes.
        let now = CMTimebaseGetTime(tb)
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        CMTimebaseSetRateAndAnchorTime(
            tb, rate: Double(newRate),
            anchorTime: now,
            immediateSourceTime: hostNow)
        // Keep audio (if any) in step. Audio is best-effort: if it drifts a
        // little the video clock is still the source of truth for position.
        if let sync = audioSynchronizer {
            sync.setRate(newRate, time: now)
        }
    }

    /// Move the clock to an absolute media time (seek, replay, stop).
    private func setVideoClockTime(_ t: CMTime) {
        anchorTime = t
        if let tb = videoTimebase {
            CMTimebaseSetTime(tb, time: t)
            CMTimebaseSetRate(tb, rate: Double(rate))
        }
        if let sync = audioSynchronizer {
            sync.setRate(rate, time: t)
        }
    }

    // MARK: - NativeVideoPlayerApiDelegate

    /// Tries to open the source for software decode. Returns true only if
    /// the source is AV1 and the engine opened cleanly. No api callbacks,
    /// no delegate changes — safe to call speculatively from the controller.
    /// Must be called off the main thread (does network/demux I/O).
    func tryOpen(_ videoSource: VideoSource) -> Bool {
        GAV1FileLog.line(String(format: "sw tryOpen path=%@", videoSource.path))
        if engine != nil { teardownEngine() }
        let isURL = videoSource.type == .network
        guard let url = isURL ? URL(string: videoSource.path) : URL(fileURLWithPath: videoSource.path) else {
            return false
        }
        guard let engine = GAV1Player(url: url, headers: videoSource.headers) else {
            return false
        }
        do {
            _ = try engine.open()
        } catch {
            return false
        }
        GAV1FileLog.line(String(format: "sw tryOpen -> true %dx%d audio=%d",
                                Int(engine.videoWidth), Int(engine.videoHeight),
                                engine.hasAudio ? 1 : 0))
        sourceURL = url
        sourceHeaders = videoSource.headers
        self.engine = engine
        info = VideoInfo(height: Int(engine.videoHeight),
                         width: Int(engine.videoWidth),
                         duration: Int64(engine.durationSeconds * 1000))
        videoFPS = engine.fps > 0 ? engine.fps : 30
        videoFrameCount = 0
        // Audio renderer only exists when the source has audio. A source
        // without audio must NOT get one: it would stay idle and (on iOS 15)
        // stall the synchronizer clock it is attached to.
        if engine.hasAudio {
            setupAudioRenderer()
        }
        return true
    }

    /// Creates the audio renderer + its synchronizer. Called once per open,
    /// only for sources that actually carry audio.
    private func setupAudioRenderer() {
        guard audioRenderer == nil else { return }
        let sync = AVSampleBufferRenderSynchronizer()
        let renderer = AVSampleBufferAudioRenderer()
        renderer.volume = volume
        if #available(iOS 16.0, *) {
            renderer.audioTimePitchAlgorithm = .varispeed
        }
        sync.addRenderer(renderer)
        audioSynchronizer = sync
        audioRenderer = renderer
    }

    func loadVideoSource(videoSource: VideoSource) {
        // Normal entry point once tryOpen succeeded: reset state and announce.
        if engine == nil {
            guard tryOpen(videoSource) else {
                api.onError(NSError(domain: "AV1SoftwarePlayer", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "cannot open source"]) as Error)
                return
            }
        }
        endedNotified = false
        atEOF = false
        lastEnqueuedPTS = .zero
        videoFrameCount = 0
        displayLayer.flush()
        if let sync = audioSynchronizer {
            sync.setRate(0, time: .zero)
            audioRenderer?.flush()
        }
        clockPrimed = false
        setVideoClockTime(.zero)
        rate = 0
        api.onPlaybackReady()
    }

    func getVideoInfo(completion: @escaping (VideoInfo) -> Void) {
        completion(info)
    }

    func getPlaybackPosition() -> Int64 {
        // Read the clock we own. It advances on the host clock while playing
        // and holds still while paused/stopped, so it is always correct —
        // unlike the previous synchronizer read, which stayed at 0 whenever
        // no audio renderer was driving it.
        if let tb = videoTimebase {
            let t = CMTimebaseGetTime(tb)
            if t.isValid && !t.isIndefinite && t.seconds >= 0 {
                return Int64(t.seconds * 1000)
            }
        }
        let last = lastEnqueuedPTS
        guard last.isValid && !last.isIndefinite else { return 0 }
        return Int64(last.seconds * 1000)
    }

    func play() {
        GAV1FileLog.line("sw play")
        guard engine != nil else { return }
        endedNotified = false
        if atEOF {
            seekTo(position: 0) { [weak self] in self?.startPump(rate: Float(self?.speed ?? 1)) }
            return
        }
        startPump(rate: Float(speed))
    }

    func pause() {
        GAV1FileLog.line("sw pause")
        stopPump()
        setVideoClockRate(0)
    }

    func stop(completion: @escaping () -> Void) {
        GAV1FileLog.line("sw stop")
        stopPump()
        setVideoClockRate(0)
        setVideoClockTime(.zero)
        if let engine = engine {
            _ = engine.seek(toTime: 0)
        }
        displayLayer.flush()
        audioRenderer?.flush()
        atEOF = false
        completion()
    }

    func isPlaying() -> Bool {
        rate != 0
    }

    func seekTo(position: Int64, completion: @escaping () -> Void) {
        GAV1FileLog.line(String(format: "sw seekTo %lld", position))
        guard let engine = engine else { completion(); return }
        let wasPlaying = rate != 0
        let targetRate: Float = wasPlaying ? Float(speed) : 0
        stopPump()
        displayLayer.flush()
        audioRenderer?.flush()

        let target = CMTime(seconds: Double(position) / 1000.0, preferredTimescale: 600)
        // Park the clock at the target while we re-seek, then restart.
        rate = 0
        setVideoClockTime(target)

        atEOF = false
        endedNotified = false
        clockPrimed = false
        videoFrameCount = Int64((Double(position) / 1000.0) * max(videoFPS, 1))
        lastEnqueuedPTS = .zero
        pumpQueue.async { [weak self] in
            guard let self = self else { return }
            _ = engine.seek(toTime: Double(position) / 1000.0)
            DispatchQueue.main.async {
                completion()
                if targetRate != 0 {
                    self.startPump(rate: targetRate)
                }
            }
        }
    }

    func setPlaybackSpeed(speed: Double) {
        self.speed = speed
        if rate != 0 {
            setVideoClockRate(Float(speed))
        }
    }

    func setVolume(volume: Double) {
        self.volume = Float(volume)
        audioRenderer?.volume = self.volume
    }

    func setLoop(loop: Bool) {
        self.loop = loop
    }

    // MARK: - pump

    private func startPump(rate newRate: Float) {
        guard let engine = engine else { return }
        if pumping {
            // Already decoding: only the clock needs to change.
            setVideoClockRate(newRate)
            return
        }
        pumping = true
        stopLock.withLock { stopFlag = false; pumpActive = true }
        setVideoClockRate(newRate)

        pumpQueue.async { [weak self] in
            guard let self = self else { return }
            engine.decode(
                video: { [weak self] pixelBuffer, pts, stop in
                    guard let self = self else { stop.pointee = true; return }
                    var shouldStop = false
                    self.enqueueVideo(pixelBuffer: pixelBuffer, pts: pts, stop: &shouldStop)
                    if shouldStop { stop.pointee = true }
                },
                audio: { [weak self] sampleBuffer, stop in
                    guard let self = self else { stop.pointee = true; return }
                    var shouldStop = false
                    self.enqueueAudio(sampleBuffer: sampleBuffer, stop: &shouldStop)
                    if shouldStop { stop.pointee = true }
                },
                completion: { [weak self] error in
                    guard let self = self else { return }
                    self.pumping = false
                    self.stopLock.withLock { self.pumpActive = false }
                    GAV1FileLog.line(String(format: "sw pump done err=%@", error?.localizedDescription ?? "nil"))
                    DispatchQueue.main.async {
                        if let error = error {
                            self.rate = 0
                            if let tb = self.videoTimebase { CMTimebaseSetRate(tb, rate: 0) }
                            self.api.onError(error)
                        } else {
                            self.onStreamEnded()
                        }
                    }
                }
            )
        }
    }

    private func stopPump() {
        engine?.requestStop()
        stopLock.withLock { stopFlag = true }
        // The decode call returns on the pump queue; pumping flips false in
        // its completion handler. Do not block the main thread waiting.
    }

    private func teardownEngine() {
        GAV1FileLog.line("sw teardown")
        // Ask the pump to stop, then WAIT for it to finish before freeing
        // the engine. Closing while the decode loop is mid-frame frees
        // _vdec/_fmt/_sws underneath it and crashes.
        stopPump()
        let deadline = Date().addingTimeInterval(2.0)
        while stopLock.withLock({ pumpActive }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        engine?.close()
        engine = nil
        displayLayer.flush()
    }

    /// Full shutdown for view teardown: stops decode, silences and detaches
    /// audio, and parks the clock. Called by the controller when the software
    /// backend is dismissed — without this the audio renderer keeps playing
    /// after the view is gone.
    private var invalidated = false
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        GAV1FileLog.line("sw invalidate")
        NotificationCenter.default.removeObserver(self)
        teardownEngine()
        rate = 0
        if let tb = videoTimebase { CMTimebaseSetRate(tb, rate: 0) }
        if let sync = audioSynchronizer, let renderer = audioRenderer {
            sync.setRate(0, time: .zero)
            renderer.flush()
            sync.removeRenderer(renderer, at: .zero)
        }
        audioSynchronizer = nil
        audioRenderer = nil
        displayLayer.flush()
        displayLayer.controlTimebase = nil
        videoTimebase = nil
    }

    /// Read on the pump thread; set on the main thread by stopPump/teardown.
    private var stopRequested: Bool {
        stopLock.withLock { stopFlag }
    }

    /// Resolves the PTS to enqueue for a frame. Prefers the container
    /// timestamp; when the decoder emits an invalid one (dav1d delay),
    /// synthesizes from the frame count and fps so frames pace correctly
    /// instead of all stamping at zero (flash-fast then black).
    private func presentationPTS(for pts: CMTime) -> CMTime {
        defer { videoFrameCount += 1 }
        if pts.isValid && !pts.isIndefinite {
            lastEnqueuedPTS = pts
            return pts
        }
        let synth = CMTimeMakeWithSeconds(Double(videoFrameCount) / max(videoFPS, 1), preferredTimescale: 600)
        lastEnqueuedPTS = synth
        return synth
    }

    private func enqueueVideo(pixelBuffer: CVPixelBuffer?, pts: CMTime, stop: inout Bool) {
        guard let pixelBuffer = pixelBuffer else { return }

        // Backpressure: wait until the layer wants more data. This keeps
        // memory bounded on long files and matches AVPlayer behaviour.
        while !displayLayer.isReadyForMoreMediaData && !stopRequested {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if stopRequested { stop = true; return }

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format = format else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationPTS(for: pts),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let st = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample)
        guard st == noErr, let sample = sample else { return }

        var failed = false
        enqueueQueue.sync {
            if self.displayLayer.status == .failed {
                failed = true
                return
            }
            self.displayLayer.enqueue(sample)
            // First frame of this segment is on the layer. Now it is safe to
            // let the clock run: it will start from this frame's PTS instead
            // of from a host time that already ran past it.
            if !self.clockPrimed {
                self.clockPrimed = true
                if let tb = self.videoTimebase {
                    CMTimebaseSetTime(tb, time: timing.presentationTimeStamp)
                }
                // Now that the segment is anchored, apply the rate the user
                // asked for (recorded by setVideoClockRate while unprimed).
                self.applyClockRate(self.desiredRate)
            }
        }
        if failed {
            stop = true
        }
    }

    private func enqueueAudio(sampleBuffer: CMSampleBuffer?, stop: inout Bool) {
        guard let sampleBuffer = sampleBuffer, let renderer = audioRenderer else { return }
        while !renderer.isReadyForMoreMediaData && !stopRequested {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if stopRequested { stop = true; return }
        enqueueQueue.sync {
            renderer.enqueue(sampleBuffer)
        }
    }

    private func onStreamEnded() {
        GAV1FileLog.line("sw ended")
        atEOF = true
        rate = 0
        if let tb = videoTimebase { CMTimebaseSetRate(tb, rate: 0) }
        if loop {
            seekTo(position: 0) { [weak self] in self?.startPump(rate: Float(self?.speed ?? 1)) }
        } else if !endedNotified {
            endedNotified = true
            api.onPlaybackEnded()
        }
    }

    @objc private func displayLayerFailed(_ note: Notification) {
        GAV1FileLog.line("sw layer FAILED")
        let err = (note.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? Error)
            ?? NSError(domain: "AV1SoftwarePlayer", code: -10,
                       userInfo: [NSLocalizedDescriptionKey: "display layer decode failure"]) as Error
        rate = 0
        if let tb = videoTimebase { CMTimebaseSetRate(tb, rate: 0) }
        api.onError(err)
    }
}
