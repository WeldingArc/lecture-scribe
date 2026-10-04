// lecture-tap — audio input helper for 강의 받아쓰기
//
// Live mode:  lecture-tap [--duration SEC] [--ignore-stdin]
//   Captures this Mac's system audio (every app, e.g. the browser playing the lecture)
//   through a Core Audio process tap and writes 16 kHz mono float32 little-endian PCM
//   to stdout. No microphone is used; works with speakers or earphones.
//   Stops when stdin closes (parent app gone), on SIGTERM/SIGINT, or after --duration.
//
// File mode:  lecture-tap --file PATH
//   Decodes any audio/video file to the same PCM format, as fast as possible.
//
// Status and errors are JSON lines on stderr.

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

let targetRate = 16000.0

func emit(_ dict: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: dict),
          let s = String(data: d, encoding: .utf8) else { return }
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// Blocking write of the whole buffer to stdout. Returns false when the reader is gone.
func writeAll(_ data: Data) -> Bool {
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard var p = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let w = write(STDOUT_FILENO, p, left)
            if w < 0 {
                if errno == EINTR { continue }
                return false
            }
            p = p.advanced(by: w)
            left -= w
        }
        return true
    }
}

// MARK: - Core Audio property helpers

func readProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
    var addr = AudioObjectPropertyAddress(mSelector: sel,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
}

func readString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var s: CFString = "" as CFString
    return readProp(obj, sel, &s) == noErr ? (s as String) : nil
}

func defaultOutputDevice() -> AudioDeviceID {
    var id = AudioDeviceID(kAudioObjectUnknown)
    _ = readProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &id)
    return id
}

struct TapError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (OSStatus \(status))" }
}

// MARK: - Live system-audio tap

final class SystemTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private let ioQueue = DispatchQueue(label: "lecture-tap.io", qos: .userInteractive)
    private let outQueue = DispatchQueue(label: "lecture-tap.out")
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                          channels: 1, interleaved: false)!
    var onReaderGone: (() -> Void)?
    var onFormatChange: (() -> Void)?

    func start() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "강의 받아쓰기"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw TapError(step: "create tap", status: st) }

        // Tap-only private aggregate device: no physical sub-device, so earphones with a
        // microphone (AirPods) are never switched into low-quality headset mode.
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "강의 받아쓰기 Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard st == noErr else { throw TapError(step: "create aggregate device", status: st) }

        var asbd = AudioStreamBasicDescription()
        st = readProp(tapID, kAudioTapPropertyFormat, &asbd)
        guard st == noErr, let inFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError(step: "read tap format", status: st)
        }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TapError(step: "create converter", status: -1)
        }
        conv.downmix = true
        converter = conv

        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.process(inInputData, inFormat)
        }
        guard st == noErr else { throw TapError(step: "create IO proc", status: st) }
        st = AudioDeviceStart(aggID, procID)
        guard st == noErr else { throw TapError(step: "start device", status: st) }

        // Rebuild if the tap's format changes (e.g. switching to earphones with another sample rate).
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(tapID, &fmtAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.onFormatChange?()
        }

        emit(["event": "started", "mode": "system",
              "sample_rate": asbd.mSampleRate, "channels": Int(asbd.mChannelsPerFrame),
              "device": readString(defaultOutputDevice(), kAudioObjectPropertyName) ?? "?"])
    }

    private func process(_ abl: UnsafePointer<AudioBufferList>, _ inFormat: AVAudioFormat) {
        guard let conv = converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: abl, deallocator: nil),
              inBuf.frameLength > 0 else { return }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * targetRate / inFormat.sampleRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        let n = Int(outBuf.frameLength)
        guard n > 0, let ch = outBuf.floatChannelData?[0] else { return }
        let data = Data(bytes: ch, count: n * MemoryLayout<Float>.size)
        // Never block the audio callback: hand the bytes to a serial writer queue.
        outQueue.async { [weak self] in
            if !writeAll(data) { self?.onReaderGone?() }
        }
    }

    func stop() {
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            if let p = procID {
                AudioDeviceStop(aggID, p)
                AudioDeviceDestroyIOProcID(aggID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        converter = nil
    }
}

// MARK: - File decode mode

func decodeFile(_ path: String) -> Int32 {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let sem = DispatchSemaphore(value: 0)
    var tracks: [AVAssetTrack] = []
    asset.loadTracks(withMediaType: .audio) { t, _ in
        tracks = t ?? []
        sem.signal()
    }
    sem.wait()
    guard !tracks.isEmpty else {
        emit(["event": "error", "message": "no audio track in file"])
        return 3
    }
    asset.loadValuesAsynchronously(forKeys: ["duration"]) { sem.signal() }
    sem.wait()
    let total = CMTimeGetSeconds(asset.duration)
    if total.isFinite && total > 0 {
        emit(["event": "duration", "seconds": total])
    }
    guard let reader = try? AVAssetReader(asset: asset) else {
        emit(["event": "error", "message": "cannot open file"])
        return 3
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: targetRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
    reader.add(output)
    guard reader.startReading() else {
        emit(["event": "error", "message": "cannot start reading file"])
        return 3
    }
    var samples = 0
    while let sb = output.copyNextSampleBuffer() {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
        let len = CMBlockBufferGetDataLength(bb)
        var data = Data(count: len)
        let st = data.withUnsafeMutableBytes { buf in
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: buf.baseAddress!)
        }
        if st != kCMBlockBufferNoErr { continue }
        if !writeAll(data) { return 0 }
        samples += len / MemoryLayout<Float>.size
    }
    emit(["event": "file_done", "seconds": Double(samples) / targetRate,
          "completed": reader.status == .completed])
    return reader.status == .completed ? 0 : 4
}

// MARK: - Main

let args = CommandLine.arguments
signal(SIGPIPE, SIG_IGN)

if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
    exit(decodeFile(args[i + 1]))
}

let tap = SystemTap()
var restarting = false

func shutdown(_ code: Int32) {
    tap.stop()
    emit(["event": "stopped"])
    exit(code)
}

func restart(_ reason: String) {
    if restarting { return }
    restarting = true
    // Debounce: device switches fire several notifications in a row.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        tap.stop()
        do {
            try tap.start()
            emit(["event": "restarted", "reason": reason])
        } catch {
            emit(["event": "error", "message": "restart: \(error)"])
            shutdown(2)
        }
        restarting = false
    }
}

tap.onReaderGone = { DispatchQueue.main.async { shutdown(0) } }
tap.onFormatChange = { restart("format") }

do {
    try tap.start()
} catch {
    emit(["event": "error", "message": "\(error)"])
    exit(2)
}

var devAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                         mScope: kAudioObjectPropertyScopeGlobal,
                                         mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, DispatchQueue.main) { _, _ in
    restart("output device changed")
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigTerm.setEventHandler { shutdown(0) }
sigTerm.resume()
let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigInt.setEventHandler { shutdown(0) }
sigInt.resume()

if !args.contains("--ignore-stdin") {
    // The parent app keeps our stdin open; EOF means it quit or crashed.
    Thread.detachNewThread {
        var buf = [UInt8](repeating: 0, count: 64)
        while read(STDIN_FILENO, &buf, buf.count) > 0 {}
        DispatchQueue.main.async { shutdown(0) }
    }
}

if let i = args.firstIndex(of: "--duration"), i + 1 < args.count, let sec = Double(args[i + 1]) {
    DispatchQueue.main.asyncAfter(deadline: .now() + sec) { shutdown(0) }
}

dispatchMain()
