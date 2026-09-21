import AVFoundation
import Flutter
import Foundation

public class NativeVideoPlayerViewController: NSObject, FlutterPlatformView {
    private let api: NativeVideoPlayerApi
    private let player: AVPlayer
    private let playerView: NativeVideoPlayerView
    private var loop = false
    private var lastPosition: Int64 = -1
    private var timeObserver: Any?
    private var timeControlObserver: NSKeyValueObservation?

    // ADDITIVE (AV1 software path): when non-nil, this backend owns playback
    // and every delegate method below forwards to it. When nil, the original
    // AVPlayer code path runs byte-for-byte as before. The backend is engaged
    // only for AV1 sources on devices without an AV1 hardware decoder.
    private var swPlayer: AV1SoftwarePlayer?
    private let probeQueue = DispatchQueue(label: "av1.probe", qos: .userInitiated)
    // If play() arrives while the codec probe is still running, remember it
    // and start playback as soon as the backend is ready.
    private var pendingPlay = false
    private var probeInFlight = false

    init(
        messenger: FlutterBinaryMessenger,
        viewId: Int64,
        frame: CGRect,
    ) {
        api = NativeVideoPlayerApi(
            messenger: messenger,
            viewId: viewId
        )
        player = AVPlayer()
        playerView = NativeVideoPlayerView(frame: frame, player: player)
        super.init()
        
        api.delegate = self
        player.addObserver(self, forKeyPath: "status", context: nil)
        
        // Play audio even when the device is in silent mode
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set playback audio session. Error: \(error)")
        }
    }
    
    deinit {
        player.removeObserver(self, forKeyPath: "status")
        timeControlObserver?.invalidate()
        removeOnVideoCompletedObserver()
        removePeriodicTimeObserver()

        player.replaceCurrentItem(with: nil)
    }
    
    public func view() -> UIView {
        playerView
    }
    
}

extension NativeVideoPlayerViewController: NativeVideoPlayerApiDelegate {
    func loadVideoSource(videoSource: VideoSource) {
        GAV1FileLog.line(String(format: "ctl load type=%@ path=%@", videoSource.type.rawValue, videoSource.path))
        // ADDITIVE: on devices without an AV1 hardware decoder, try the
        // software backend first — it validates AV1 itself and fails fast
        // for anything else, in which case we run the original AVPlayer
        // code below, untouched. Devices WITH hardware AV1 skip this
        // entirely: zero behavior change.
        guard !AV1Capability.hasHardwareDecoder else {
            loadVideoSourceNative(videoSource)
            return
        }
        probeInFlight = true
        pendingPlay = false
        probeQueue.async { [weak self] in
            guard let self = self else { return }
            let sw = AV1SoftwarePlayer(api: self.api)
            let opened = sw.tryOpen(videoSource)
            DispatchQueue.main.async {
                self.probeInFlight = false
                if opened {
                    self.activateSoftware(sw, videoSource: videoSource)
                    if self.pendingPlay {
                        self.pendingPlay = false
                        sw.play()
                    }
                } else {
                    self.deactivateSoftwarePlayer()
                    self.loadVideoSourceNative(videoSource)
                    if self.pendingPlay {
                        self.pendingPlay = false
                        self.play()
                    }
                }
            }
        }
    }

    // ADDITIVE: engage an already-opened software backend.
    private func activateSoftware(_ sw: AV1SoftwarePlayer, videoSource: VideoSource) {
        // Park the AVPlayer so it holds no item and emits no callbacks.
        removeOnVideoCompletedObserver()
        player.replaceCurrentItem(with: nil)
        removePeriodicTimeObserver()
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        lastPosition = -1

        // Drop any previous SW backend (its layer and engine are released).
        if let old = swPlayer {
            old.layer.removeFromSuperlayer()
        }
        swPlayer = sw
        api.delegate = sw
        // The platform view's final bounds may not be applied yet (Flutter
        // sizes it after creation). Lay out first, then size the decode
        // layer to the real bounds so the very first frame is not shown at
        // the wrong aspect / size.
        playerView.setNeedsLayout()
        playerView.layoutIfNeeded()
        sw.layer.frame = playerView.bounds
        playerView.layer.addSublayer(sw.layer)
        sw.loadVideoSource(videoSource: videoSource)
    }

    // ADDITIVE: return to the native backend (restores api.delegate).
    private func deactivateSoftwarePlayer() {
        if let sw = swPlayer {
            sw.layer.removeFromSuperlayer()
            swPlayer = nil
        }
        api.delegate = self
    }

    private func loadVideoSourceNative(_ videoSource: VideoSource) {
        let isUrl = videoSource.type == .network
        let sourcePath = videoSource.path
        guard let uri = isUrl ? URL(string: sourcePath) : URL(fileURLWithPath: sourcePath) else { return }

        let videoAsset: AVAsset
        if isUrl, #available(iOS 15.0, *), let proxyURL = VideoProxyServer.shared.proxyURL(for: uri) {
            videoAsset = AVURLAsset(url: proxyURL)
        } else if isUrl {
            var headers = HTTPCookie.requestHeaderFields(with: SwiftNativeVideoPlayerPlugin.cookieStorage?.cookies(for: uri) ?? [])
            headers.merge(videoSource.headers) { _, new in new }
            videoAsset = AVURLAsset(url: uri, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            videoAsset = AVAsset(url: uri)
        }

        let playerItem = AVPlayerItem(asset: videoAsset)
        removeOnVideoCompletedObserver()
        player.replaceCurrentItem(with: playerItem)
        addOnVideoCompletedObserver()
        timeControlObserver = addTimeControlObserver(currentItem: playerItem)
        api.onPlaybackReady()
        addPeriodicTimeObserver()
    }

    func getVideoInfo(completion: @escaping (VideoInfo) -> Void) {
        if #available(iOS 15, *) {
            getVideoInfoAsync(completion: completion)
        } else {
            getVideoInfoLegacy(completion: completion)
        }
    }

    @available(iOS 15, *)
    private func getVideoInfoAsync(completion: @escaping (VideoInfo) -> Void) {
        guard let asset = player.currentItem?.asset else {
            return completion(VideoInfo(height: 0, width: 0, duration: 0))
        }
        Task {
            do {
                async let d = asset.load(.duration)
                async let t = asset.loadTracks(withMediaType: .video)

                let duration = try await d
                let size = try await t.first?.load(.naturalSize) ?? .zero

                let info = VideoInfo(
                    height: Int(size.height),
                    width: Int(size.width),
                    duration: Int64(duration.seconds * 1000)
                )
                completion(info)
            } catch {
                completion(VideoInfo(height: 0, width: 0, duration: 0))
            }
        }
    }
    
    private func getVideoInfoLegacy(completion: @escaping (VideoInfo) -> Void) {
        guard let asset = player.currentItem?.asset else {
            return completion(VideoInfo(height: 0, width: 0, duration: 0))
        }

        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
            let duration: Int64
            if asset.statusOfValue(forKey: "duration", error: nil) == .loaded {
                duration = Int64(asset.duration.seconds * 1000)
            } else {
                duration = 0
            }

            var width = 0, height = 0
            if asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
            let track = asset.tracks(withMediaType: .video).first {
                track.loadValuesAsynchronously(forKeys: ["naturalSize"]) {
                    if track.statusOfValue(forKey: "naturalSize", error: nil) == .loaded {
                        width = Int(track.naturalSize.width)
                        height = Int(track.naturalSize.height)
                    }
                    completion(VideoInfo(height: height, width: width, duration: duration))
                }
                return
            }

            completion(VideoInfo(height: height, width: width, duration: duration))
        }
    }
    
    func play() {
        // ADDITIVE: a play() landing while the codec probe is still running
        // would hit the idle AVPlayer and get lost. Remember it instead.
        if probeInFlight {
            pendingPlay = true
            return
        }
        if player.currentItem?.currentTime() == player.currentItem?.duration {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }
    
    func pause() {
        player.pause()
    }
    
    func stop(completion: @escaping () -> Void) {
        player.pause()
        if #available(iOS 15, *) {
            // on iOS 15 or newer
            player.seek(to: CMTime.zero) { _ in completion() }
        } else {
            player.seek(to: CMTime.zero)
            completion()
        }
    }
    
    func isPlaying() -> Bool {
        player.rate != 0 && player.error == nil
    }
    
    func seekTo(position: Int64, completion: @escaping () -> Void) {
        player.seek(
            to: CMTime(value: position, timescale: 1000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { _ in
            completion()
        }
    }
    
    func getPlaybackPosition() -> Int64 {
        guard let currentItem = player.currentItem else { return 0 }
        let currentTime = currentItem.currentTime()
        return currentTime.isValid ? Int64(currentTime.seconds * 1000) : 0
    }
    
    func setPlaybackSpeed(speed: Double) {
        player.rate = Float(speed)
    }
    
    func setVolume(volume: Double) {
        player.volume = Float(volume)
    }
    
    func setLoop(loop: Bool) {
        self.loop = loop
    }
}

extension NativeVideoPlayerViewController {
    override public func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "status", player.status == .failed, let error = player.error else { return }
        api.onError(error)
    }
}

extension NativeVideoPlayerViewController {
    @objc
    private func onVideoCompleted(notification: NSNotification) {
        if loop {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        } else {
            api.onPlaybackEnded()
        }
    }
    
    private func addOnVideoCompletedObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVideoCompleted(notification:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
    }
    
    private func removeOnVideoCompletedObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
    }

    private func addTimeControlObserver(currentItem: AVPlayerItem) -> NSKeyValueObservation {
        return currentItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            if item.isPlaybackLikelyToKeepUp,
               self?.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                // AVPlayer can sometimes get stuck
                DispatchQueue.main.async { [weak self] in self?.player.play() }
            }
        }
    }

    private func addPeriodicTimeObserver() {
        removePeriodicTimeObserver()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0/120.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            let position = Int64(time.seconds * 1000)
            if lastPosition != position {
                lastPosition = position
                self.api.onPlaybackPositionChanged(position: position)
            }
        }
    }

    private func removePeriodicTimeObserver() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
}
