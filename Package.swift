// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Belfry",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    dependencies: [
        // libghostty surface (default backend), via the Termini SwiftUI wrapper.
        // Vendored locally (see vendor/Termini/LOCAL_PATCHES.md) so we can patch
        // its NSView resize path; it bundles a prebuilt GhosttyKit.xcframework
        // (no Zig toolchain needed).
        .package(path: "vendor/Termini"),
        // Stable fallback backend (pure Swift, no xcframework).
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            from: "1.13.0"
        ),
        // Auto-updates for the distributed .app (macOS only; the framework is
        // embedded + re-signed by scripts/make_app.sh).
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.9.3"
        ),
    ],
    targets: [
        // The macOS app. `Sources/BelfryKit` is the platform-neutral core,
        // compiled directly into each app target (this one via `sources`; the
        // iOS app via its xcodegen target) so both stay a single module and
        // the shared code needs no access-control ceremony.
        .executableTarget(
            name: "Belfry",
            dependencies: [
                .product(name: "Termini", package: "Termini"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            exclude: ["BelfryAskpass", "BelfryiOS"],
            sources: ["Belfry", "BelfryKit"],
            // Swift 5 language mode: avoids strict-concurrency churn while we
            // bring the app up; can tighten to .v6 later.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tiny GUI helper ssh runs (via SSH_ASKPASS) to prompt for a password /
        // passphrase, since the control connection has no visible terminal.
        .executableTarget(
            name: "belfry-askpass",
            path: "Sources/BelfryAskpass",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Unit tests (macOS host). Depends on the app target so `@testable import
        // Belfry` can reach internal seams like `LaunchdTmux.runOutcome` and
        // `RemoteTmux.prelude` (Sources/BelfryKit compiles into this module too).
        .testTarget(
            name: "BelfryTests",
            dependencies: ["Belfry"],
            path: "Tests/BelfryTests",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // The app target links Sparkle.framework (normally embedded into the
            // .app by make_app.sh). A bare `swift test` bundle has no such embed,
            // and SIP strips DYLD_FRAMEWORK_PATH from Xcode's signed test helper,
            // so point the loader at the framework SwiftPM already built alongside
            // the xctest bundle: <build>/Debug/Sparkle.framework, three levels up
            // from the test binary in …/BelfryTests.xctest/Contents/MacOS/.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../..",
            ])]
        ),
    ]
)
