// CoreEngine — Swift face of the Rust core over the C ABI (ADR-0005).
//
// Effects arrive as cadence-ipc JSON on a core-owned thread; this wrapper hands the raw
// string to `onEffect` untouched — routing/trampolining is EffectRouter's job.
//
// Lifetime: the engine is created once and lives for the process (menu-bar agent). The
// callback context is an unretained self, which is only sound because `deinit` →
// `cadence_engine_free` joins the core threads before returning.

import CCadenceFFI
import Foundation

final class CoreEngine {
    enum Backend {
        case whisper(modelPath: String)
        case mock(refined: String)
    }

    private var handle: OpaquePointer?
    private let onEffect: (String) -> Void

    init?(backend: Backend, onEffect: @escaping (String) -> Void) {
        self.onEffect = onEffect
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb: cadence_effect_cb = { json, ctx in
            guard let json, let ctx else { return }
            let me = Unmanaged<CoreEngine>.fromOpaque(ctx).takeUnretainedValue()
            me.onEffect(String(cString: json))
        }
        switch backend {
        case .whisper(let path):
            handle = cadence_engine_new(path, cb, ctx)
        case .mock(let refined):
            handle = cadence_engine_new_mock(refined, cb, ctx)
        }
        if handle == nil {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            FileHandle.standardError.write(Data("cadence core init failed: \(msg)\n".utf8))
            return nil
        }
    }

    deinit {
        if let handle { cadence_engine_free(handle) }
    }

    func triggerDown(verbatim: Bool = false) { cadence_engine_trigger_down(handle, verbatim) }
    func triggerUp() { cadence_engine_trigger_up(handle) }
    func cancel() { cadence_engine_cancel(handle) }
    func captureStopped() { cadence_engine_capture_stopped(handle) }

    /// Runtime language override: "auto", an ISO code ("en"/"es"), or "" to leave as loaded.
    func setLanguage(_ lang: String) { cadence_engine_set_language(handle, lang) }

    func pushAudio(_ samples: [Int16], level: Float) {
        samples.withUnsafeBufferPointer {
            cadence_engine_push_audio(handle, $0.baseAddress, $0.count, level)
        }
    }

    func insertionResult(
        utterance: String, strategy: String, inserted: Bool, clipboardRestored: Bool
    ) {
        cadence_engine_insertion_result(handle, utterance, strategy, inserted, clipboardRestored)
    }

    func insertionFailed(utterance: String) {
        cadence_engine_insertion_failed(handle, utterance)
    }

    static var coreVersion: String { String(cString: cadence_version()) }
}
