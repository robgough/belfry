import Foundation
import Observation

/// One of Belfry's built-in colour themes (palettes taken verbatim from the
/// matching Ghostty theme files).
struct BuiltInTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let theme: ResolvedTheme
}

/// The colour theme the whole app uses — sidebar chrome *and* terminals. Either
/// one of the built-in coding themes, or "Match Ghostty" (the user's Ghostty
/// config, resolved by `GhosttyThemeReader`). Observable, so every view that
/// reads `AppTheme` re-renders when the choice changes, and terminals recolour
/// live (their appearance carries `SurfaceTheme.theme`). Persisted per device.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    /// The "Match Ghostty" option's id.
    static let ghosttyID = "ghostty"
    private static let defaultsKey = "colorTheme"

    private(set) var selectedID: String
    private(set) var current: ResolvedTheme

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? Self.ghosttyID
        selectedID = saved
        current = Self.resolve(saved)
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        current = Self.resolve(id)
        UserDefaults.standard.set(id, forKey: Self.defaultsKey)
    }

    /// Display name of the current choice.
    var selectedName: String {
        selectedID == Self.ghosttyID ? "Match Ghostty"
            : Self.builtIn.first { $0.id == selectedID }?.name ?? "Match Ghostty"
    }

    private static func resolve(_ id: String) -> ResolvedTheme {
        if id == ghosttyID { return GhosttyThemeReader.resolved }
        return builtIn.first { $0.id == id }?.theme ?? GhosttyThemeReader.resolved
    }

    /// Dark themes first, then light, each in the order listed.
    static var darkThemes: [BuiltInTheme] { builtIn.filter { $0.theme.isDark } }
    static var lightThemes: [BuiltInTheme] { builtIn.filter { !$0.theme.isDark } }

    static let builtIn: [BuiltInTheme] = [
        BuiltInTheme(id: "catppuccin-mocha", name: "Catppuccin Mocha", theme: ResolvedTheme(
            background: 0x1E1E2E, foreground: 0xCDD6F4, cursor: 0xF5E0DC,
            selectionBackground: 0x585B70, selectionForeground: 0xCDD6F4,
            palette: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
                      0x585B70, 0xF37799, 0x89D88B, 0xEBD391, 0x74A8FC, 0xF2AEDE, 0x6BD7CA, 0xBAC2DE])),
        BuiltInTheme(id: "catppuccin-macchiato", name: "Catppuccin Macchiato", theme: ResolvedTheme(
            background: 0x24273A, foreground: 0xCAD3F5, cursor: 0xF4DBD6,
            selectionBackground: 0x5B6078, selectionForeground: 0xCAD3F5,
            palette: [0x494D64, 0xED8796, 0xA6DA95, 0xEED49F, 0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xA5ADCB,
                      0x5B6078, 0xEC7486, 0x8CCF7F, 0xE1C682, 0x78A1F6, 0xF2A9DD, 0x63CBC0, 0xB8C0E0])),
        BuiltInTheme(id: "catppuccin-latte", name: "Catppuccin Latte", theme: ResolvedTheme(
            background: 0xEFF1F5, foreground: 0x4C4F69, cursor: 0xDC8A78,
            selectionBackground: 0xACB0BE, selectionForeground: 0x4C4F69,
            palette: [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
                      0x6C6F85, 0xDE293E, 0x49AF3D, 0xEEA02D, 0x456EFF, 0xFE85D8, 0x2D9FA8, 0xBCC0CC])),
        BuiltInTheme(id: "tokyo-night", name: "Tokyo Night", theme: ResolvedTheme(
            background: 0x1A1B26, foreground: 0xC0CAF5, cursor: 0xC0CAF5,
            selectionBackground: 0x33467C, selectionForeground: 0xC0CAF5,
            palette: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                      0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5])),
        BuiltInTheme(id: "tokyo-night-storm", name: "Tokyo Night Storm", theme: ResolvedTheme(
            background: 0x24283B, foreground: 0xC0CAF5, cursor: 0xC0CAF5,
            selectionBackground: 0x364A82, selectionForeground: 0xC0CAF5,
            palette: [0x1D202F, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                      0x4E5575, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5])),
        BuiltInTheme(id: "dracula", name: "Dracula", theme: ResolvedTheme(
            background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2,
            selectionBackground: 0x44475A, selectionForeground: 0xFFFFFF,
            palette: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                      0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF])),
        BuiltInTheme(id: "nord", name: "Nord", theme: ResolvedTheme(
            background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0xECEFF4,
            selectionBackground: 0xECEFF4, selectionForeground: 0x4C566A,
            palette: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                      0x596377, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4])),
        BuiltInTheme(id: "gruvbox-dark", name: "Gruvbox Dark", theme: ResolvedTheme(
            background: 0x282828, foreground: 0xEBDBB2, cursor: 0xEBDBB2,
            selectionBackground: 0x665C54, selectionForeground: 0xEBDBB2,
            palette: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                      0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2])),
        BuiltInTheme(id: "gruvbox-light", name: "Gruvbox Light", theme: ResolvedTheme(
            background: 0xFBF1C7, foreground: 0x3C3836, cursor: 0x3C3836,
            selectionBackground: 0x3C3836, selectionForeground: 0xFBF1C7,
            palette: [0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
                      0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836])),
        BuiltInTheme(id: "one-dark", name: "One Dark", theme: ResolvedTheme(
            background: 0x21252B, foreground: 0xABB2BF, cursor: 0xABB2BF,
            selectionBackground: 0x323844, selectionForeground: 0xABB2BF,
            palette: [0x21252B, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                      0x767676, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF])),
        BuiltInTheme(id: "rose-pine", name: "Rosé Pine", theme: ResolvedTheme(
            background: 0x191724, foreground: 0xE0DEF4, cursor: 0xE0DEF4,
            selectionBackground: 0x403D52, selectionForeground: 0xE0DEF4,
            palette: [0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
                      0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4])),
        BuiltInTheme(id: "rose-pine-dawn", name: "Rosé Pine Dawn", theme: ResolvedTheme(
            background: 0xFAF4ED, foreground: 0x575279, cursor: 0x575279,
            selectionBackground: 0xDFDAD9, selectionForeground: 0x575279,
            palette: [0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
                      0x9893A5, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279])),
        BuiltInTheme(id: "github-dark", name: "GitHub Dark", theme: ResolvedTheme(
            background: 0x0D1117, foreground: 0xE6EDF3, cursor: 0x2F81F7,
            selectionBackground: 0xE6EDF3, selectionForeground: 0x0D1117,
            palette: [0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
                      0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF])),
        BuiltInTheme(id: "github-light", name: "GitHub Light", theme: ResolvedTheme(
            background: 0xFFFFFF, foreground: 0x1F2328, cursor: 0x0969DA,
            selectionBackground: 0x1F2328, selectionForeground: 0xFFFFFF,
            palette: [0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
                      0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F])),
        BuiltInTheme(id: "kanagawa-wave", name: "Kanagawa Wave", theme: ResolvedTheme(
            background: 0x1F1F28, foreground: 0xDCD7BA, cursor: 0xDCD7BA,
            selectionBackground: 0xDCD7BA, selectionForeground: 0x1F1F28,
            palette: [0x090618, 0xC34043, 0x76946A, 0xC0A36E, 0x7E9CD8, 0x957FB8, 0x6A9589, 0xC8C093,
                      0x727169, 0xE82424, 0x98BB6C, 0xE6C384, 0x7FB4CA, 0x938AA9, 0x7AA89F, 0xDCD7BA])),
        BuiltInTheme(id: "everforest-dark", name: "Everforest Dark", theme: ResolvedTheme(
            background: 0x1E2326, foreground: 0xD3C6AA, cursor: 0xE69875,
            selectionBackground: 0x4C3743, selectionForeground: 0xD3C6AA,
            palette: [0x7A8478, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xF2EFDF,
                      0xA6B0A0, 0xF85552, 0x8DA101, 0xDFA000, 0x3A94C5, 0xDF69BA, 0x35A77C, 0xFFFBEF])),
        BuiltInTheme(id: "solarized-dark", name: "Solarized Dark", theme: ResolvedTheme(
            background: 0x002B36, foreground: 0x839496, cursor: 0x839496,
            selectionBackground: 0x073642, selectionForeground: 0x93A1A1,
            palette: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                      0x335E69, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])),
        BuiltInTheme(id: "solarized-light", name: "Solarized Light", theme: ResolvedTheme(
            background: 0xFDF6E3, foreground: 0x657B83, cursor: 0x657B83,
            selectionBackground: 0xEEE8D5, selectionForeground: 0x586E75,
            palette: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xBBB5A2,
                      0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])),
        BuiltInTheme(id: "monokai-pro", name: "Monokai Pro", theme: ResolvedTheme(
            background: 0x2D2A2E, foreground: 0xFCFCFA, cursor: 0xC1C0C0,
            selectionBackground: 0x5B595C, selectionForeground: 0xFCFCFA,
            palette: [0x2D2A2E, 0xFF6188, 0xA9DC76, 0xFFD866, 0xFC9867, 0xAB9DF2, 0x78DCE8, 0xFCFCFA,
                      0x727072, 0xFF6188, 0xA9DC76, 0xFFD866, 0xFC9867, 0xAB9DF2, 0x78DCE8, 0xFCFCFA])),
        BuiltInTheme(id: "night-owl", name: "Night Owl", theme: ResolvedTheme(
            background: 0x011627, foreground: 0xD6DEEB, cursor: 0x7E57C2,
            selectionBackground: 0x5F7E97, selectionForeground: 0xDFE5EE,
            palette: [0x011627, 0xEF5350, 0x22DA6E, 0xADDB67, 0x82AAFF, 0xC792EA, 0x21C7A8, 0xFFFFFF,
                      0x575656, 0xEF5350, 0x22DA6E, 0xFFEB95, 0x82AAFF, 0xC792EA, 0x7FDBCA, 0xFFFFFF])),
    ]
}
