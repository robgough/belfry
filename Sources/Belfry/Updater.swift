import AppKit
import Sparkle

/// App-wide Sparkle updater. nil when running without a bundle (the bare
/// `swift build` binary has no Info.plist to carry SUFeedURL) — Sparkle
/// treats that as a fatal setup error rather than quietly doing nothing, so
/// the menu item's action no-ops instead. The feed lives at
/// belfry.robgough.net/appcast.xml (docs/appcast.xml, regenerated and
/// EdDSA-signed by scripts/release.sh).
enum Updater {
    static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            qlog("sparkle: no SUFeedURL — updater disabled")
            return nil
        }
        qlog("sparkle: starting updater")
        return SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()
}
