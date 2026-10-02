import AppKit
import SwiftUI
import Testing
@testable import Belfry

/// Renders the Mac sidebar off-screen from sample data, so its layout can be
/// inspected without running the app. Only runs when BELFRY_RENDER_DIR is set
/// (it writes PNGs there); a no-op in normal test runs.
@MainActor
struct SidebarRenderTests {
    private static var outputDir: URL? {
        ProcessInfo.processInfo.environment["BELFRY_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    }

    @Test func renderSidebar() throws {
        guard let dir = Self.outputDir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = ThemeStore.shared.selectedID
        defer { ThemeStore.shared.select(original) }
        for (name, theme, hover) in [("dark", "catppuccin-mocha", false), ("light", "github-light", false),
                                     ("hover", "catppuccin-mocha", true)] {
            ThemeStore.shared.select(theme)
            let view = MacSidebarView(snapshot: SidebarSamples.snapshot(),
                                      selection: .constant(WindowSelection(hostID: "local", windowID: "@6")))
                .content
                .environment(\.staticAgentBadges, true)
                .environment(\.sidebarForceHover, hover)
                .frame(width: 280, height: 900, alignment: .top)
                .background(AppTheme.sidebarBackground)
                .environment(\.colorScheme, AppTheme.colorScheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("sidebar-\(name).png"))
        }
    }
}
