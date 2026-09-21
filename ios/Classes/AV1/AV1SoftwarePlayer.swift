// AV1SoftwarePlayer.swift — software AV1 playback backend.
//
// ADDITIVE file. Implements the same NativeVideoPlayerApiDelegate contract as
// the AVPlayer-based controller, but decodes with dav1d (via GAV1Player) and
// renders through AVSampleBufferDisplayLayer + AVSampleBufferRenderSynchronizer
// (+ AVSampleBufferAudioRenderer when the source has audio).
//
// It is engaged ONLY when BOTH hold:
//   1. the source's video stream is AV1 (probed with GAV1Probe), and
//   2. the device has no AV1 hardware decoder (AV1Capability).
// Every other format keeps using the existing AVPlayer code path, byte for
// byte unchanged.

import AVFoundation
import CoreMedia

final class AV1SoftwarePlayer: NSObject, NativeVideoPlayerApiDelegate {

    // MARK: - plumbing back to Flutter (mirrors the AVPlayer controller)

    private let api: NativeVideoPlayerApi

    // MARK: - render pipeline

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private var hasAudioRenderer = false

    // MARK: - decode engine

    private var engine: GAV1Player?
    private var sourceURL: URL?
    private var sourceHeaders: [String: String] = [:]
    private let pumpQueue = DispatchQueue(label: "av1.software.pump", qos: .userInitiated)
    // All AVSampleBuffer* enqueue/addRenderer calls go through this serial
    // queue. Using DispatchQueue.main.sync from the decode callbacks risked
    // deadlocking with the main thread (play/seek/teardown), which the
    // watchdog kills; a private queue removes that coupling entirely.
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

    init(api: NativeVideoPlayerApi) {
        self.api = api
        super.init()
        // NOTE: the controller assigns api.delegate = self only after
        // tryOpen succeeds, so a failed probe never hijacks callbacks.
        displayLayer.videoGravity = .resizeAspect
        // Drive the display layer from the shared clock. Without an explicit
        // timebase the layer accepts enqueued frames but never presents them
        // (black), because nothing advances its clock.
        if #available(iOS 18.0, *) {
            // On iOS 18+ the renderer's own timebase is authoritative.
        } else {
            displayLayer.controlTimebase = synchronizer.timebase
        }
        synchronizer.addRenderer(displayLayer)
        // Audio renderer is added lazily on first audio frame (sources
        // without audio must never add it: an idle audio renderer stalls
        // the synchronizer clock).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayLayerFailed(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode,
            object: displayLayer
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // deinit can run on any thread; never block here. Just signal stop
        // and free the engine (the pump may still be unwinding, so this
        // branch is avoided in the normal controller flow by an explicit
        // teardown before release).
        engine?.requestStop()
        engine?.close()
        engine = nil
    }

    /// The layer the platform view must display instead of the AVPlayerLayer.
    var layer: CALayer { displayLayer }

    // MARK: - NativeVideoPlayerApiDelegate

    /// Tries to open the source for software decode. Returns true only if
    /// the source is AV1 and the engine opened cleanly. No api callbacks,
    /// no delegate changes — safe to call speculatively from the controller.
    /// Must be called off the main thread (does network/demux I/O).
    func tryOpen(_ videoSource: VideoSource) -> Bool {
        GAV1FileLog.log("sw tryOpen path=%@", videoSource.path)
        // Never leak a previous engine (defensive; the controller currently
        // creates a fresh instance per load).
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
        GAV1FileLog.log("sw tryOpen -> true %dx%d", Int(engine.videoWidth), Int(engine.videoHeight))
        sourceURL = url
        sourceHeaders = videoSource.headers
        self.engine = engine
        info = VideoInfo(height: Int(engine.videoHeight),
                         width: Int(engine.videoWidth),
                         duration: Int64(engine.durationSeconds * 1000))
        videoFPS = engine.fps > 0 ? engine.fps : 30
        videoFrameCount = 0
        return true
    }

    func loadVideoSource(videoSource: VideoSource) {
        // Normal entry point once tryOpen succeeded: reset state and announce.
        // (If tryOpen was skipped, open here; on failure report the error.)
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
        if hasAudioRenderer {
            synchronizer.removeRenderer(audioRenderer, at: .zero)
            hasAudioRenderer = false
        }
        audioRenderer.volume = volume
        api.onPlaybackReady()
    }

    func getVideoInfo(completion: @escaping (VideoInfo) -> Void) {
        completion(info)
    }

    func getPlaybackPosition() -> Int64 {
        let t = synchronizer.currentTime()
        guard t.isValid && !t.isIndefinite else { return 0 }
        return Int64(t.seconds * 1000)
    }

    func play() {
        GAV1FileLog.log("sw play")
        guard engine != nil else { return }
        endedNotified = false
        if atEOF {
            // Replay from the start, like the AVPlayer controller does.
            seekTo(position: 0) { [weak self] in self?.startPump(rate: Float(self?.speed ?? 1)) }
            return
        }
        startPump(rate: Float(speed))
    }

    func pause() {
        GAV1FileLog.log("sw pause")
        setSyncRate(0)
    }

    func stop(completion: @escaping () -> Void) {
        GAV1FileLog.log("sw stop")
        setSyncRate(0)
        stopPump()
        if let engine = engine {
            _ = engine.seek(toTime: 0)
        }
        displayLayer.flush()
        atEOF = false
        completion()
    }

    func isPlaying() -> Bool {
        rate != 0
    }

    func seekTo(position: Int64, completion: @escaping () -> Void) {
        GAV1FileLog.log("sw seekTo %lld", position)
        guard let engine = engine else { completion(); return }
        let wasPlaying = rate != 0
        let targetRate: Float = wasPlaying ? Float(speed) : 0
        stopPump()
        displayLayer.flush()
        // Re-anchor the render clock to the seek target. Without this the
        // synchronizer keeps the pre-seek time, so freshly decoded frames
        // (whose PTS restart at the target) arrive "late" and are never
        // presented (black) while the position readout goes stale.
        synchronizer.setRate(0, time: CMTime(seconds: Double(position) / 1000.0,
                                             preferredTimescale: 600))
        atEOF = false
        endedNotified = false
        // Restart the synthesis baseline from the seek target so invalid
        // PTS after a seek still paces correctly.
        videoFrameCount = Int64((Double(position) / 1000.0) * max(videoFPS, 1))
        lastEnqueuedPTS = .zero
        pumpQueue.async { [weak self] in
            guard let self = self else { return }
            _ = engine.seek(toTime: Double(position) / 1000.0)
            DispatchQueue.main.async {
                completion()
                if wasPlaying || targetRate != 0 {
                    self.startPump(rate: targetRate)
                }
            }
        }
    }

    func setPlaybackSpeed(speed: Double) {
        self.speed = speed
        // audioTimePitchAlgorithm needs iOS 16+; on 15.x the synchronizer
        // rate still drives both renderers, just without pitch correction.
        if #available(iOS 16.0, *) {
            audioRenderer.audioTimePitchAlgorithm = .varispeed
        }
        if rate != 0 {
            setSyncRate(Float(speed))
        }
    }

    func setVolume(volume: Double) {
        self.volume = Float(volume)
        audioRenderer.volume = self.volume
    }

    func setLoop(loop: Bool) {
        self.loop = loop
    }

    // MARK: - pump

    /// Sets the synchronizer rate, falling back to time zero when the clock
    /// has no valid current time yet (fresh synchronizer, no frames enqueued).
    /// A setRate with an invalid time fails silently and leaves the clock
    /// stopped — which presents as black frames.
    private func setSyncRate(_ rate: Float) {
        let t = synchronizer.currentTime()
        synchronizer.setRate(rate, time: (t.isValid && !t.isIndefinite) ? t : .zero)
        self.rate = rate
    }

    private func startPump(rate: Float) {
        guard let engine = engine, !pumping else {
            // Already pumping: just (re)set the clock rate.
            if pumping { setSyncRate(rate) }
            return
        }
        pumping = true
        stopLock.withLock { stopFlag = false; pumpActive = true }
        setSyncRate(rate)

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
                    GAV1FileLog.log("sw pump done err=%@", error?.localizedDescription ?? "nil")
                    DispatchQueue.main.async {
                        if let error = error {
                            self.rate = 0
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
        setSyncRate(0)
    }

    private func teardownEngine() {
        GAV1FileLog.log("sw teardown")
        // Ask the pump to stop, then WAIT for it to finish before freeing
        // the engine. Closing while the decode loop is mid-frame frees
        // _vdec/_fmt/_sws underneath it and crashes.
        stopPump()
        // Bounded wait: the decode loop checks the stop flag between every
        // packet/frame, so this returns promptly.
        let deadline = Date().addingTimeInterval(2.0)
        while stopLock.withLock({ pumpActive }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        engine?.close()
        engine = nil
        displayLayer.flush()
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
        // Diagnostic: first frames + layer/clock state (Console.app, filter GAV1).
        if videoFrameCount < 5 {
            let t = self.synchronizer.currentTime()
            NSLog("GAV1 frame=%lld pts=%.3fs syncRate=%.2f syncTime=%.3fs layerReady=%d layerStatus=%ld clockValid=%d",
                  videoFrameCount, pts.seconds, self.synchronizer.rate, t.seconds,
                  self.displayLayer.isReadyForMoreMediaData ? 1 : 0,
                  Int(self.displayLayer.status.rawValue),
                  (t.isValid && !t.isIndefinite) ? 1 : 0)
        }
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
        lastEnqueuedPTS = timing.presentationTimeStamp

        // Serialize on our own queue (never the main thread: the pump can be
        // started from main, so main.sync here deadlocks and gets killed).
        var failed = false
        enqueueQueue.sync {
            if self.displayLayer.status == .failed {
                failed = true
                return
            }
            self.displayLayer.enqueue(sample)
            // Prime the clock on the first frame so playback starts even if
            // the app never calls play() with an explicit rate yet.
            if self.synchronizer.rate == 0 && self.rate != 0 {
                self.setSyncRate(self.rate)
            }
        }
        if failed {
            stop = true
        }
    }
    private func enqueueAudio(sampleBuffer: CMSampleBuffer?, stop: inout Bool) {
        guard let sampleBuffer = sampleBuffer else { return }
        if !hasAudioRenderer {
            enqueueQueue.sync {
                self.synchronizer.addRenderer(self.audioRenderer)
                self.hasAudioRenderer = true
            }
        }
        while !audioRenderer.isReadyForMoreMediaData && !stopRequested {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if stopRequested { stop = true; return }
        enqueueQueue.sync {
            self.audioRenderer.enqueue(sampleBuffer)
        }
    }

    private func onStreamEnded() {
        GAV1FileLog.log("sw ended")
        atEOF = true
        rate = 0
        if loop {
            seekTo(position: 0) { [weak self] in self?.startPump(rate: Float(self?.speed ?? 1)) }
        } else if !endedNotified {
            endedNotified = true
            api.onPlaybackEnded()
        }
    }

    @objc private func displayLayerFailed(_ note: Notification) {
        GAV1FileLog.log("sw layer FAILED")
        let err = (note.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? Error)
            ?? NSError(domain: "AV1SoftwarePlayer", code: -10,
                       userInfo: [NSLocalizedDescriptionKey: "display layer decode failure"]) as Error
        rate = 0
        api.onError(err)
    }
}
