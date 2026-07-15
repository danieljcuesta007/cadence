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
    ]
)
