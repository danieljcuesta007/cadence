// cadence — the macOS menu-bar shell (§25 App/, §32 Phase 1 spine).
//
//   cadence run [--model path | --mock "text"] [--verbatim]
//       Menu-bar agent: hold Right-Option (or Right-Control for the second language) to
//       dictate into the focused field; Esc cancels.
//
//   cadence selftest-wav <wav> [--model path | --mock "text"] [--expect-app Name]
//       Full FFI pipeline (trigger → ring → ASR → cleanup → insertion) with the WAV
//       injected in capture-sized chunks instead of the mic. With --expect-app, insertion
//       is frontmost-guarded — the harness safety lesson from Phase 0 is mandatory here.
//
// Default model path matches the headless tool; CADENCE_MODEL overrides.

import AppKit
import CadenceCapture
import CadenceHotkeys
import CadenceInsertion
import CadenceOverlay
import Foundation

/// The model shipped inside Cadence.app. Prefers a multilingual model over an English-only
/// `.en` tier when both are present: the old code sorted alphabetically and took the first,
/// which ranks "ggml-base.en.bin" ahead of "ggml-small.bin" — so a bundle containing both
/// would silently dictate English-only, and whisper gives no error for a language it cannot
/// honour. Ties inside a tier still sort, so the choice stays deterministic.
func bundledModel() -> String? {
    let candidates = Bundle.main.paths(forResourcesOfType: "bin", inDirectory: "models")
        .filter { ($0 as NSString).lastPathComponent.hasPrefix("ggml-") }
        .sorted()
    return candidates.first { !($0 as NSString).lastPathComponent.contains(".en.") }
        ?? candidates.first
}

/// True when this model can only ever produce English, whatever language is requested.
func isEnglishOnly(_ path: String) -> Bool {
    (path as NSString).lastPathComponent.contains(".en.")
}

// Bare dev binary runs from <repo>/platform-macos/.build/<config>/cadence, so the checkout
// root is a few levels up. Walk to it from the executable rather than naming a checkout
// path: the app is only self-contained if nothing assumes where the repo was cloned.
private func devCheckoutModel() -> String? {
    var dir = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
    for _ in 0..<5 {
        let artifacts = dir.appendingPathComponent("models/artifacts")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: artifacts.path)) ?? []
        if let pick = names.filter({ $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }).sorted().first {
            return artifacts.appendingPathComponent(pick).path
        }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

struct Config {
    var mode = "run"
    var wav: String?
    // Resolution order: explicit env → bundled resource (Cadence.app ships its model,
    // self-contained; any ggml-*.bin — the tier is a packaging decision, §30) →
    // dev-checkout path (bare binary run from the repo, located relative to the binary).
    // The last arm is relative on purpose: if it is ever reached the model is genuinely
    // missing, and a clear "no such file" beats pointing at somebody else's home dir.
    var model =
        ProcessInfo.processInfo.environment["CADENCE_MODEL"]
        ?? bundledModel()
        ?? devCheckoutModel()
        ?? "models/artifacts/ggml-base.en.bin"
    var mock: String?
    var expectApp: String?
    var verbatim = false
}

func parseArgs() -> Config {
    var c = Config()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "run": c.mode = "run"
        case "selftest-wav":
            c.mode = "selftest"
            c.wav = it.next()
        case "selftest-stats": c.mode = "selftest-stats"
        case "selftest-hotkeys": c.mode = "selftest-hotkeys"
        case "--model": if let v = it.next() { c.model = v }
        case "--mock": c.mock = it.next() ?? "mock transcript"
        case "--expect-app": c.expectApp = it.next()
        case "--verbatim": c.verbatim = true
        default:
            FileHandle.standardError.write(Data("unknown arg: \(a)\n".utf8))
            exit(2)
        }
    }
    return c
}

func makeBackend(_ c: Config) -> CoreEngine.Backend {
    if let mock = c.mock { return .mock(refined: mock) }
    return .whisper(modelPath: c.model)
}

let config = parseArgs()

switch config.mode {
case "selftest":
    exit(runSelftest(config))
case "selftest-stats":
    exit(runStatsSelftest())
case "selftest-hotkeys":
    exit(runHotkeySelftest())
default:
    runApp(config) // never returns
}
