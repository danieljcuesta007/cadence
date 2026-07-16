// cadence — the macOS menu-bar shell (§25 App/, §32 Phase 1 spine).
//
//   cadence run [--model path | --mock "text"] [--verbatim]
//       Menu-bar agent: hold Right-Option to dictate into the focused field; Esc cancels.
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

struct Config {
    var mode = "run"
    var wav: String?
    // Resolution order: explicit env → bundled resource (Cadence.app ships its model,
    // self-contained) → dev-checkout path (bare binary run from the repo).
    var model =
        ProcessInfo.processInfo.environment["CADENCE_MODEL"]
        ?? Bundle.main.path(forResource: "ggml-base.en", ofType: "bin", inDirectory: "models")
        ?? NSString(string: "~/cadence/models/artifacts/ggml-base.en.bin").expandingTildeInPath
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
default:
    runApp(config) // never returns
}
