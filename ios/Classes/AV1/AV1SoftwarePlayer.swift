import AVFoundation

final class AV1SoftwarePlayer: NativeVideoPlayerApiDelegate {
    private let api: NativeVideoPlayerApi
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let videoTimebase: CMTimebase
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var audioSynchronizer: AVSampleBufferRenderSynchronizer?
    private var engine: GAV1Player?
    private let pumpQueue = DispatchQueue(label: "av1.software.pump", qos: .userInitiated)
    private var atEOF = false
    private var stopFlag = false
    private var pumpActive = false
    private let stopLock = NSLock()
    private var loop = false
    private var rate: Float = 0
    private var speed: Double = 1
    private var clockPrimed = false
    private var seekFloor = CMTime.zero
    private var info = VideoInfo(height: 0, width: 0, duration: 0)
    private var positionTimer: Timer?

    var layer: CALayer { displayLayer }

    init(api: NativeVideoPlayerApi) {
        self.api = api
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        videoTimebase = tb!
        displayLayer.controlTimebase = videoTimebase
        displayLayer.videoGravity = .resizeAspect
    }

    func tryOpen(_ videoSource: VideoSource) -> Bool {
        let isUrl = videoSource.type == .network
        guard let url = isUrl ? URL(string: videoSource.path) : URL(fileURLWithPath: videoSource.path) else { return false }
        var headers = HTTPCookie.requestHeaderFields(with: SwiftNativeVideoPlayerPlugin.cookieStorage?.cookies(for: url) ?? [])
        headers.merge(videoSource.headers) { _, new in new }
        let engine = GAV1Player(url: url, headers: headers)
        guard engine.open() else { return false }
        self.engine = engine
        info = VideoInfo(height: Int(engine.videoHeight), width: Int(engine.videoWidth), duration: Int64(engine.durationSeconds * 1000))
        if engine.hasAudio {
            let renderer = AVSampleBufferAudioRenderer()
            let sync = AVSampleBufferRenderSynchronizer()
            sync.addRenderer(renderer)
            audioRenderer = renderer
            audioSynchronizer = sync
        }
        return true
    }

    func invalidate() {
        positionTimer?.invalidate()
        stopPump()
        audioSynchronizer?.setRate(0, time: .zero)
    }

    func loadVideoSource(videoSource: VideoSource) {
        api.onPlaybackReady()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.api.onPlaybackPositionChanged(position: self.getPlaybackPosition())
        }
    }

    func getVideoInfo(completion: @escaping (VideoInfo) -> Void) {
        completion(info)
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
        guard let engine = engine else { return completion() }
        let seconds = Double(position) / 1000
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        stopPump()
        setClockTime(target)
        atEOF = false
        pumpQueue.async { [weak self] in
            engine.seek(toTime: seconds)
            DispatchQueue.main.async {
                guard let self = self else { return completion() }
                self.displayLayer.flush()
                self.audioRenderer?.flush()
                self.setClockTime(target)
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
        audioRenderer?.volume = Float(volume)
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
        audioSynchronizer?.setRate(newRate, time: now)
    }

    private func setClockTime(_ time: CMTime) {
        CMTimebaseSetTime(videoTimebase, time: time)
        CMTimebaseSetRate(videoTimebase, rate: 0)
        audioSynchronizer?.setRate(0, time: time)
    }

    private func startPump(rate newRate: Float) {
        guard let engine = engine else { return }
        if stopLock.withLock({ pumpActive }) { return setClockRate(newRate) }
        stopLock.withLock { stopFlag = false; pumpActive = true }
        setClockRate(newRate)
        pumpQueue.async { [weak self] in
            engine.decode(video: { [weak self] pixelBuffer, pts, stop in
                guard let self = self else { stop.pointee = true; return }
                self.enqueueVideo(pixelBuffer, pts: pts, stop: stop)
            }, audio: { [weak self] sampleBuffer, stop in
                guard let self = self else { stop.pointee = true; return }
                self.enqueueAudio(sampleBuffer, stop: stop)
            }, completion: { [weak self] error in
                guard let self = self else { return }
                let stopped = self.stopLock.withLock { () -> Bool in
                    self.pumpActive = false
                    return self.stopFlag
                }
                if stopped { return }
                DispatchQueue.main.async {
                    guard let error = error else { return self.onStreamEnded() }
                    self.setClockRate(0)
                    self.api.onError(error)
                }
            })
        }
    }

    private func stopPump() {
        engine?.requestStop()
        stopLock.withLock { stopFlag = true }
    }

    private var stopRequested: Bool {
        stopLock.withLock { stopFlag }
    }

    private func enqueueVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, stop: UnsafeMutablePointer<ObjCBool>) {
        if pts < seekFloor { return }
        while !displayLayer.isReadyForMoreMediaData && !stopRequested {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if stopRequested { stop.pointee = true; return }

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format = format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample = sample else { return }

        if displayLayer.status == .failed { stop.pointee = true; return }
        displayLayer.enqueue(sample)
        if !clockPrimed {
            clockPrimed = true
            CMTimebaseSetTime(videoTimebase, time: pts)
            applyClockRate(rate)
        }
    }

    private func enqueueAudio(_ sampleBuffer: CMSampleBuffer, stop: UnsafeMutablePointer<ObjCBool>) {
        guard let renderer = audioRenderer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= seekFloor else { return }
        while !renderer.isReadyForMoreMediaData && clockPrimed && !stopRequested {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if stopRequested { stop.pointee = true; return }
        renderer.enqueue(sampleBuffer)
    }

    private func onStreamEnded() {
        if loop { return seekTo(position: 0) {} }
        atEOF = true
        setClockRate(0)
        api.onPlaybackEnded()
    }
}
