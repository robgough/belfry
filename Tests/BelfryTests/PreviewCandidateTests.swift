import Foundation
import Testing
@testable import Belfry

struct PreviewCandidateTokenTests {
    @Test func extractsTokenUnderColumn() {
        let row = "  ➜  Local:   http://localhost:5173/  "
        let column = row.distance(from: row.startIndex, to: row.range(of: "5173")!.lowerBound)
        #expect(PreviewCandidate.token(inRow: row, column: column) == "http://localhost:5173/")
    }

    @Test func trimsHuggingPunctuation() {
        let row = "see (http://localhost:3000/app)."
        let column = row.distance(from: row.startIndex, to: row.range(of: "3000")!.lowerBound)
        #expect(PreviewCandidate.token(inRow: row, column: column) == "http://localhost:3000/app")
    }

    @Test func whitespaceColumnYieldsNothing() {
        #expect(PreviewCandidate.token(inRow: "a b", column: 1) == nil)
    }
}

struct PreviewCandidateParseTests {
    @Test func localhostURLForms() {
        #expect(PreviewCandidate.parse(token: "http://localhost:5173/", currentDirectory: nil)
            == .localhost(targetHost: "127.0.0.1", port: 5173, scheme: "http", pathQuery: "/"))
        #expect(PreviewCandidate.parse(token: "http://127.0.0.1:8080/api?x=1", currentDirectory: nil)
            == .localhost(targetHost: "127.0.0.1", port: 8080, scheme: "http", pathQuery: "/api?x=1"))
        #expect(PreviewCandidate.parse(token: "http://0.0.0.0:4000", currentDirectory: nil)
            == .localhost(targetHost: "127.0.0.1", port: 4000, scheme: "http", pathQuery: "/"))
        // Default port when the URL has none.
        #expect(PreviewCandidate.parse(token: "http://localhost/x", currentDirectory: nil)
            == .localhost(targetHost: "127.0.0.1", port: 80, scheme: "http", pathQuery: "/x"))
    }

    @Test func bareServerLogForms() {
        #expect(PreviewCandidate.parse(token: "localhost:3000", currentDirectory: nil)
            == .localhost(targetHost: "127.0.0.1", port: 3000, scheme: "http", pathQuery: "/"))
        #expect(PreviewCandidate.parse(token: "127.0.0.1:9000/health", currentDirectory: nil)
            == .localhost(targetHost: "127.0.0.1", port: 9000, scheme: "http", pathQuery: "/health"))
        // Not a port → not a server.
        #expect(PreviewCandidate.parse(token: "localhost:abc", currentDirectory: nil) == nil)
        #expect(PreviewCandidate.parse(token: "foo:3000", currentDirectory: nil) == nil)
    }

    @Test func externalURLsGoToTheBrowser() {
        let parsed = PreviewCandidate.parse(token: "https://example.com/x", currentDirectory: nil)
        #expect(parsed == .webURL(URL(string: "https://example.com/x")!))
    }

    @Test func absoluteAndHomePaths() {
        #expect(PreviewCandidate.parse(token: "/var/log/syslog", currentDirectory: nil)
            == .remoteFile(path: "/var/log/syslog"))
        #expect(PreviewCandidate.parse(token: "~/notes/todo.md", currentDirectory: nil)
            == .remoteFile(path: "~/notes/todo.md"))
    }

    @Test func relativePathsNeedAnAnchor() {
        #expect(PreviewCandidate.parse(token: "src/main.rs", currentDirectory: nil) == nil)
        #expect(PreviewCandidate.parse(token: "src/main.rs", currentDirectory: "/home/rob/proj")
            == .remoteFile(path: "/home/rob/proj/src/main.rs"))
        #expect(PreviewCandidate.parse(token: "Package.swift", currentDirectory: "/code/belfry")
            == .remoteFile(path: "/code/belfry/Package.swift"))
    }

    @Test func conservativeRejections() {
        #expect(PreviewCandidate.parse(token: "hello", currentDirectory: "/x") == nil)
        #expect(PreviewCandidate.parse(token: "--flag", currentDirectory: "/x") == nil)
        #expect(PreviewCandidate.parse(token: ".gitignore", currentDirectory: "/x") == nil)
        #expect(PreviewCandidate.parse(token: "../up.txt", currentDirectory: "/x") == nil)
        #expect(PreviewCandidate.parse(token: "ssh://host/x", currentDirectory: nil) == nil)
    }
}

struct AttachmentNamingTests {
    @Test func sanitizesHostileNames() {
        #expect(AttachmentNaming.sanitized("my file's \"name\".png") == "my file_s _name_.png")
        #expect(AttachmentNaming.sanitized("a/b\\c.txt") == "a_b_c.txt")
        #expect(AttachmentNaming.sanitized("..hidden") == "hidden")
        #expect(AttachmentNaming.sanitized("--rf") == "rf")
        #expect(AttachmentNaming.sanitized("") == "attachment")
        #expect(!AttachmentNaming.sanitized(String(repeating: "x", count: 300) + ".png").isEmpty)
        #expect(AttachmentNaming.sanitized(String(repeating: "x", count: 300) + ".png").count <= 180)
    }

    @Test func deduplicatesWithinTransfer() {
        #expect(AttachmentNaming.deduplicated(["a.png", "a.png", "a.png"])
            == ["a.png", "a-2.png", "a-3.png"])
        #expect(AttachmentNaming.deduplicated(["A.png", "a.png"]) == ["A.png", "a-2.png"])
    }

    @Test func promptQuoting() {
        #expect(AttachmentNaming.promptQuoted("/home/rob/x.png") == "/home/rob/x.png")
        #expect(AttachmentNaming.promptQuoted("/tmp/my file.png") == "'/tmp/my file.png'")
        #expect(AttachmentNaming.promptQuoted("/a/it's.png") == "'/a/it'\\''s.png'")
    }

    @Test func remoteDirectoryShape() {
        let id = UUID(uuidString: "ABCDEF01-0000-4000-8000-000000000000")!
        let dir = AttachmentNaming.remoteDirectory(sessionName: "my proj", transferID: id)
        #expect(dir == "~/.cache/belfry/attachments/my proj/abcdef01")
    }
}
