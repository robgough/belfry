import SwiftUI

/// Toolbar chip for in-flight file transfers. Hidden until there's something
/// to show; while transfers run it draws a live progress ring, and afterwards
/// it lingers (with a failure tint when something went wrong) until cleared.
/// Tapping opens the transfer list — transfers themselves belong to
/// `TransferCenter`, so this button is pure observation.
struct TransfersButton: View {
    let center: TransferCenter
    @State private var showsList = false

    var body: some View {
        if !center.transfers.isEmpty {
            Button {
                showsList.toggle()
            } label: {
                label
            }
            .help("File transfers")
            .popover(isPresented: $showsList, arrowEdge: .bottom) {
                TransfersList(center: center)
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if center.hasActive {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 2)
                if let fraction = center.overallFraction {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: fraction)
                } else {
                    // No totals yet — spin a fixed arc as "working".
                    IndeterminateArc()
                }
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .frame(width: 16, height: 16)
        } else if center.failedCount > 0 {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle")
        }
    }
}

private struct IndeterminateArc: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.3)
            .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// The popover/sheet body listing every transfer with progress and controls.
struct TransfersList: View {
    let center: TransferCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Spacer()
                Button("Clear Finished") { center.clearFinished() }
                    .font(.caption)
                    .disabled(!center.transfers.contains { $0.state.isTerminal })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(center.transfers.reversed()) { transfer in
                        TransferRow(transfer: transfer, center: center)
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .frame(minWidth: 320, maxHeight: 360)
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let center: TransferCenter

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .download
                  ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch transfer.state {
                case .queued:
                    Text("Waiting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .running:
                    ProgressView(value: transfer.fraction)
                        .controlSize(.small)
                    Text(progressCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                case .finished:
                    Text("Done — \(Text(transfer.bytesTransferred, format: .byteCount(style: .file)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                case .cancelled:
                    Text("Cancelled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            trailingControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var progressCaption: String {
        let done = ByteCountFormatter.string(
            fromByteCount: transfer.bytesTransferred, countStyle: .file)
        guard let total = transfer.totalBytes else { return done }
        return "\(done) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch transfer.state {
        case .queued, .running:
            Button {
                center.cancel(transfer)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Cancel")
        case .failed:
            Button {
                center.retry(transfer)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Try again")
        case .finished, .cancelled:
            EmptyView()
        }
    }
}
