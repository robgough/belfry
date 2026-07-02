import CoreText
import SwiftUI

@main
struct BelfryiOSApp: App {
    @State private var model = BelfryiOSApp.bootstrapModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.registerBundledFonts()
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
            IOSRootView(model: model)
        }
        // iOS kills our SSH connections shortly after backgrounding; the tmux
        // servers keep the sessions. Tear links down quietly on background and
        // rebuild them on return, so foregrounding is a fast resync — never a
        // pile of dead sockets.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.suspendAll()
            case .active: model.resumeAll()
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
