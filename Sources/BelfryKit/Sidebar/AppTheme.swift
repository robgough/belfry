import SwiftUI

/// SwiftUI colours for the app chrome (sidebar, headers, window, selection),
/// derived from the same resolved Ghostty theme the terminals use — so the whole
/// window reads as one theme that follows whatever Ghostty is set to.
enum AppTheme {
    static let resolved = GhosttyThemeReader.resolved

    /// Force the window's light/dark to match the theme, so system text and
    /// materials render with the right contrast over our themed backgrounds.
    static var colorScheme: ColorScheme { resolved.isDark ? .dark : .light }

    static var windowBackground: Color { color(resolved.background) }
    /// Slightly offset from the content background so the sidebar reads as distinct.
    static var sidebarBackground: Color {
        color(shade(resolved.background, by: resolved.isDark ? -0.30 : -0.05))
    }
    static var accent: Color { color(resolved.palette[safe: 4] ?? resolved.foreground) }

    private static func color(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255,
              opacity: opacity)
    }

    /// Blend a colour toward black (negative `f`) or white (positive `f`).
    private static func shade(_ hex: UInt32, by f: Double) -> UInt32 {
        let target: Double = f < 0 ? 0 : 255
        let amount = abs(f)
        func mix(_ component: UInt32) -> UInt32 {
            let v = Double(component) * (1 - amount) + target * amount
            return UInt32(max(0, min(255, v)))
        }
        return (mix((hex >> 16) & 0xFF) << 16) | (mix((hex >> 8) & 0xFF) << 8) | mix(hex & 0xFF)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
