// AudioCapture — mic → 16 kHz mono i16 chunks for the core ring buffer (§16.1, §18 step 2).
//
// AVAudioEngine (CoreAudio-backed) tap at the device's native format, resampled per chunk
// through AVAudioConverter. Chunks are delivered on the audio tap thread; the core's
// `push_audio` is audio-thread-safe by contract, so the callback forwards directly.
//
// Warm-path design (§28: perceived capture start ≤ 50 ms): the tap + converter are built
// ONCE (and rebuilt only on an audio-route change) — the first live run measured 85–94 ms
// with per-start tap install + cold engine.start(). The engine is fully stopped between
// utterances so the mic-in-use indicator tracks actual listening (§10 privacy), but
// prepare() re-arms immediately after stop; if live numbers are still over target, the
// next lever is engine.pause() — verify the orange dot goes off before shipping that.

import AVFoundation
import CObjCCatch
import CoreAudio

public enum CaptureError: Error, CustomStringConvertible {
    case formatUnavailable
    case engineStart(Error)
    case tapInstall(String)

    public var description: String {
        switch self {
        case .formatUnavailable:
            return "no usable input format (mic permission missing or no input device?)"
        case .engineStart(let e):
            return "audio engine start failed: \(e.localizedDescription)"
        case .tapInstall(let reason):
            return "tap install rejected by AVFAudio: \(reason)"
        }
    }
}

public final class AudioCapture {
    // var, not let: recreated outright when a route change leaves it serving stale
    // formats (reset() proved insufficient live — see start()).
    private var engine = AVAudioEngine()
    private var running = false
    private var tapInstalled = false
    private var tapFormat: AVAudioFormat?
    private var routeChangeObserver: NSObjectProtocol?
    private var rebuildWork: DispatchWorkItem?

    /// (samples16k, level 0…1) — called on the audio tap thread. Only fires while running:
    /// the tap checks this flag so a buffer straggling in after stop() is still delivered
    /// (no-lost-words), but nothing arrives once the engine is stopped.
    public var onChunk: (([Int16], Float) -> Void)?

    /// Prefer the built-in mic over the system default input (default ON). Bluetooth
    /// headsets as input mean telephony-mode audio — muffled 16 kHz HFP that whisper
    /// mangles — AND the user's music drops to the same codec. The Mac's mic array beats
    /// both; in-ear playback can't leak into it either.
    public var preferBuiltInMic = true

    public func setPreferBuiltInMic(_ on: Bool) {
        guard on != preferBuiltInMic else { return }
        preferBuiltInMic = on
        guard !running else { return } // mid-capture: applies at the next start
        recreateEngine()
        prewarm()
    }

    /// Human-readable current input ("MacBook Pro Microphone @ 48000 Hz") for the log.
    public var inputDescription: String {
        let fmt = engine.inputNode.inputFormat(forBus: 0)
        var name = "default input"
        if let unit = engine.inputNode.audioUnit {
            var dev = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &dev, &size) == noErr, dev != 0, let n = Self.deviceName(dev) {
                name = n
            }
        }
        return "\(name) @ \(Int(fmt.sampleRate)) Hz"
    }

    // MARK: - CoreAudio device selection

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &nameRef) == noErr,
            let name = nameRef?.takeRetainedValue()
        else { return nil }
        return name as String
    }

    /// The built-in input device (transport type built-in, has input streams), or nil
    /// (clamshell-less Macs, hypothetical headless boxes) — callers fall back to default.
    private static func builtInInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else {
            return nil
        }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else {
            return nil
        }
        for id in ids {
            var taddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport) == noErr,
                transport == kAudioDeviceTransportTypeBuiltIn
            else { continue }
            var saddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var ssize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &ssize) == noErr,
                ssize > 0
            else { continue }
            return id
        }
        return nil
    }

    public init() {}

    deinit {
        if let o = routeChangeObserver { NotificationCenter.default.removeObserver(o) }
    }

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

    /// Pay the one-time costs (tap install, converter build, engine prepare) at app load
    /// instead of on the first key-down. Does NOT start audio I/O — no mic indicator.
    /// Safe to call without mic permission (start() will re-derive if this failed).
    public func prewarm() {
        try? ensureTap()
        engine.prepare()
    }

    public func start() throws {
        guard !running else { return }
        do {
            try startOnce()
        } catch {
            // Route changed under a stale tap. reset() proved insufficient live
            // (2026-07-19 13:03–13:06: four consecutive tap rejections, every dictation
            // cancelling) — an AVAudioEngine can keep serving stale formats for the life
            // of the object. Recreate it outright and retry once.
            recreateEngine()
            try startOnce()
        }
        running = true
    }

    private func startOnce() throws {
        try ensureTap()
        do { try engine.start() } catch { throw CaptureError.engineStart(error) }
    }

    /// Nuclear route-change recovery: discard the engine (its tap dies with it) and start
    /// clean. The config-change observer is engine-bound, so it is re-registered by the
    /// next ensureTap.
    private func recreateEngine() {
        if let o = routeChangeObserver {
            NotificationCenter.default.removeObserver(o)
            routeChangeObserver = nil
        }
        rebuildWork?.cancel()
        engine.stop()
        tapInstalled = false
        tapFormat = nil
        engine = AVAudioEngine()
    }

    /// Synchronous stop. After return, in-flight tap callbacks have had time to land their
    /// samples, so the caller may safely confirm `capture_stopped` (no-lost-words contract).
    /// Full engine stop (not pause) so the mic-in-use indicator turns off with the capture;
    /// the tap stays installed and prepare() re-arms immediately, keeping the next start warm.
    public func stop() {
        guard running else { return }
        engine.stop()
        running = false
        Thread.sleep(forTimeInterval: 0.02)
        engine.prepare()
    }

    // MARK: - warm tap

    private func ensureTap() throws {
        if tapInstalled {
            // Trust the format, not the flag: a route change the observer missed (or one
            // that landed mid-debounce) leaves a tap bound to the old sample rate.
            let current = engine.inputNode.inputFormat(forBus: 0)
            if let f = tapFormat, f.sampleRate == current.sampleRate,
                f.channelCount == current.channelCount {
                return
            }
            teardownTap()
        }
        let input = engine.inputNode
        // Pin the built-in mic (when preferred and present) BEFORE reading the format:
        // the AUHAL otherwise follows the system default input, i.e. whatever Bluetooth
        // headset connected last. Failure to pin falls through to the default silently.
        if preferBuiltInMic, let dev = Self.builtInInputDevice(), let unit = input.audioUnit {
            var id = dev
            _ = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        // The HARDWARE format, not outputFormat(forBus:): installTap asserts
        // format.sampleRate == inputHWFormat.sampleRate, and the output side can serve a
        // stale rate after a route change (the exact repeated live failure) while
        // inputFormat is the source of truth the assert compares against.
        let inFormat = input.inputFormat(forBus: 0)
        // channelCount too: mid-route-change the node can report 48 kHz / 0 ch, and
        // installTap raises on it.
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                interleaved: true),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw CaptureError.formatUnavailable }

        // ~43 ms buffers at 48 kHz: small enough that the ring is near-live, big enough to
        // keep the tap cheap.
        let install = { input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
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
        } }
        // AVFAudio raises NSException (not a throw) if the format goes stale between the
        // query above and the install — fatal if unfenced (crashed the resident app
        // 2026-07-18 on a route change). Fenced, it degrades to a throw; the next start()
        // rebuilds cold.
        if let reason = CadenceCatchNSException(install) {
            throw CaptureError.tapInstall(reason)
        }
        tapInstalled = true
        tapFormat = inFormat
        engine.prepare()

        // Device/route changes (AirPods connect, display mic, …) invalidate the tap's
        // format and converter: tear down so the next start() rebuilds against the new route.
        // Rebuild on the main queue, debounced: changes arrive in bursts on arbitrary
        // threads, and re-tapping while the engine is still reconfiguring is what raised.
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.rebuildWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.running else { return }  // mid-capture: start() rebuilds after
                    self.teardownTap()
                    self.prewarm()
                }
                self.rebuildWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }
    }

    private func teardownTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        tapFormat = nil
    }
}
