import CoreText
import SwiftUI
import Termini
import UIKit

@main
struct BelfryiOSApp: App {
    @State private var model = BelfryiOSApp.bootstrapModel()
    @State private var backgroundGrace = BackgroundGrace()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.registerBundledFonts()
        // Warm libghostty's Metal state + font atlas off the critical path so
        // the first real surface paints promptly (and any font/atlas issue
        // surfaces at launch, not mid-connect).
        SurfaceContainerView.prewarmRenderer()
    }

    /// Make the bundled Maple Mono NF faces available to UIFont (runtime
    /// registration — simpler than UIAppFonts with a generated Info.plist).
    private static func registerBundledFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(model: model, keepAlive: backgroundGrace.keepAlive)
        }
        // The tmux servers keep the sessions; only our links need managing.
        // On background, a UIBackgroundTask keeps the SSH connections alive for
        // the grace window iOS grants (~25s) so quick app switches come back
        // instantly; when it runs out we tear down quietly and foregrounding
        // becomes a fast reconnect instead of a pile of dead sockets.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: backgroundGrace.enteredBackground(model: model)
            case .active: backgroundGrace.becameActive(model: model)
            default: break
            }
        }
    }

    private static func bootstrapModel() -> AppModel {
        #if DEBUG
        if let test = testHost() { return AppModel(hosts: [test]) }
        #endif
        return AppModel(hosts: HostPersistence.load().map { HostModel(saved: $0) })
    }

    #if DEBUG
    /// Harness hook: BELFRY_TEST_HOST/PORT/USER + BELFRY_TEST_KEY_B64 seed a
    /// throwaway host at launch so automated simulator runs can connect
    /// without driving the add-host form. Debug builds only; inert unless all
    /// variables are present.
    private static func testHost() -> HostModel? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["BELFRY_TEST_HOST"],
              let user = env["BELFRY_TEST_USER"],
              let keyB64 = env["BELFRY_TEST_KEY_B64"],
              let keyData = Data(base64Encoded: keyB64),
              let key = String(data: keyData, encoding: .utf8) else { return nil }
        let port = env["BELFRY_TEST_PORT"].flatMap(Int.init) ?? 22
        let saved = SavedHost(
            alias: "test", displayName: "Test",
            hostname: host, port: port, username: user,
            authMethod: SavedHost.authMethodKey)
        KeychainStore.setSecret(key, for: "test")
        return HostModel(saved: saved)
    }
    #endif
}

extension HostModel {
    /// Rebuild a persisted iOS host (endpoint in `saved`, secret in Keychain).
    convenience init(saved: SavedHost) {
        self.init(
            id: saved.alias,
            displayName: saved.displayName ?? saved.alias,
            transport: SSHHostTransport(saved: saved))
    }
}

/// Keeps SSH links alive across brief trips to the background.
///
/// iOS suspends the process shortly after backgrounding unless a background
/// task is open. We open one and delay `suspendAll()` until just before the
/// system's grace window closes (or the expiration handler fires, whichever
/// comes first). A quick check-something-else-and-return never drops the
/// connections; a longer absence suspends cleanly and resumes on return.
@MainActor
final class BackgroundGrace {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var pendingSuspend: DispatchWorkItem?
    /// Opt-in indefinite runtime (see BackgroundKeepAlive); owned here so the
    /// background/foreground transitions and the options toggle share it.
    let keepAlive = BackgroundKeepAlive()

    func enteredBackground(model: AppModel) {
        endTask()
        pendingSuspend?.cancel()
        // Keep-alive engaged: the process (and its sockets) stays running —
        // no suspension scheduled at all.
        if keepAlive.engageIfEnabled() { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "belfry.ssh-grace") { [weak self] in
            // Expiration arrives on the main thread; suspend immediately.
            self?.suspendNow(model: model)
        }
        let work = DispatchWorkItem { [weak self] in
            self?.suspendNow(model: model)
        }
        pendingSuspend = work
        // Use what the system actually granted (usually ~30 s, occasionally
        // more) instead of a fixed guess, keeping a 5 s margin to suspend in
        // an orderly fashion rather than in the expiration handler's last gasp.
        let granted = UIApplication.shared.backgroundTimeRemaining
        let grace = granted.isFinite ? min(max(granted - 5, 5), 110) : 25
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }

    func becameActive(model: AppModel) {
        keepAlive.disengage()
        pendingSuspend?.cancel()
        pendingSuspend = nil
        endTask()
        // No-op if we never actually suspended (AppModel guards on its own flag).
        model.resumeAll()
    }

    private func suspendNow(model: AppModel) {
        pendingSuspend?.cancel()
        pendingSuspend = nil
        model.suspendAll()
        endTask()
    }

    private func endTask() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
