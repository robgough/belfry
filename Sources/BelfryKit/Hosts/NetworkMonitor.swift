import Foundation
import Network

/// Passive view of the device's network path, so reconnect logic can stop
/// guessing. `NWPathMonitor` makes no network calls of its own — the OS tells
/// us when connectivity changes — which lets a host with no route pause its
/// retries entirely (no radio wakeups, no doomed handshakes) and reconnect the
/// moment a path returns instead of waiting out its backoff.
///
/// Two signals reach the owner:
/// - `onAvailabilityChange(true/false)`: the path became (un)satisfied.
/// - `onPathChange()`: still satisfied, but over a different interface
///   (wifi → cellular, VPN up/down). TCP connections bound to the old
///   interface are often dead without knowing it, so live links should be
///   probed rather than trusted.
@MainActor
final class NetworkMonitor {
    private(set) var isAvailable = true
    var onAvailabilityChange: ((Bool) -> Void)?
    var onPathChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var interfaceSignature: String?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let signature = path.availableInterfaces.map { "\($0.type)/\($0.name)" }.joined(separator: ",")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(available: available, signature: signature) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "belfry.network-monitor", qos: .utility))
    }

    func stop() {
        monitor.cancel()
    }

    private func apply(available: Bool, signature: String) {
        // The first update reports the starting state. Only "no network" is
        // news (owners assume a network until told otherwise — e.g. launched
        // in airplane mode, hosts should park rather than burn attempts).
        guard let previous = interfaceSignature else {
            interfaceSignature = signature
            isAvailable = available
            if !available { onAvailabilityChange?(false) }
            return
        }
        interfaceSignature = signature
        if available != isAvailable {
            isAvailable = available
            onAvailabilityChange?(available)
        } else if available, signature != previous {
            onPathChange?()
        }
    }
}
