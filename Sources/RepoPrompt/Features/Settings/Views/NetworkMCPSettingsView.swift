import SwiftUI

struct NetworkMCPSettingsView: View {
    @ObservedObject var viewModel: NetworkMCPSettingsViewModel
    let windowState: WindowState

    @Environment(\.repoPromptFontScalePreset) private var fontPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            enablementRow
            endpointControls
            listenerStatus
            targetControls
            tokenControls
            trustedClientControls
            exportControls
            safetyNotes
        }
        .task { await viewModel.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Network MCP (Streamable HTTP)")
                .font(fontPreset.subHeadlineBoldFont)
            Spacer()
            if let feedback = viewModel.feedbackMessage {
                Text(feedback)
                    .font(fontPreset.captionFont)
                    .foregroundColor(viewModel.feedbackIsError ? .orange : .green)
                    .lineLimit(2)
            }
        }
    }

    private var enablementRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Enable Network MCP", isOn: Binding(
                    get: { viewModel.snapshot.enabled },
                    set: { enabled in Task { await viewModel.setEnabled(enabled) } }
                ))
                .toggleStyle(SwitchToggleStyle())
                .disabled(!viewModel.canEnable && !viewModel.snapshot.enabled)
                Spacer()
                Text(viewModel.endpointPreview)
                    .font(.system(size: max(fontPreset.rawValue - 2, 9), design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            if !viewModel.canEnable {
                Label("Generate a token and choose a default workspace target before enabling.", systemImage: "lock.fill")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var endpointControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Bind", selection: Binding(
                    get: { viewModel.bindAddressText },
                    set: { viewModel.selectBindAddress($0) }
                )) {
                    ForEach(viewModel.bindAddressOptions, id: \.self) { address in
                        Text(label(forBindAddress: address)).tag(address)
                    }
                }
                .frame(maxWidth: 260)

                TextField("Port", text: $viewModel.portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 82)

                Button("Save Endpoint") {
                    Task { await viewModel.saveEndpointSettings() }
                }
                .buttonStyle(CustomButtonStyle())
            }

            if viewModel.isNonLoopbackBind {
                warningLabel("Non-loopback binding exposes this bearer-token HTTP endpoint to your private LAN. Do not port-forward or expose it to the public internet.")
            }
        }
    }

    private var listenerStatus: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(viewModel.listenerStatus.isListening ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.listenerStatus.userFacingDescription)
                    .font(fontPreset.captionFont)
                    .foregroundColor(viewModel.listenerStatus.lastErrorDescription == nil ? .secondary : .orange)
                Text("Streamable HTTP supports POST /mcp, GET SSE, and DELETE sessions.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var targetControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default Target")
                .font(fontPreset.font.bold())

            Text(viewModel.targetSummary)
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Allow RepoPrompt to open this workspace when a remote client connects", isOn: Binding(
                get: { viewModel.openDefaultTargetIfNeeded },
                set: { enabled in Task { await viewModel.updateDefaultTargetOpenIfNeeded(enabled) } }
            ))
            .font(fontPreset.font)

            HStack(spacing: 8) {
                Button("Use Current Workspace") {
                    Task { await viewModel.setDefaultTarget(from: windowState) }
                }
                .buttonStyle(CustomButtonStyle())

                Button("Clear Target") {
                    Task { await viewModel.clearDefaultTarget() }
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(viewModel.snapshot.defaultTarget == nil)
            }
        }
    }

    private var tokenControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bearer Token")
                .font(fontPreset.font.bold())

            Text(viewModel.tokenSummary)
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(viewModel.snapshot.token == nil ? "Generate & Copy" : "Rotate & Copy") {
                    Task {
                        if viewModel.snapshot.token == nil {
                            await viewModel.generateToken()
                        } else {
                            await viewModel.rotateToken()
                        }
                    }
                }
                .buttonStyle(CustomButtonStyle())

                Button("Copy Token") {
                    Task { await viewModel.copyToken() }
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(viewModel.snapshot.token == nil)

                Button("Delete Token") {
                    Task { await viewModel.deleteToken() }
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(viewModel.snapshot.token == nil)
            }

            Text("Token metadata shows only a label/fingerprint. Raw bearer-token material is copied only by explicit token actions.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
        }
    }

    private var trustedClientControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Trusted LAN Clients")
                    .font(fontPreset.font.bold())
                Spacer()
                Button("Revoke All") {
                    Task { await viewModel.revokeAllTrustedClients() }
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(viewModel.snapshot.trustedClients.isEmpty)
            }

            if viewModel.snapshot.trustedClients.isEmpty {
                Text("No LAN clients are trusted yet. Non-loopback clients require first-connect approval.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            } else {
                ForEach(viewModel.snapshot.trustedClients) { policy in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(policy.clientDisplayName ?? policy.normalizedClientID)
                                .font(fontPreset.font)
                            Text(trustedClientDetail(policy))
                                .font(fontPreset.captionFont)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Revoke") {
                            Task { await viewModel.revokeTrustedClient(policy) }
                        }
                        .buttonStyle(CustomButtonStyle())
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
                }
            }
        }
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote Client Export")
                .font(fontPreset.font.bold())

            HStack(spacing: 8) {
                Button("Copy OpenClaw JSON") { viewModel.copyOpenClawConfig() }
                    .buttonStyle(CustomButtonStyle())
                Button("Copy Generic JSON") { viewModel.copyGenericConfig() }
                    .buttonStyle(CustomButtonStyle())
                Button("Copy Env Snippet") { viewModel.copyEnvironmentSnippet() }
                    .buttonStyle(CustomButtonStyle())
                Button("Copy Notes") { viewModel.copySetupNotes() }
                    .buttonStyle(CustomButtonStyle())
            }

            Text("Exports reference Authorization: Bearer ${REPOPROMPT_MCP_TOKEN}; they never embed the raw token. Use Copy Token separately to populate a shell env var or client secret store.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var safetyNotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            warningLabel("Use HTTP only on loopback or trusted private LANs. Rotate the token if you suspect it was copied to an untrusted place.")
            Text("OpenClaw/remote clients should connect to /mcp with Streamable HTTP. Same-endpoint GET SSE is enabled for attached session streams; legacy two-endpoint HTTP+SSE remains deprecated.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(forBindAddress address: String) -> String {
        switch address {
        case "127.0.0.1": "127.0.0.1 (loopback)"
        case "0.0.0.0": "0.0.0.0 (all IPv4 interfaces)"
        default: address
        }
    }

    private func trustedClientDetail(_ policy: NetworkMCPTrustedClientPolicy) -> String {
        var parts = ["Fingerprint: \(policy.tokenFingerprint)"]
        if let lastAddress = policy.lastAddress {
            parts.append("Last address: \(lastAddress)")
        }
        if let lastUsedAt = policy.lastUsedAt {
            parts.append("Last used: \(lastUsedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func warningLabel(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 12))
            Text(text)
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
