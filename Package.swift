// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Belfry",
    platforms: [
        .macOS(.v14)
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
    ],
    targets: [
        .executableTarget(
            name: "Belfry",
            dependencies: [
                .product(name: "Termini", package: "Termini"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Belfry",
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
    ]
)
