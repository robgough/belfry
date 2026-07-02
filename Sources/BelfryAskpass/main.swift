import AppKit

// SSH_ASKPASS helper for Belfry.
//
// When ssh needs a password / key passphrase (or a host-key confirmation) it
// runs this program with the prompt text as the first argument and reads the
// answer from our stdout. Belfry points ssh here (SSH_ASKPASS + force) because
// its control connection runs in a headless PTY with nowhere to show a prompt —
// without this, a password host just fails and falls into a reconnect loop.
//
// Secrets are written to stdout (a pipe straight to ssh) and never logged. A
// cancel exits non-zero, which ssh treats as a declined prompt.

let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Password:"
let lowered = prompt.lowercased()
// A host-key prompt is a yes/no question, not a secret to type back.
let isConfirmation = lowered.contains("(yes/no")
    || lowered.contains("(yes/no/[fingerprint])")
    || (lowered.contains("authenticity of host") && !lowered.contains("password"))

func emit(_ value: String) {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let alert = NSAlert()
alert.messageText = "Belfry — SSH"
alert.informativeText = prompt
alert.icon = NSImage(named: NSImage.cautionName)

app.activate(ignoringOtherApps: true)

if isConfirmation {
    alert.addButton(withTitle: "Yes")
    alert.addButton(withTitle: "No")
    emit(alert.runModal() == .alertFirstButtonReturn ? "yes" : "no")
    exit(0)
}

let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
alert.accessoryView = field
alert.addButton(withTitle: "OK")
alert.addButton(withTitle: "Cancel")
alert.window.initialFirstResponder = field

if alert.runModal() == .alertFirstButtonReturn {
    emit(field.stringValue)
    exit(0)
} else {
    exit(1)   // cancelled → ssh aborts this authentication method
}
