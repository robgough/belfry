import CoreLocation
import Foundation

/// Opt-in indefinite background runtime via continuous coarse location
/// updates — the only App Store-sanctioned way for a terminal app to keep
/// its SSH connections alive past the ~30 s background grace (Blink's
/// long-standing approach). The location values are deliberately ignored:
/// the updates exist purely so iOS keeps the process, and therefore its
/// sockets, running. Coarsest accuracy + an infinite distance filter keep
/// the battery cost minimal; iOS shows its location indicator while
/// engaged, which is the honest signal that the app is still running.
@MainActor
final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    /// UserDefaults key for the user's opt-in (bound by the options menu).
    static let enabledKey = "belfry.keepAliveInBackground"

    private let manager = CLLocationManager()
    private(set) var isEngaged = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: true
        default: false
        }
    }

    /// Prompt for when-in-use permission (called when the toggle turns on).
    /// When-in-use is enough: with the `location` background mode declared,
    /// `allowsBackgroundLocationUpdates` carries updates — and us — through
    /// backgrounding without the "Always" escalation.
    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Start background updates if the user opted in and permission stands.
    /// Returns whether keep-alive is now carrying the app (the caller skips
    /// scheduling a suspend when it is).
    func engageIfEnabled() -> Bool {
        guard isEnabled, isAuthorized else { return false }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isEngaged = true
        return true
    }

    func disengage() {
        guard isEngaged else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isEngaged = false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Deliberately ignored — see the type comment.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Failures (denied mid-flight, airplane mode) just mean the process
        // suspends on the normal grace path; nothing to surface.
    }
}
