import AVFoundation

final class AV1SoftwarePlayer: NativeVideoPlayerApiDelegate {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let api: NativeVideoPlayerApi
    private let engine: AV1Decoder
    private let videoTimebase: CMTimebase
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let audioSynchronizer = AVSampleBufferRenderSynchronizer()
    private let pumpQueue = DispatchQueue(label: "av1.software.pump", qos: .userInitiated)
    private var pumping = false
    private var atEOF = false
    private var loop = false
    private var rate: Float = 0
    private var speed: Double = 1
    private var clockPrimed = false
    private var seekFloor = CMTime.zero

    init?(api: NativeVideoPlayerApi, videoSource: VideoSource) {
        let isUrl = videoSource.type == .network
        guard let url = isUrl ? URL(string: videoSource.path) : URL(fileURLWithPath: videoSource.path) else { return nil }
        var headers = HTTPCookie.requestHeaderFields(with: SwiftNativeVideoPlayerPlugin.cookieStorage?.cookies(for: url) ?? [])
        headers.merge(videoSource.headers) { _, new in new }
        engine = AV1Decoder(url: url, headers: headers)
        guard engine.open() else { return nil }
        self.api = api
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        videoTimebase = tb!
        displayLayer.controlTimebase = videoTimebase
        displayLayer.videoGravity = .resizeAspect
        audioSynchronizer.addRenderer(audioRenderer)
    }

    deinit {
        engine.stop = true
        audioSynchronizer.setRate(0, time: .zero)
    }

    func loadVideoSource(videoSource: VideoSource) {
        api.onPlaybackReady()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self = self else { return timer.invalidate() }
            self.api.onPlaybackPositionChanged(position: self.getPlaybackPosition())
        }
    }

    func getVideoInfo(completion: @escaping (VideoInfo) -> Void) {
        completion(VideoInfo(height: Int(engine.videoHeight), width: Int(engine.videoWidth), duration: Int64(engine.durationSeconds * 1000)))
    }

    func getPlaybackPosition() -> Int64 {
        Int64(max(CMTimebaseGetTime(videoTimebase).seconds, 0) * 1000)
    }

    func play() {
        guard atEOF else { return startPump(rate: Float(speed)) }
        rate = Float(speed)
        seekTo(position: 0) {}
    }

    func pause() {
        setClockRate(0)
    }

    func stop(completion: @escaping () -> Void) {
        pause()
        seekTo(position: 0, completion: completion)
    }

    func isPlaying() -> Bool {
        rate != 0
    }

    func seekTo(position: Int64, completion: @escaping () -> Void) {
        let seconds = Double(position) / 1000
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        engine.stop = true
        setClockTime(target)
        atEOF = false
        pumpQueue.async { [weak self, engine] in
            engine.seek(toTime: seconds)
            DispatchQueue.main.async {
                guard let self = self else { return completion() }
                self.displayLayer.flush()
                self.audioRenderer.flush()
                self.clockPrimed = false
                self.seekFloor = target
                self.startPump(rate: self.rate)
                completion()
            }
        }
    }

    func setPlaybackSpeed(speed: Double) {
        self.speed = speed
        if rate != 0 { setClockRate(Float(speed)) }
    }

    func setVolume(volume: Double) {
        audioRenderer.volume = Float(volume)
    }

    func setLoop(loop: Bool) {
        self.loop = loop
    }

    private func setClockRate(_ newRate: Float) {
        rate = newRate
        if clockPrimed { applyClockRate(newRate) }
    }

    private func applyClockRate(_ newRate: Float) {
        let now = CMTimebaseGetTime(videoTimebase)
        CMTimebaseSetRateAndAnchorTime(videoTimebase, rate: Double(newRate), anchorTime: now, immediateSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
        audioSynchronizer.setRate(newRate, time: now)
    }

    private func setClockTime(_ time: CMTime) {
        CMTimebaseSetTime(videoTimebase, time: time)
        CMTimebaseSetRate(videoTimebase, rate: 0)
        audioSynchronizer.setRate(0, time: time)
    }

    private func startPump(rate newRate: Float) {
        setClockRate(newRate)
        if pumping { return }
        pumping = true
        engine.stop = false
        pumpQueue.async { [weak self, engine] in
            engine.decode({ sample, video in
                self?.enqueue(sample, video: video)
            }, completion: { error in
                let stopped = engine.stop
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.pumping = false
                    if stopped { return }
                    guard let error = error else { return self.onStreamEnded() }
                    self.setClockRate(0)
                    self.api.onError(error)
                }
            })
        }
    }

    private func enqueue(_ sample: CMSampleBuffer, video: Bool) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let renderer: AVQueuedSampleBufferRendering = video ? displayLayer : audioRenderer
        guard pts >= seekFloor else { return }
        while !renderer.isReadyForMoreMediaData && (video || clockPrimed) && !engine.stop {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if engine.stop { return }
        renderer.enqueue(sample)
        if video && !clockPrimed {
            clockPrimed = true
            CMTimebaseSetTime(videoTimebase, time: pts)
            applyClockRate(rate)
        }
    }

    private func onStreamEnded() {
        if loop { return seekTo(position: 0) {} }
        atEOF = true
        setClockRate(0)
        api.onPlaybackEnded()
    }
}
