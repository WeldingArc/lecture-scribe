// Audio sources for 강의 받아쓰기 v2. Every source delivers 16 kHz mono Int16 PCM — the format
// Apple's SpeechAnalyzer asks for — through a callback, from its own queue.

import AVFoundation
import AudioToolbox
#if os(macOS)
import CoreAudio
#else
import UIKit
#endif
import Foundation

let sampleRate = 16000.0
let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
private let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

protocol AudioSource: AnyObject {
    /// Called with 16 kHz mono Int16 buffers. `nil` means the source ended (files only).
    var onBuffer: ((AVAudioPCMBuffer?) -> Void)? { get set }
    /// Something the user should know mid-recording: (notice code, message). Any thread.
    var onProblem: ((String, String) -> Void)? { get set }
    func start() throws
    func stop()
}

/// Float32 → Int16 (the analyzer's format) without allocating a converter per buffer.
func int16Buffer(from f: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let n = Int(f.frameLength)
    guard n > 0, let src = f.floatChannelData?[0],
          let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)) else { return nil }
    out.frameLength = AVAudioFrameCount(n)
    let dst = out.int16ChannelData![0]
    for i in 0..<n { dst[i] = Int16(max(-1, min(1, src[i])) * 32767) }
    return out
}

struct CaptureError: Error, CustomStringConvertible {
    let step: String, status: OSStatus
    var description: String { "\(step) (\(status))" }
}

#if os(macOS)
// MARK: - System audio (Core Audio process tap, macOS 14.2+)

private func readProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
}

/// Everything this Mac plays (all apps), mixed to mono. No microphone; works with earphones.
/// A tap-only private aggregate device is used so AirPods never switch to headset mode.
final class SystemAudioSource: AudioSource {
    var onBuffer: ((AVAudioPCMBuffer?) -> Void)?
    var onProblem: ((String, String) -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private let ioQueue = DispatchQueue(label: "lecture.capture", qos: .userInteractive)
    private var listening = false
    private var listener: AudioObjectPropertyListenerBlock?
    private static var outputDeviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                                       mElement: kAudioObjectPropertyElementMain)

    deinit {                                   // safety net: never leave a tap or device behind
        if let l = listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &SystemAudioSource.outputDeviceAddress, ioQueue, l)
        }
        teardown()
    }

    /// Start and stop run on the capture queue, one after the other: a 정지 during start-up tears down
    /// whatever start created, instead of leaving the tap running after the save.
    func start() throws { try ioQueue.sync { try startLocked() } }

    private func startLocked() throws {
        guard !stopped else { return }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "강의 받아쓰기"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        log("capture: creating tap")
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        log("capture: create tap → \(st)")
        guard st == noErr else { throw CaptureError(step: "create tap", status: st) }

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "강의 받아쓰기 Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        log("capture: aggregate device → \(st)")
        guard st == noErr else { teardown(); throw CaptureError(step: "create aggregate device", status: st) }

        var asbd = AudioStreamBasicDescription()
        st = readProp(tapID, kAudioTapPropertyFormat, &asbd)
        guard st == noErr, let inFormat = AVAudioFormat(streamDescription: &asbd),
              let conv = AVAudioConverter(from: inFormat, to: floatFormat) else {
            teardown(); throw CaptureError(step: "tap format", status: st)
        }
        log("capture: tap format \(asbd.mSampleRate) Hz × \(asbd.mChannelsPerFrame)")
        conv.downmix = true
        converter = conv

        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { [weak self] _, input, _, _, _ in
            self?.process(input, inFormat)
        }
        guard st == noErr else { teardown(); throw CaptureError(step: "create IO proc", status: st) }
        st = AudioDeviceStart(aggID, procID)
        log("capture: start device → \(st)")
        guard st == noErr else { teardown(); throw CaptureError(step: "start device", status: st) }
        listenForDeviceChanges()
        if stopped { teardown() }                          // 정지 arrived while macOS was busy starting
    }

    private var callbacks = 0
    private var stopped = false

    private func process(_ abl: UnsafePointer<AudioBufferList>, _ inFormat: AVAudioFormat) {
        guard !stopped else { return }
        callbacks += 1
        if callbacks == 1 || callbacks == 200 { log("capture: audio callback #\(callbacks)") }
        guard let conv = converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: abl, deallocator: nil),
              inBuf.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: floatFormat,
                                         frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * sampleRate / inFormat.sampleRate) + 64)
        else { return }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let pcm = int16Buffer(from: out) { onBuffer?(pcm) }
    }

    /// Switching speakers ↔ earphones changes the tap's format: rebuild the capture.
    private func listenForDeviceChanges() {
        guard !listening else { return }
        listening = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped, self.aggID != AudioObjectID(kAudioObjectUnknown) else { return }
            self.teardown()
            do { try self.startLocked() } catch {
                log("capture: rebuild after output change failed: \(error)")
                self.onProblem?("capture_stopped", "출력 장치가 바뀐 뒤 소리를 다시 가져오지 못했어요. [정지]를 누른 뒤 다시 시작해 주세요.")
            }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &SystemAudioSource.outputDeviceAddress, ioQueue, block)
    }

    private func teardown() {
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        converter = nil
    }

    /// Never blocks the caller: Core Audio calls can hang while macOS is busy with permissions.
    func stop() {
        stopped = true
        ioQueue.async { [self] in
            if let l = listener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &SystemAudioSource.outputDeviceAddress, ioQueue, l)
                listener = nil
            }
            teardown()
        }
    }
}

#endif

#if os(iOS)
// MARK: - Microphone (iPhone/iPad)

/// The device microphone: a lecture playing nearby (laptop, TV) or in the room. Keeps recording with
/// the screen locked (background audio); pauses for calls and picks up again afterwards (also when iOS
/// never says the call ended: on return to the app); rebuilds itself after route changes or a
/// media-services reset; tells the user if it can't, and says so again when it recovers.
/// All engine work happens on the main thread, so start, stop and restarts never overlap.
final class MicAudioSource: AudioSource {
    var onBuffer: ((AVAudioPCMBuffer?) -> Void)?
    var onProblem: ((String, String) -> Void)?
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
    private var running = false             // between start() and stop()
    private var stopRequested = false
    private var interrupted = false         // a call or another app has the audio session
    private var interruptedAt = Date.distantPast
    private var troubled = false            // a pause/stop notice is showing: say when it's fine again
    private var attempt = 0
    private var lastQuietTry = Date.distantPast
    private var retry: DispatchWorkItem?
    private var stallTimer: Timer?
    private var lastBuffer = Date()
    private let lock = NSLock()

    private func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try s.setActive(true)
    }

    func start() throws {
        if Thread.isMainThread { try startOnMain() } else { try DispatchQueue.main.sync { try startOnMain() } }
    }

    private func startOnMain() throws {
        guard !stopRequested else { return }
        try configureSession()
        try startEngine()
        running = true
        log("capture: microphone \(engine.inputNode.outputFormat(forBus: 0).sampleRate) Hz")
        let nc = NotificationCenter.default, session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                log("capture: interrupted")
                self.interrupted = true
                self.interruptedAt = Date()
                self.tell("capture_paused", "전화나 다른 앱 때문에 녹음이 잠시 멈췄어요. 끝나면 이어서 녹음해요.")
            } else {
                log("capture: interruption ended, resuming")
                self.interrupted = false
                self.restart()
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            log("capture: media services reset, rebuilding")
            guard let self, self.running else { return }
            self.engine = AVAudioEngine()                      // the old engine is dead: just let it go
            self.restart()
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            if !self.interrupted { if self.attempt >= 4 { self.restart() }; return }             // gave up earlier: try again now
            guard (try? self.configureSession()) != nil else { return }                          // still in a call
            log("capture: back in the app while paused, resuming")  // iOS doesn't always send "ended"
            self.interrupted = false
            self.restart()
        })
        stallTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkStall() }
        if stopRequested { stopOnMain() }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0, let conv = AVAudioConverter(from: fmt, to: floatFormat) else {
            throw CaptureError(step: "microphone", status: -1)
        }
        conv.downmix = true
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in self?.process(buf) }
        if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            log("capture: audio route changed")
            self?.restart()
        }
        engine.prepare()
        try engine.start()
        lock.lock(); lastBuffer = Date(); lock.unlock()
    }

    private func tell(_ code: String, _ msg: String) {
        troubled = code != "capture_resumed"
        onProblem?(code, msg)
    }

    /// Restart the engine (route change, end of a call, stall). One retry chain at a time: 1, 3, 10 s.
    private func restart() {
        guard running, !interrupted else { return }
        retry?.cancel(); retry = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try configureSession()
            try startEngine()
            attempt = 0
            if troubled { tell("capture_resumed", "녹음을 다시 이어서 해요.") }
        } catch {
            attempt += 1
            log("capture: restart failed (\(attempt)): \(error)")
            if attempt <= 3 {
                let work = DispatchWorkItem { [weak self] in self?.restart() }
                retry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + [1.0, 3.0, 10.0][attempt - 1], execute: work)
            } else if attempt == 4 {
                lastQuietTry = Date()
                tell("capture_stopped", "마이크 녹음이 멈췄어요. [정지]를 누른 뒤 다시 시작해 주세요. 지금까지의 녹음은 저장돼요.")
            }
        }
    }

    private func checkStall() {
        guard running else { return }
        if interrupted {                     // a pause iOS never ended: once a minute, see if the audio is free again
            if Date().timeIntervalSince(interruptedAt) > 60 {
                interruptedAt = Date()
                if (try? configureSession()) != nil { interrupted = false; restart() }   // still in a call: stays paused, quietly
            }
            return
        }
        if attempt >= 4 {                    // gave up and said so: keep trying quietly (e.g. the call finally ended)
            if Date().timeIntervalSince(lastQuietTry) > 30 { lastQuietTry = Date(); restart() }
            return
        }
        guard retry == nil else { return }
        lock.lock(); let quiet = Date().timeIntervalSince(lastBuffer); lock.unlock()
        if quiet > 6 {
            log("capture: no buffers for \(Int(quiet)) s, restarting")
            restart()
        }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        lock.lock(); lastBuffer = Date(); lock.unlock()
        guard let conv = converter, buf.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: floatFormat,
                                         frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * sampleRate / buf.format.sampleRate) + 64)
        else { return }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if let pcm = int16Buffer(from: out) { onBuffer?(pcm) }
    }

    func stop() {
        if Thread.isMainThread { stopOnMain() } else { DispatchQueue.main.async { self.stopOnMain() } }
    }

    private func stopOnMain() {
        stopRequested = true
        guard running else { return }
        running = false
        retry?.cancel(); retry = nil
        stallTimer?.invalidate(); stallTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let o = engineObserver { NotificationCenter.default.removeObserver(o); engineObserver = nil }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif

// MARK: - Files (any audio/video AVFoundation can read)

/// Decodes a media file. `realtime` paces delivery like live audio (used by silent tests);
/// otherwise it runs as fast as the decoder can.
final class FileAudioSource: AudioSource {
    var onBuffer: ((AVAudioPCMBuffer?) -> Void)?
    var onProblem: ((String, String) -> Void)?
    let url: URL
    let realtime: Bool
    private(set) var duration: Double = 0
    private var cancelled = false
    private var reader: AVAssetReader?          // must outlive the read loop (a freed reader raises, crashing the app)
    private let queue = DispatchQueue(label: "lecture.file", qos: .userInitiated)

    init(url: URL, realtime: Bool = false) {
        self.url = url
        self.realtime = realtime
    }

    func start() throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])   // VBR mp3: real length
        let sem = DispatchSemaphore(value: 0)
        var tracks: [AVAssetTrack] = []
        var loadedDuration = CMTime.zero
        Task {
            tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            var audioEnd = 0.0                                 // the sound's own length, not the video's
            for t in tracks { if let r = try? await t.load(.timeRange), r.end.seconds.isFinite { audioEnd = max(audioEnd, r.end.seconds) } }
            loadedDuration = audioEnd > 0 ? CMTime(seconds: audioEnd, preferredTimescale: 600) : ((try? await asset.load(.duration)) ?? .zero)
            sem.signal()
        }
        if sem.wait(timeout: .now() + 60) == .timedOut {      // a hung network drive, an iCloud file still downloading
            if cancelled { return }                            // 정지 already ended this session: stay quiet
            throw CaptureError(step: "file took too long to open", status: -3)
        }
        guard !cancelled else { return }
        guard !tracks.isEmpty else { throw CaptureError(step: "no audio track", status: -1) }
        duration = loadedDuration.seconds.isFinite ? loadedDuration.seconds : 0
        let reader = try AVAssetReader(asset: asset)
        self.reader = reader
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw CaptureError(step: "read file", status: -2) }
        queue.async { [weak self, reader, output] in
            let t0 = Date()
            var sent = 0
            while let self, !self.cancelled, reader.status == .reading, let sb = output.copyNextSampleBuffer() {
                guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
                let bytes = CMBlockBufferGetDataLength(bb)
                let frames = bytes / 2
                guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else { continue }
                buf.frameLength = AVAudioFrameCount(frames)
                CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: buf.int16ChannelData![0])
                self.onBuffer?(buf)
                sent += frames
                if self.realtime {
                    let ahead = Double(sent) / sampleRate - Date().timeIntervalSince(t0)
                    if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
                }
            }
            let got = Double(sent) / sampleRate
            if reader.status == .failed {
                log("file read failed: \(String(describing: reader.error))")
                self?.onProblem?("file_error", got > 1 ? "파일을 끝까지 읽지 못했어요. 파일이 손상됐을 수 있어요 — 읽은 부분까지만 받아 적었어요."
                                                       : "이 파일에서 소리를 읽을 수 없어요. 파일이 손상됐을 수 있어요.")
            } else if let me = self, !me.cancelled, me.duration > 5, got < me.duration * 0.9 {   // e.g. a WAV cut short
                log("file ended early: \(Int(got)) of \(Int(me.duration)) s")
                me.onProblem?("file_error", "파일이 중간에 끊겨 있어요 — 앞부분(\(fmtTime(got)))까지만 받아 적었어요.")
            }
            self?.onBuffer?(nil)
        }
    }

    func stop() { cancelled = true }
}
