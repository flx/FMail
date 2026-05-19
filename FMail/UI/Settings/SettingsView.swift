import SwiftUI
import AppKit

/// FMail's Settings window. MCP server configuration + auth token +
/// Cloudflare tunnel toggle for exposing the loopback MCP endpoint to
/// the public internet.
struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    let model: MailModel

    /// Use `@AppStorage` for the form binding so the toggle/port fields
    /// re-render automatically. The model side reads via `MCPSettings.shared`
    /// — both wrap the same `UserDefaults.standard` keys.
    @AppStorage(MCPSettings.enabledKey) private var enabled: Bool = false
    @AppStorage(MCPSettings.portKey) private var port: Int = MCPSettings.defaultPort
    @AppStorage(MCPSettings.authTokenKey) private var authToken: String = ""
    @AppStorage(MCPSettings.tunnelNameKey) private var tunnelName: String = ""
    @AppStorage(MCPSettings.tunnelPublicURLKey) private var tunnelPublicURL: String = ""

    @State private var copied = false
    @State private var coworkCopied = false
    @State private var setupCopied = false
    @State private var tokenRevealed = false
    @State private var showRecentLogs = false

    var body: some View {
        Form {
            mcpServerSection
            authTokenSection
            tunnelSection
            mcpStatusSection
            clientConfigSection
            privacySection
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 600)
    }

    // MARK: — MCP Server

    private var mcpServerSection: some View {
        Section {
            Toggle("Enable MCP server", isOn: $enabled)
                .onChange(of: enabled) { _, _ in model.applyMCPSettings() }

            HStack {
                Text("Port")
                Spacer()
                TextField("8765", value: $port, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { model.applyMCPSettings() }
            }
            .disabled(!enabled)
        } header: {
            Text("MCP Server")
        } footer: {
            Text("Loopback only by default — exposed on 127.0.0.1 unless you open the Cloudflare tunnel below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: — Auth token

    private var authTokenSection: some View {
        Section {
            HStack(spacing: 8) {
                Group {
                    if authToken.isEmpty {
                        Text("(no token set — server is local-loopback-only)")
                            .foregroundStyle(.secondary)
                            .italic()
                    } else if tokenRevealed {
                        Text(authToken)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } else {
                        Text(String(repeating: "●", count: 16))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !authToken.isEmpty {
                    Button {
                        tokenRevealed.toggle()
                    } label: {
                        Image(systemName: tokenRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(tokenRevealed ? "Hide" : "Reveal")

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(authToken, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy token")
                }
            }

            HStack {
                Button(authToken.isEmpty ? "Generate token" : "Regenerate") {
                    authToken = MCPSettings.generateAuthToken()
                    tokenRevealed = true
                }
                .buttonStyle(.bordered)
                Button("Clear") {
                    authToken = ""
                    tokenRevealed = false
                }
                .buttonStyle(.bordered)
                .disabled(authToken.isEmpty || model.tunnel.state.isLive)
                Spacer()
            }
        } header: {
            Text("Auth Token")
        } footer: {
            Text("Required if you expose this server via the Cloudflare tunnel. Optional for local use — when empty, only loopback connections are accepted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: — Cloudflare tunnel

    private var tunnelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                cloudflaredStatusRow
                loginStatusRow

                LabeledContent("Tunnel name") {
                    TextField("fmail", text: $tunnelName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .disabled(model.tunnel.state.isLive)
                }
                LabeledContent("Public URL") {
                    TextField("https://fmail.your-domain.com", text: $tunnelPublicURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .disabled(model.tunnel.state.isLive)
                }

                tunnelStatusRow
                tunnelButtonRow

                Divider().padding(.vertical, 4)
                setupHelpDisclosure
                recentLogsDisclosure
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Cloudflare Tunnel")
                Spacer()
                if model.tunnel.state.isLive {
                    Label("EXPOSED", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                        .font(.caption.bold())
                }
            }
        } footer: {
            Text("Opens a Cloudflare tunnel that routes your public hostname to this Mac's MCP server. Anyone who learns the URL can reach it — the auth token above is the only thing keeping them out.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cloudflaredStatusRow: some View {
        let path = CloudflaredLocator.locate(override: MCPSettings.cloudflaredPath)
        HStack(spacing: 6) {
            Image(systemName: path != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(path != nil ? .green : .red)
            Text("cloudflared:")
                .foregroundStyle(.secondary)
            Text(path ?? "not found — run `brew install cloudflared`")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var loginStatusRow: some View {
        let loggedIn = CloudflaredLocator.isLoggedIn()
        HStack(spacing: 6) {
            Image(systemName: loggedIn ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(loggedIn ? .green : .orange)
            Text("Login state:")
                .foregroundStyle(.secondary)
            Text(loggedIn ? "~/.cloudflared/cert.pem present" : "not logged in — run `cloudflared tunnel login`")
                .font(.caption.monospaced())
        }
    }

    @ViewBuilder
    private var tunnelStatusRow: some View {
        HStack(spacing: 6) {
            switch model.tunnel.state {
            case .off:
                Circle().fill(.gray).frame(width: 8, height: 8)
                Text("Off").foregroundStyle(.secondary)
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting…").foregroundStyle(.secondary)
            case .running(let url):
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Running")
                    .foregroundStyle(.red)
                    .bold()
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .stopping:
                ProgressView().controlSize(.small)
                Text("Closing…").foregroundStyle(.secondary)
            case .error(let msg):
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var tunnelButtonRow: some View {
        let refusal = model.tunnel.refusalReason()
        HStack {
            switch model.tunnel.state {
            case .off, .error:
                Button("Open tunnel") {
                    Task { await model.tunnel.start() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(refusal != nil && refusal != .alreadyRunning)
                .help(refusal?.userMessage ?? "Open the Cloudflare tunnel.")
            case .starting:
                Button("Cancel") {
                    Task { await model.tunnel.stop() }
                }
                .buttonStyle(.bordered)
            case .running:
                Button("Close tunnel", role: .destructive) {
                    Task { await model.tunnel.stop() }
                }
                .buttonStyle(.borderedProminent)
            case .stopping:
                Button("Closing…") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
            if case .running = model.tunnel.state {
                Spacer()
                Button {
                    copyCoworkConfig()
                } label: {
                    HStack {
                        Image(systemName: coworkCopied ? "checkmark" : "doc.on.doc")
                        Text(coworkCopied ? "Copied" : "Copy Cowork config")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var setupHelpDisclosure: some View {
        DisclosureGroup("One-time setup (run once in Terminal)") {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.setupCommands)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.setupCommands, forType: .string)
                    setupCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { setupCopied = false }
                    }
                } label: {
                    HStack {
                        Image(systemName: setupCopied ? "checkmark" : "doc.on.doc")
                        Text(setupCopied ? "Copied" : "Copy commands")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    private static let setupCommands = """
        brew install cloudflared
        cloudflared tunnel login
        cloudflared tunnel create <NAME>
        cloudflared tunnel route dns <NAME> <HOSTNAME>
        """

    @ViewBuilder
    private var recentLogsDisclosure: some View {
        if !model.tunnel.recentLogLines.isEmpty {
            DisclosureGroup("Recent cloudflared log (\(model.tunnel.recentLogLines.count) lines)", isExpanded: $showRecentLogs) {
                ScrollView {
                    Text(model.tunnel.recentLogLines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(maxHeight: 160)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: — Status

    private var mcpStatusSection: some View {
        Section {
            statusRow
            if case .error(let msg) = model.mcpServerStatus {
                Text(msg)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("MCP Server Status")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.mcpServerStatus {
        case .stopped:
            HStack {
                Circle().fill(.gray).frame(width: 8, height: 8)
                Text("Stopped")
            }
        case .starting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Starting…")
            }
        case .running(let p):
            HStack {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Running on 127.0.0.1:\(p, format: .number.grouping(.never))")
            }
        case .error:
            HStack {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Error")
            }
        }
    }

    // MARK: — Client config

    private var clientConfigSection: some View {
        Section {
            Button {
                copyClaudeCodeConfig()
            } label: {
                HStack {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "Copied" : "Copy local Claude Code config")
                }
            }
            .buttonStyle(.bordered)
            Text("Paste this into ~/.claude/settings.json under \"mcpServers\". Local use (loopback) only — for Cowork, use the tunnel section's copy button while the tunnel is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Set up your MCP client")
        }
    }

    // MARK: — Privacy

    private var privacySection: some View {
        Section {
            Text("FMail's MCP server reads every email in your index — subjects, senders, recipients, body text, attachment bytes — and exposes them to whichever process connects. Local-loopback use stays on this Mac. Opening the Cloudflare tunnel makes the server reachable from the public internet; the auth token is the only thing gating access.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Privacy").foregroundStyle(.orange)
        }
    }

    // MARK: — Clipboard helpers

    private func copyClaudeCodeConfig() {
        var headers = ""
        if !authToken.isEmpty {
            headers = """
                ,
                  "headers": { "Authorization": "Bearer \(authToken)" }
            """
        }
        let snippet = """
        {
          "mcpServers": {
            "fmail": {
              "type": "http",
              "url": "http://127.0.0.1:\(port)/mcp"\(headers)
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { copied = false }
        }
    }

    private func copyCoworkConfig() {
        let baseURL = tunnelPublicURL.trimmingCharacters(in: .whitespaces)
        guard !baseURL.isEmpty, !authToken.isEmpty else { return }
        let snippet = """
        {
          "mcpServers": {
            "fmail": {
              "type": "http",
              "url": "\(baseURL)/mcp",
              "headers": { "Authorization": "Bearer \(authToken)" }
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        coworkCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { coworkCopied = false }
        }
    }
}
