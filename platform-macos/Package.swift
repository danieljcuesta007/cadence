// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CadenceMac",
    platforms: [.macOS(.v13)],
    targets: [
        // Insertion engine spike (§32 Phase 0): capability-detecting cascade that must never
        // freeze the target app nor corrupt the clipboard (AC-20).
        .target(
            name: "CadenceInsertion",
            path: "Insertion/Sources/CadenceInsertion"
        ),
        // NOTE: no .testTarget — this machine has Command Line Tools only (no XCTest/Testing
        // module). The invariants are covered by `insertctl selftest`, which is what
        // qa/insertion-matrix.sh runs first.
        .executableTarget(
            name: "insertctl",
            dependencies: ["CadenceInsertion"],
            path: "Insertion/Sources/insertctl"
        ),

        // C ABI of the Rust core (ADR-0005). The header is a symlink to the canonical copy
        // in core/ffi/include/; the library comes from `cargo build -p cadence-ffi`.
        .target(
            name: "CCadenceFFI",
            path: "Core/CCadenceFFI"
        ),
        // ObjC exception fence: AVFAudio raises NSException on bad tap installs (route
        // changes); Swift can't catch those, so this wraps them into a returnable error.
        .target(
            name: "CObjCCatch",
            path: "Capture/Sources/CObjCCatch"
        ),
        // AVAudioEngine (CoreAudio) capture → 16 kHz mono i16 chunks (§16.1, §18 step 2).
        .target(
            name: "CadenceCapture",
            dependencies: ["CObjCCatch"],
            path: "Capture/Sources/CadenceCapture"
        ),
        // Global PTT + cancel via a CGEvent tap (§12.4). Requires Accessibility.
        .target(
            name: "CadenceHotkeys",
            path: "Hotkeys/Sources/CadenceHotkeys"
        ),
        // Non-activating NSPanel HUD (§12.1): state glyph, level bar, local/cloud chip.
        .target(
            name: "CadenceOverlay",
            path: "Overlay/Sources/CadenceOverlay"
        ),
        // The menu-bar shell (§25 App/): interprets core effects, owns lifecycle.
        // Build the Rust side first — qa/build-shell.sh does both in order.
        .executableTarget(
            name: "cadence",
            dependencies: [
                "CCadenceFFI", "CadenceCapture", "CadenceHotkeys", "CadenceOverlay",
                "CadenceInsertion",
            ],
            path: "App/Sources/cadence",
            linkerSettings: [
                .linkedLibrary("cadence_ffi"),
                .linkedLibrary("c++"), // whisper.cpp/ggml objects inside libcadence_ffi.a
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .unsafeFlags(["-L\(Context.packageDirectory)/../target/release"]),
            ]
        ),
    ]
)
