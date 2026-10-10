// Plays a session's recording for the library: play/pause, seek (a tap on any transcript line),
// ±15 s and speed. The page draws the controls; this reports the position a few times a second.

import AVFoundation
#if os(iOS)
import MediaPlayer
#endif

@MainActor
final class Player: NSObject, AVAudioPlayerDelegate {
    var emit: ([String: Any]) -> Void = { _ in }
    private var player: AVAudioPlayer?
    private(set) var id: String?
    private var title = ""
    private var timer: Timer?
    private var rate: Float = 1

    override init() {
        super.init()
        #if os(iOS)
        let rc = MPRemoteCommandCenter.shared()                     // lock screen and earphone controls
        rc.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.play() }; return .success }
        rc.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        rc.skipBackwardCommand.preferredIntervals = [15]
        rc.skipForwardCommand.preferredIntervals = [15]
        rc.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(-15) }; return .success }
        rc.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(15) }; return .success }
        rc.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { MainActor.assumeIsolated { self?.seek(e.positionTime) } }
            return .success
        }
        #endif
    }

    var playing: Bool { player?.isPlaying ?? false }

    /// Opens a recording (paused at the start). Re-opening the current one keeps its position.
    func load(id: String, url: URL, title: String) {
        if self.id == id, player != nil { report(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { report(); return }
        p.enableRate = true
        p.rate = rate
        p.delegate = self
        p.prepareToPlay()
        player = p
        self.id = id
        self.title = title
        report()
    }

    func play(at t: Double? = nil) {
        guard let p = player else { return }
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio)
        try? s.setActive(true)
        #endif
        if let t { p.currentTime = max(0, min(t, p.duration - 0.05)) }
        if p.currentTime >= p.duration - 0.05 { p.currentTime = 0 }
        p.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }

    func pause() {
        player?.pause()
        timer?.invalidate(); timer = nil
        report()
    }

    func toggle() { playing ? pause() : play() }

    func seek(_ t: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        report()
    }

    func skip(_ d: Double) { if let p = player { seek(p.currentTime + d) } }

    /// The session was renamed: same recording (its file stays open), new id.
    func renamed(from old: String, to new: String) {
        guard id == old else { return }
        id = new
        title = new
        report()
    }

    func setRate(_ r: Float) {
        rate = max(0.5, min(2, r))
        player?.rate = rate
        report()
    }

    func stop() {
        player?.stop()
        player = nil
        id = nil
        timer?.invalidate(); timer = nil
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    var position: Double { player?.currentTime ?? 0 }

    func report() {
        let p = player
        emit(["ev": "player", "id": id ?? "", "t": ((p?.currentTime ?? 0) * 100).rounded() / 100,
              "dur": ((p?.duration ?? 0) * 100).rounded() / 100, "playing": p?.isPlaying ?? false, "rate": rate])
        #if os(iOS)
        if let p {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: L("Arc 강의 받아쓰기", "Arc Lecture Transcriber"),
                MPMediaItemPropertyPlaybackDuration: p.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: p.currentTime,
                MPNowPlayingInfoPropertyPlaybackRate: p.isPlaying ? Double(rate) : 0,
            ]
        }
        #endif
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.timer?.invalidate(); self.timer = nil
            self.report()
        }
    }
}
