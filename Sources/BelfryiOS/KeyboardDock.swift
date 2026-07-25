import SwiftUI
import UIKit

// The floating keyboard dock: Belfry's replacement for a custom accessory
// bar. Rides above the keyboard (or the bottom edge when it's down) as glass
// capsules — sticky Ctrl, Esc, Tab, the shortcut palette, attachments, and a
// keyboard toggle. Long-pressing Ctrl opens the palette (Remux's gesture).

/// Everything the dock overlays on the terminal: the capsule bar itself plus
/// the shortcut palette panel above it.
struct TerminalDockLayer: View {
    let workspace: BelfrySSHWorkspace
    let store: ShortcutStore
    /// Session context for attachments + previews (nil hides the paperclip).
    var context: DockContext?

    @State private var showsPalette = false
    @State private var showsSettings = false
    @State private var showsAttachments = false
    @State private var staging = AttachmentStaging()
    @State private var preview: PresentedPreview?
    /// Arrow-key capsule toggled from the dock's d-pad key; sticky across
    /// launches — someone living in vim/tmux wants it every session. (The
    /// cursor trackpad — long-press-drag on the terminal or the spacebar
    /// floating cursor — remains the gesture alternative.)
    @AppStorage("belfry.dockArrows") private var showsArrows = false

    private var attachmentAction: (() -> Void)? {
        context == nil ? nil : { showsAttachments = true }
    }
    private var attachmentCount: Int { staging.items.count }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if showsPalette {
                ShortcutPalette(store: store, workspace: workspace) {
                    showsSettings = true
                }
                .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }
            if showsArrows {
                arrowPad
                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }
            dock
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.25), value: showsPalette)
        .animation(.spring(duration: 0.25), value: showsArrows)
        .sheet(isPresented: $showsSettings) {
            ShortcutSettingsSheet(store: store)
        }
        .sheet(isPresented: $showsAttachments) {
            if let context {
                AttachmentTraySheet(staging: staging, context: context)
            }
        }
        .sheet(item: $preview) { presented in
            if let context {
                TerminalPreviewSheet(candidate: presented.candidate, context: context)
            }
        }
        .onAppear { installPreviewHook() }
        .onChange(of: context?.currentDirectory) { installPreviewHook() }
    }

    /// Long-press on a token in terminal output → parse → preview. The hook
    /// re-installs when the pane's cwd changes so relative paths resolve
    /// against the current directory, not a stale capture.
    private func installPreviewHook() {
        let currentDirectory = context?.currentDirectory
        workspace.onTokenLongPress = { [weak workspace] point in
            guard let workspace,
                  let row = workspace.terminalView.rowText(at: point),
                  let token = PreviewCandidate.token(inRow: row.text, column: row.column),
                  let candidate = PreviewCandidate.parse(
                      token: token, currentDirectory: currentDirectory)
            else { return }
            if case .webURL(let url) = candidate {
                UIApplication.shared.open(url)   // external links go to Safari
                return
            }
            Haptics.rigid()
            preview = PresentedPreview(candidate: candidate)
        }
    }

    private var dock: some View {
        HStack(spacing: 10) {
            DockCapsule {
                DockKey(
                    label: { Text("ctrl").font(.system(size: 15, weight: .semibold, design: .monospaced)) },
                    isActive: workspace.stickyModifiers.controlArmed
                ) {
                    workspace.stickyModifiers.toggleControl()
                    Haptics.selection()
                } onLongPress: {
                    showsPalette.toggle()
                    Haptics.rigid()
                }
                DockKey(label: { Text("esc").font(.system(size: 15, weight: .semibold, design: .monospaced)) }) {
                    workspace.sendKey(.escape)
                    Haptics.tap()
                }
                DockKey(label: { Text("tab").font(.system(size: 15, weight: .semibold, design: .monospaced)) }) {
                    workspace.sendKey(.tab)
                    Haptics.tap()
                }
                DockKey(label: {
                    Image(systemName: "dpad").font(.system(size: 15, weight: .semibold))
                }, isActive: showsArrows) {
                    showsArrows.toggle()
                    Haptics.selection()
                }
            }
            Spacer(minLength: 0)
            DockCapsule {
                DockKey(label: {
                    Image(systemName: "bolt.fill").font(.system(size: 15, weight: .semibold))
                }, isActive: showsPalette) {
                    showsPalette.toggle()
                    Haptics.tap()
                }
                if let attachmentAction {
                    DockKey(label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 15, weight: .semibold))
                            .overlay(alignment: .topTrailing) {
                                if attachmentCount > 0 {
                                    Text("\(attachmentCount)")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(3)
                                        .background(Circle().fill(AppTheme.accent))
                                        .foregroundStyle(.black)
                                        .offset(x: 8, y: -8)
                                }
                            }
                    }) {
                        attachmentAction()
                        Haptics.tap()
                    }
                }
                DockKey(label: {
                    Image(systemName: "keyboard").font(.system(size: 15, weight: .semibold))
                }) {
                    workspace.toggleKeyboard()
                    Haptics.tap()
                }
            }
        }
    }

    /// Held-to-repeat arrow keys, in reading order left/up/down/right so the
    /// vertical pair sits together (tmux scroll, shell history).
    private var arrowPad: some View {
        DockCapsule {
            RepeatingDockKey(symbol: "arrow.left") { workspace.sendKey(.arrowLeft) }
            RepeatingDockKey(symbol: "arrow.up") { workspace.sendKey(.arrowUp) }
            RepeatingDockKey(symbol: "arrow.down") { workspace.sendKey(.arrowDown) }
            RepeatingDockKey(symbol: "arrow.right") { workspace.sendKey(.arrowRight) }
        }
    }
}

/// A dock key that fires on touch-down and auto-repeats while held — arrows
/// are held keys, not tapped ones. (Tap-style DockKey fires on touch-up.)
private struct RepeatingDockKey: View {
    let symbol: String
    let send: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(repeatTask == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(AppTheme.accent))
            .frame(width: 44, height: 38)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginIfNeeded() }
                    .onEnded { _ in end() }
            )
            .onDisappear { end() }
    }

    private func beginIfNeeded() {
        guard repeatTask == nil else { return }
        send()
        Haptics.tap()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                send()
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func end() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

/// One glass capsule housing a row of dock keys.
private struct DockCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(capsuleBackground)
    }

    @ViewBuilder private var capsuleBackground: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.clear).glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        }
    }
}

/// A single key: 40pt hit target, optional active highlight, optional
/// long-press action (used by Ctrl → palette).
private struct DockKey<Label: View>: View {
    @ViewBuilder let label: () -> Label
    var isActive: Bool = false
    let action: () -> Void
    var onLongPress: (() -> Void)?

    var body: some View {
        label()
            .foregroundStyle(isActive ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
            .frame(width: 44, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isActive ? AppTheme.accent.opacity(0.18) : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.4) {
                (onLongPress ?? action)()
            }
    }
}

// MARK: - Shortcut palette

/// Floating panel above the dock: collection tabs on top, a two-row grid of
/// shortcut tiles below. Stays open across taps so repeated commands are
/// cheap; the bolt key (or tapping the terminal) dismisses it.
struct ShortcutPalette: View {
    let store: ShortcutStore
    let workspace: BelfrySSHWorkspace
    let openSettings: () -> Void

    @AppStorage("belfry.paletteTab") private var selectedTabID: String = ""

    private var selectedCollection: ShortcutCollection? {
        store.collections.first { $0.id.uuidString == selectedTabID }
            ?? store.collections.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.collections) { collection in
                            tab(for: collection)
                        }
                    }
                }
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
            }
            if let collection = selectedCollection {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(46)), GridItem(.fixed(46))], spacing: 8) {
                        ForEach(collection.shortcuts) { shortcut in
                            tile(for: shortcut)
                        }
                    }
                }
                .frame(height: 100)
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(panelBackground)
    }

    private func tab(for collection: ShortcutCollection) -> some View {
        let isSelected = collection.id == selectedCollection?.id
        return Button {
            selectedTabID = collection.id.uuidString
            Haptics.selection()
        } label: {
            Label(collection.title, systemImage: collection.symbol)
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? AppTheme.accent.opacity(0.2) : .clear))
                .foregroundStyle(isSelected ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.secondary))
        }
    }

    private func tile(for shortcut: Shortcut) -> some View {
        Button {
            let workspace = workspace
            Task { await ShortcutExecutor.run(shortcut, on: workspace) }
            Haptics.tap()
        } label: {
            Text(shortcut.title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 46)
                .frame(minWidth: 72)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var panelBackground: some View {
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: 20).fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
        }
    }
}

// MARK: - Settings

/// Manage saved commands: add, edit, delete, per collection. Starter items
/// deleted here stay deleted across app updates (the store remembers).
struct ShortcutSettingsSheet: View {
    let store: ShortcutStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?

    private struct EditTarget: Identifiable {
        var id: UUID { shortcut.id }
        var collectionID: UUID
        var shortcut: Shortcut
        var isNew: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.collections) { collection in
                    Section {
                        ForEach(collection.shortcuts) { shortcut in
                            Button {
                                editing = EditTarget(collectionID: collection.id,
                                                     shortcut: shortcut, isNew: false)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shortcut.title)
                                    Text(shortcut.preview)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                store.removeShortcut(
                                    id: collection.shortcuts[offset].id,
                                    from: collection.id)
                            }
                        }
                        Button {
                            editing = EditTarget(
                                collectionID: collection.id,
                                shortcut: Shortcut(title: "", steps: [.text("", submit: true)]),
                                isNew: true)
                        } label: {
                            Label("Add Command", systemImage: "plus")
                                .font(.callout)
                        }
                    } header: {
                        Label(collection.title, systemImage: collection.symbol)
                    }
                }
            }
            .navigationTitle("Saved Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { target in
                ShortcutEditor(store: store, collectionID: target.collectionID,
                               shortcut: target.shortcut, isNew: target.isNew)
            }
        }
    }
}

/// Minimal editor: title + text + submit toggle. Multi-step and key-based
/// shortcuts are starter-only for now; text covers the overwhelming case.
private struct ShortcutEditor: View {
    let store: ShortcutStore
    let collectionID: UUID
    @State var shortcut: Shortcut
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var submit: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $shortcut.title)
                Section("Sends") {
                    TextField("Command text", text: $text, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Toggle("Press Return after", isOn: $submit)
                }
            }
            .navigationTitle(isNew ? "New Command" : "Edit Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = shortcut
                        if saved.title.isEmpty { saved.title = text }
                        saved.steps = [.text(text, submit: submit)]
                        if isNew {
                            store.addShortcut(saved, to: collectionID)
                        } else {
                            store.updateShortcut(saved, in: collectionID)
                        }
                        dismiss()
                    }
                    .disabled(text.isEmpty)
                }
            }
            .onAppear {
                // Pre-fill from an existing single-text shortcut; other step
                // shapes edit as a fresh text command.
                if case .text(let existing, let existingSubmit) = shortcut.steps.first {
                    text = existing
                    submit = existingSubmit
                }
            }
        }
    }
}

// MARK: - Haptics

/// Prepared, long-lived generators so the first tap has no cold-start lag.
@MainActor
enum Haptics {
    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private static let select = UISelectionFeedbackGenerator()

    static func prewarm() {
        impact.prepare()
        select.prepare()
    }

    static func tap() { impact.impactOccurred(intensity: 0.7) }
    static func rigid() { rigidImpact.impactOccurred() }
    static func selection() { select.selectionChanged() }
}
