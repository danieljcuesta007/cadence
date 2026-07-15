// AudioCapture — mic → 16 kHz mono i16 chunks for the core ring buffer (§16.1, §18 step 2).
//
// AVAudioEngine (CoreAudio-backed) tap at the device's native format, resampled per chunk
// through AVAudioConverter. Chunks are delivered on the audio tap thread; the core's
// `push_audio` is audio-thread-safe by contract, so the callback forwards directly.

import AVFoundation

public enum CaptureError: Error, CustomStringConvertible {
    case formatUnavailable
    case engineStart(Error)

    public var description: String {
        switch self {
        case .formatUnavailable:
            return "no usable input format (mic permission missing or no input device?)"
        case .engineStart(let e):
            return "audio engine start failed: \(e.localizedDescription)"
        }
    }
}

public final class AudioCapture {
    private let engine = AVAudioEngine()
    private var running = false

    /// (samples16k, level 0…1) — called on the audio tap thread.
    public var onChunk: (([Int16], Float) -> Void)?

    public init() {}

    public static func micAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Resolves mic permission, prompting if undetermined (§10.1: just-in-time, with payoff).
    public static func requestMicAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: done)
        default: done(false)
        }
    }

    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                interleaved: true),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw CaptureError.formatUnavailable }

        // ~43 ms buffers at 48 kHz: small enough that the ring is near-live, big enough to
        // keep the tap cheap.
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self, let onChunk = self.onChunk else { return }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
            else { return }
            var fed = false
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData
            else { return }
            let n = Int(out.frameLength)
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
            var acc: Float = 0
            for s in samples {
                let f = Float(s) / 32768
                acc += f * f
            }
            let rms = (acc / Float(max(n, 1))).squareRoot()
            onChunk(samples, min(1.0, rms * 6)) // speech RMS ~0.05–0.15 → usable 0…1 level
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStart(error)
        }
        running = true
    }

    /// Synchronous stop. After return, in-flight tap callbacks have had time to land their
    /// samples, so the caller may safely confirm `capture_stopped` (no-lost-words contract).
    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        Thread.sleep(forTimeInterval: 0.02)
    }
}
