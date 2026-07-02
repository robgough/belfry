import Foundation

/// The resolved colours of the user's Ghostty theme. Belfry reads the user's
/// Ghostty config (`theme = …`, plus any inline colour overrides) and the named
/// theme file, so the terminal *and* the app chrome match whatever Ghostty is set
/// to. Falls back to Catppuccin Mocha if Ghostty isn't installed or the theme
/// can't be resolved — so it never breaks, just may not match.
struct ResolvedTheme: Equatable {
    var background: UInt32
    var foreground: UInt32
    var cursor: UInt32
    var selectionBackground: UInt32
    var selectionForeground: UInt32
    var palette: [UInt32]   // 16 entries (ANSI 0–15)

    /// Dark vs light, from background luminance — drives the app's color scheme.
    var isDark: Bool { Self.luminance(background) < 0.5 }

    static func luminance(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Used when Ghostty/theme resolution fails. Matches the Ghostty "Catppuccin
    /// Mocha" theme file exactly.
    static let fallback = ResolvedTheme(
        background: 0x1E1E2E, foreground: 0xCDD6F4, cursor: 0xF5E0DC,
        selectionBackground: 0x585B70, selectionForeground: 0xCDD6F4,
        palette: [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
            0x585B70, 0xF37799, 0x89D88B, 0xEBD391, 0x74A8FC, 0xF2AEDE, 0x6BD7CA, 0xBAC2DE,
        ])
}

enum GhosttyThemeReader {
    /// Resolved once per launch (file I/O); chrome + terminal share this.
    static let resolved: ResolvedTheme = resolve()

    // MARK: Resolution

    private static func resolve() -> ResolvedTheme {
        guard let config = configPaths().lazy.compactMap(parseFile).first else {
            return .fallback
        }
        var merged = ParsedConfig()
        // The named theme is the base; the user's inline colours override it.
        if let name = config.scalars["theme"], let theme = locateTheme(name).flatMap(parseFile) {
            merged = theme
        }
        merged.scalars.merge(config.scalars) { _, new in new }
        for (index, color) in config.palette { merged.palette[index] = color }

        let fb = ResolvedTheme.fallback
        func color(_ key: String, _ fallback: UInt32) -> UInt32 {
            merged.scalars[key].flatMap(parseColor) ?? fallback
        }
        var palette = fb.palette
        for index in 0..<16 { if let c = merged.palette[index] { palette[index] = c } }

        return ResolvedTheme(
            background: color("background", fb.background),
            foreground: color("foreground", fb.foreground),
            cursor: color("cursor-color", fb.cursor),
            selectionBackground: color("selection-background", fb.selectionBackground),
            selectionForeground: color("selection-foreground", fb.selectionForeground),
            palette: palette)
    }

    // MARK: Paths

    private static func configPaths() -> [String] {
        let home = NSHomeDirectory()
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? "\(home)/.config"
        return [
            "\(xdg)/ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ]
    }

    private static func themeDirs() -> [String] {
        let home = NSHomeDirectory()
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? "\(home)/.config"
        return [
            "\(xdg)/ghostty/themes",                                   // user themes win
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        ]
    }

    /// A `theme` value can be a bare name or `light:Name,dark:Name`; pick the one
    /// matching the system appearance, then find its file.
    private static func locateTheme(_ raw: String) -> String? {
        let name = pickThemeName(raw)
        for dir in themeDirs() {
            let path = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private static func pickThemeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("light:") || trimmed.contains("dark:") else { return trimmed }
        var variants: [String: String] = [:]
        for part in trimmed.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                variants[kv[0].trimmingCharacters(in: .whitespaces)] =
                    kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return variants[dark ? "dark" : "light"] ?? variants["dark"] ?? variants["light"] ?? trimmed
    }

    // MARK: Parsing

    private struct ParsedConfig {
        var scalars: [String: String] = [:]
        var palette: [Int: UInt32] = [:]
    }

    private static func parseFile(_ path: String) -> ParsedConfig? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var parsed = ParsedConfig()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "palette" {
                // value is "N=#hex"
                guard let inner = value.firstIndex(of: "="),
                      let index = Int(value[..<inner].trimmingCharacters(in: .whitespaces)),
                      let color = parseColor(String(value[value.index(after: inner)...])) else { continue }
                parsed.palette[index] = color
            } else if !key.isEmpty {
                parsed.scalars[key] = value
            }
        }
        return parsed
    }

    /// Parse `#rrggbb` / `rrggbb` into 0xRRGGBB. Named colours aren't supported
    /// (themes use hex); they fall back to the default for that field.
    private static func parseColor(_ raw: String) -> UInt32? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return value
    }
}
