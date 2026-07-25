import Foundation
import Testing
@testable import TerminiSSH
import Termini

/// Live end-to-end test of the SSH local-forward patch. Skipped unless the
/// environment provides a reachable SSH server:
///
///   TERMINI_LIVE_SSH_HOST=127.0.0.1 TERMINI_LIVE_SSH_USER=me \
///   TERMINI_LIVE_SSH_KEY_B64=$(base64 < key) \
///   TERMINI_LIVE_HTTP_PORT=8123 swift test --filter LocalForwardLive
///
/// with an HTTP server on the remote's loopback at TERMINI_LIVE_HTTP_PORT
/// serving a file `forward-probe.txt` containing `forward-ok`.
@Suite struct LocalForwardLiveTests {
    @Test @MainActor func forwardBridgesHTTP() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TERMINI_LIVE_SSH_HOST"],
              let user = env["TERMINI_LIVE_SSH_USER"],
              let keyB64 = env["TERMINI_LIVE_SSH_KEY_B64"],
              let keyData = Data(base64Encoded: keyB64),
              let key = String(data: keyData, encoding: .utf8),
              let httpPort = env["TERMINI_LIVE_HTTP_PORT"].flatMap(Int.init)
        else {
            return   // not configured — skip quietly
        }

        let session = TerminiSSHSession(controller: TerminiTerminalController())
        await session.connect(configuration: TerminiSSHConfiguration(
            host: host, username: user, privateKeyPEM: key,
            opensPrimaryChannel: false, hostKeyPolicy: .trustOnFirstUse))
        #expect(session.status == .connected)

        let forward = try await session.openLocalForward(
            targetHost: "127.0.0.1", targetPort: httpPort)
        defer { forward.close() }

        let url = "http://127.0.0.1:\(forward.localPort)/forward-probe.txt"
        // curl rather than URLSession: this exercises the tunnel with a
        // plain, patient HTTP client (URLSession's connection management
        // added its own variables while this was being debugged).
        func fetch() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-s", "--max-time", "10", url]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try fetch() == "forward-ok")
        // A second request exercises listener reuse (fresh child channel).
        #expect(try fetch() == "forward-ok")

        await session.disconnect()
    }
}
