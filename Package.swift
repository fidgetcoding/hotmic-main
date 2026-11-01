// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HotMic",
    platforms: [.macOS("14.2")],  // Core Audio process taps
    products: [
        .executable(name: "HotMic", targets: ["HotMic"]),
    ],
    dependencies: [
        // Lyrics: Whisper on Core ML / Apple silicon (MIT).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        // Auto-updates (MIT). Spec decision 3.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        // Session: phones join a session (shared with the iPhone app).
        .package(path: "SessionKit"),
    ],
    targets: [
        // Capture context: arming, aggregate device, taps, echo cancellation, disk.
        .target(name: "CRingBuffer"),
        .target(name: "Capture", dependencies: ["CRingBuffer"]),
        // Detection context: pitch tracking, singing-vs-talking, take slicing.
        .target(name: "Detection"),
        .testTarget(name: "DetectionTests", dependencies: ["Detection"]),
        // Timeline context: MIDI clock/SPP → bar, beat, tempo.
        .target(name: "Timeline"),
        .testTarget(name: "TimelineTests", dependencies: ["Timeline"]),
        // Pitch shifting for tuned takes: signalsmith-stretch + linear (MIT, vendored), C API for Swift.
        .target(name: "CStretch", exclude: ["vendor/stretch/LICENSE.txt", "vendor/linear/LICENSE.txt"],
                cxxSettings: [.headerSearchPath("vendor/stretch"), .headerSearchPath("vendor/linear/include")]),
        // Enrichment context: key, melody → MIDI (transcription + tuning pending dependency approval).
        .target(name: "Enrichment", dependencies: ["Detection", "CStretch"],
                resources: [.copy("Models/nmp.mlmodelc"), .copy("Models/BASIC-PITCH-LICENSE.txt")]),
        .testTarget(name: "EnrichmentTests", dependencies: ["Enrichment"]),
        // Transcription context: WhisperKit behind a protocol so everything else stays testable offline.
        .target(name: "Transcription", dependencies: ["Enrichment", .product(name: "WhisperKit", package: "argmax-oss-swift")]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription"]),
        .executableTarget(name: "hotmic-export", dependencies: ["Library"]),
        // Bench: runs recordings (the livestream test corpus) through the import pipeline headless.
        .executableTarget(name: "hotmic-bench", dependencies: ["Library", "Transcription"]),
        // Library audio for the window: a URL scheme that only serves files inside the library folder.
        .target(name: "MediaScheme"),
        .testTarget(name: "MediaSchemeTests", dependencies: ["MediaScheme"]),
        // Library context: scratch audio, take export, sidecars.
        .target(name: "Library", dependencies: ["Capture", "Detection", "Timeline", "Enrichment"]),
        // Fixtures/lyric-scenarios.json is read by path (#filePath).
        .testTarget(name: "LibraryTests", dependencies: ["Library", "Detection", "Timeline", "Enrichment", "Capture"], exclude: ["Fixtures"]),
        // Session context (host side): phones' mic streams → aligned to the beat → echo-cancelled → takes.
        .target(name: "Session", dependencies: ["Capture", "Library", "Timeline", .product(name: "SessionKit", package: "SessionKit")]),
        // Overlay: invisible hover pill + panel (never takes focus).
        .target(name: "Overlay"),
        .testTarget(name: "OverlayTests", dependencies: ["Overlay"]),
        // Final-phase end-to-end session simulation (opt-in: HM_E2E=1).
        .testTarget(name: "EndToEndTests", dependencies: ["Capture", "Detection", "Library", "Enrichment"]),
        // Shell: menu bar app + overlay. Thin; wires contexts together.
        .executableTarget(name: "HotMic", dependencies: ["Capture", "Detection", "Library", "Overlay", "Timeline", "Transcription", "Enrichment", "Session", "MediaScheme",
                                                          .product(name: "SessionKit", package: "SessionKit"),
                                                          .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"]),
        .testTarget(name: "SessionKitTests", dependencies: [.product(name: "SessionKit", package: "SessionKit")]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
