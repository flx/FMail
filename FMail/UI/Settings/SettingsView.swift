import SwiftUI
import AppKit

/// FMail's Settings window. Currently just MCP configuration.
struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    let model: MailModel

    /// Use `@AppStorage` for the form binding so the toggle/port fields
    /// re-render automatically. The model side reads via `MCPSettings.shared`
    /// — both wrap the same `UserDefaults.standard` keys.
    @AppStorage(MCPSettings.enabledKey) private var enabled: Bool = false
    @AppStorage(MCPSettings.portKey) private var port: Int = MCPSettings.defaultPort

    @State private var copied = false

    var body: some View {
        Form {
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
                Text("Loopback only — exposed on 127.0.0.1, never on the LAN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                statusRow
                if case .error(let msg) = model.mcpServerStatus {
                    Text(msg)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Status")
            }

            Section {
                Button {
                    copyClaudeCodeConfig()
                } label: {
                    HStack {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy Claude Code config")
                    }
                }
                .buttonStyle(.bordered)
                Text("Paste this into ~/.claude/settings.json under \"mcpServers\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Set up your MCP client")
            }

            Section {
                Text("FMail's MCP server reads every email in your index — subjects, senders, recipients, body text — and exposes them to whichever local process connects on this port. There is no authentication. Only enable this if you understand and accept that.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy").foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 460)
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

    private func copyClaudeCodeConfig() {
        let snippet = """
        {
          "mcpServers": {
            "fmail": {
              "type": "http",
              "url": "http://127.0.0.1:\(port)/mcp"
            }
          }
        }
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { copied = false }
        }
    }
}
