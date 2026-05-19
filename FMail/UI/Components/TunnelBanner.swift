import SwiftUI

/// Persistent top-of-window banner shown whenever the Cloudflare tunnel is
/// in any non-`.off` state. Deliberately loud so the user cannot lose
/// track that their MCP server is reachable from the public internet —
/// the whole point of this view is that "I forgot the tunnel was open"
/// shouldn't be possible.
struct TunnelBanner: View {
    let model: MailModel

    var body: some View {
        switch model.tunnel.state {
        case .off:
            EmptyView()
        case .starting:
            banner(
                background: .orange,
                icon: "antenna.radiowaves.left.and.right",
                primary: "Opening Cloudflare tunnel…",
                secondary: nil,
                buttonLabel: "Cancel",
                buttonRole: .cancel,
                action: { Task { await model.tunnel.stop() } }
            )
        case .running(let url):
            banner(
                background: .red,
                icon: "network",
                primary: "Cloudflare tunnel ACTIVE",
                secondary: url.absoluteString,
                buttonLabel: "Close tunnel",
                buttonRole: .destructive,
                action: { Task { await model.tunnel.stop() } }
            )
        case .stopping:
            banner(
                background: .orange,
                icon: "antenna.radiowaves.left.and.right",
                primary: "Closing tunnel…",
                secondary: nil,
                buttonLabel: nil,
                buttonRole: nil,
                action: nil
            )
        case .error(let message):
            banner(
                background: .yellow,
                icon: "exclamationmark.triangle.fill",
                primary: "Tunnel error",
                secondary: message,
                buttonLabel: "Dismiss",
                buttonRole: .cancel,
                action: { model.tunnel.clearError() }
            )
        }
    }

    @ViewBuilder
    private func banner(
        background: Color,
        icon: String,
        primary: String,
        secondary: String?,
        buttonLabel: String?,
        buttonRole: ButtonRole?,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                if let secondary {
                    Text(secondary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let buttonLabel, let action {
                Button(buttonLabel, role: buttonRole, action: action)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background.opacity(0.92))
    }
}
