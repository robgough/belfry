import Foundation

/// What a long-pressed token in terminal output can preview. Parsing is
/// deliberately conservative: only things that are clearly a URL or a path
/// produce a candidate — everything else falls through to nothing rather
/// than a wrong guess.
enum PreviewCandidate: Equatable {
    /// A dev server on the *remote host's* loopback — previewed through an
    /// SSH local forward. `targetHost` is as seen from the remote (0.0.0.0
    /// normalizes to 127.0.0.1); `pathQuery` keeps a leading "/".
    case localhost(targetHost: String, port: Int, scheme: String, pathQuery: String)
    /// An absolute file path on the remote host.
    case remoteFile(path: String)
    /// An ordinary external web URL — hand it to the system browser.
    case webURL(URL)

    // MARK: Token extraction

    /// The whitespace-delimited token covering `column` in a terminal row,
    /// with the punctuation that typically hugs URLs/paths in output
    /// (brackets, quotes, trailing `.,:;`) trimmed away.
    static func token(inRow row: String, column: Int) -> String? {
        guard !row.isEmpty else { return nil }
        let characters = Array(row)
        guard column < characters.count, !characters[column].isWhitespace else { return nil }
        var start = column
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        var end = column
        while end + 1 < characters.count, !characters[end + 1].isWhitespace { end += 1 }
        var token = String(characters[start...end])

        // Strip wrapping punctuation: ("http://x") → http://x, 'path', <url>…
        let leading: Set<Character> = ["(", "[", "<", "\"", "'", "`", "{"]
        let trailing: Set<Character> = [")", "]", ">", "\"", "'", "`", "}", ",", ";", ":", "."]
        while let first = token.first, leading.contains(first) { token.removeFirst() }
        while let last = token.last, trailing.contains(last) { token.removeLast() }
        return token.isEmpty ? nil : token
    }

    // MARK: Parsing

    /// Parse a trimmed token. `currentDirectory` (the pane's cwd, from the
    /// control-plane subscription) anchors relative paths; without it they
    /// are not previewable.
    static func parse(token: String, currentDirectory: String?) -> PreviewCandidate? {
        guard !token.isEmpty, !token.contains(where: \.isNewline) else { return nil }

        // Scheme'd URLs.
        if token.lowercased().hasPrefix("http://") || token.lowercased().hasPrefix("https://") {
            guard let components = URLComponents(string: token), let host = components.host else { return nil }
            if let loopback = loopbackHost(host) {
                let port = components.port ?? (components.scheme == "https" ? 443 : 80)
                var pathQuery = components.path.isEmpty ? "/" : components.path
                if let query = components.query { pathQuery += "?" + query }
                return .localhost(targetHost: loopback, port: port,
                                  scheme: components.scheme ?? "http", pathQuery: pathQuery)
            }
            return URL(string: token).map(PreviewCandidate.webURL)
        }
        if token.lowercased().hasPrefix("file://") {
            let path = String(token.dropFirst("file://".count))
            return path.hasPrefix("/") ? .remoteFile(path: path) : nil
        }
        guard !token.contains("://") else { return nil }

        // Bare server-log forms: localhost:5173, 127.0.0.1:8080/app.
        if let bare = parseBareLoopback(token) { return bare }

        // Paths.
        if token.hasPrefix("/") {
            return .remoteFile(path: (token as NSString).standardizingPath)
        }
        if token.hasPrefix("~/") {
            // The remote home isn't known client-side; the file layer expands
            // "~" on the host, so keep the form.
            return .remoteFile(path: token)
        }
        // Relative: only tokens that look like paths (contain a separator or
        // an extension), never dotfiles/flags/ellipses.
        guard let currentDirectory, currentDirectory.hasPrefix("/") else { return nil }
        guard !token.hasPrefix("-"), !token.hasPrefix("."), !token.contains("..") else { return nil }
        let looksLikePath = token.contains("/")
            || (!(token as NSString).pathExtension.isEmpty && (token as NSString).pathExtension.count <= 12)
        guard looksLikePath else { return nil }
        let joined = (currentDirectory as NSString).appendingPathComponent(token)
        return .remoteFile(path: (joined as NSString).standardizingPath)
    }

    /// "localhost" / "127.x.y.z" / "0.0.0.0" / "::1" / "[::1]" → the address
    /// to dial from the remote side, or nil for a real host.
    private static func loopbackHost(_ host: String) -> String? {
        let lowered = host.lowercased()
        if lowered == "localhost" { return "127.0.0.1" }
        if lowered == "0.0.0.0" { return "127.0.0.1" }
        if lowered == "::1" || lowered == "[::1]" { return "::1" }
        if lowered.hasPrefix("127.") { return lowered }
        return nil
    }

    private static func parseBareLoopback(_ token: String) -> PreviewCandidate? {
        // host:port[/path...] with a loopback host and a numeric port.
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let host = String(token[..<colon])
        guard let loopback = loopbackHost(host) else { return nil }
        let rest = token[token.index(after: colon)...]
        let portPart = rest.prefix { $0.isNumber }
        guard let port = Int(portPart), (1...65535).contains(port) else { return nil }
        let tail = rest.dropFirst(portPart.count)
        guard tail.isEmpty || tail.hasPrefix("/") else { return nil }
        return .localhost(targetHost: loopback, port: port, scheme: "http",
                          pathQuery: tail.isEmpty ? "/" : String(tail))
    }
}
