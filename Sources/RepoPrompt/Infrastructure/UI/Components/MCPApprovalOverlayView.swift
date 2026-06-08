//
//  MCPApprovalOverlayView.swift
//  RepoPrompt
//
//  Created by RepoPrompt MCP integration
//

import SwiftUI

/// Inline MCP client approval controls for places where the full-screen overlay is hidden behind
/// the current UI surface, such as toolbar popovers or settings panes.
struct MCPInlineApprovalActionsView: View {
    @ObservedObject var server: MCPServerViewModel
    let clientID: String
    let presentation: MCPApprovalPresentation?

    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: approvalIcon)
                        .foregroundColor(.orange)
                        .imageScale(.medium)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Approval required")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(approvalSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            clientDetailRow

            if let remoteDetails, !remoteDetails.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(remoteDetails, id: \.label) { detail in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(detail.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Text(detail.value)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            if let warning = presentation?.warning, !warning.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption2)
                    Text(warning)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actionButtons
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private var isRemoteApproval: Bool {
        presentation?.transport == .remoteHTTP
    }

    private var approvalIcon: String {
        isRemoteApproval ? "network.badge.shield.half.filled" : "link.badge.plus"
    }

    private var approvalSummary: String {
        if isRemoteApproval {
            "Remote HTTP client \(clientID) wants access to RepoPrompt."
        } else {
            "Local MCP client \(clientID) wants to connect to RepoPrompt."
        }
    }

    private var clientDetailRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(isRemoteApproval ? "Remote" : "Local")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.16)))

            Text(clientID)
                .font(.caption.monospaced())
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
    }

    private var canPersistTrust: Bool {
        presentation?.canPersistTrust ?? true
    }

    private var trustPersistenceDescription: String? {
        presentation?.trustPersistenceDescription
    }

    private var remoteDetails: [(label: String, value: String)]? {
        guard isRemoteApproval else { return nil }
        var details: [(String, String)] = []
        if let address = presentation?.remoteAddress, !address.isEmpty {
            details.append(("Address", address))
        }
        if let fingerprint = presentation?.tokenFingerprint, !fingerprint.isEmpty {
            details.append(("Token", fingerprint))
        }
        return details
    }

    @ViewBuilder
    private var actionButtons: some View {
        if isRemoteApproval {
            remoteActionButtons
        } else {
            localActionButtons
        }
    }

    private var remoteActionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                denyButton

                Spacer(minLength: 0)

                allowOnceButton(isPrimary: true)
                alwaysAllowButton(isPrimary: false)
            }
            if let trustPersistenceDescription {
                Text(trustPersistenceDescription)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption.weight(.medium))
    }

    private var localActionButtons: some View {
        HStack(spacing: 8) {
            denyButton

            Spacer(minLength: 0)

            allowOnceButton(isPrimary: false)
            alwaysAllowButton(isPrimary: true)
        }
        .font(.caption.weight(.medium))
    }

    private var denyButton: some View {
        Button {
            resolve(allow: false, alwaysAllow: false)
        } label: {
            inlineActionLabel("Deny")
        }
        .buttonStyle(MCPDenyButtonStyle())
        .disabled(isResolving)
    }

    private func allowOnceButton(isPrimary: Bool) -> some View {
        Button {
            resolve(allow: true, alwaysAllow: false)
        } label: {
            inlineActionLabel("Allow Once")
        }
        .buttonStyle(isPrimary ? .primaryMCPInline : .secondaryMCPInline)
        .disabled(isResolving)
    }

    private func alwaysAllowButton(isPrimary: Bool) -> some View {
        Button {
            resolve(allow: true, alwaysAllow: true)
        } label: {
            inlineActionLabel(isRemoteApproval ? "Trust Future" : "Always Allow")
        }
        .buttonStyle(isPrimary ? .primaryMCPInline : .secondaryMCPInline)
        .disabled(isResolving || !canPersistTrust)
    }

    private func inlineActionLabel(_ title: String) -> some View {
        Text(title)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
    }

    private func resolve(allow: Bool, alwaysAllow: Bool) {
        guard !isResolving else { return }
        let resolvedAlwaysAllow = alwaysAllow && canPersistTrust
        isResolving = true
        Task {
            await server.resolveApproval(allow: allow, alwaysAllow: resolvedAlwaysAllow)
            await MainActor.run { isResolving = false }
        }
    }
}

private struct MCPInlineApprovalButtonStyle: ButtonStyle {
    enum Emphasis {
        case primary
        case secondary
    }

    let emphasis: Emphasis

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(emphasis == .primary ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }

    private var backgroundColor: Color {
        switch emphasis {
        case .primary:
            Color.green
        case .secondary:
            Color.primary.opacity(0.04)
        }
    }

    private var borderColor: Color {
        switch emphasis {
        case .primary:
            Color.white.opacity(0.2)
        case .secondary:
            Color.primary.opacity(0.12)
        }
    }
}

private extension ButtonStyle where Self == MCPInlineApprovalButtonStyle {
    static var primaryMCPInline: MCPInlineApprovalButtonStyle {
        MCPInlineApprovalButtonStyle(emphasis: .primary)
    }

    static var secondaryMCPInline: MCPInlineApprovalButtonStyle {
        MCPInlineApprovalButtonStyle(emphasis: .secondary)
    }
}

/// A full-screen takeover overlay for MCP client approval requests.
/// Presents a modern, polished UI that blocks interaction until the user responds.
struct MCPApprovalOverlayView: View {
    @EnvironmentObject private var server: MCPServerViewModel
    @State private var alwaysAllow: Bool
    @State private var isAnimating = false
    @State private var pulseScale: CGFloat = 1.0

    let clientID: String
    let presentation: MCPApprovalPresentation?

    init(clientID: String, presentation: MCPApprovalPresentation? = nil) {
        self.clientID = clientID
        self.presentation = presentation
        _alwaysAllow = State(initialValue: presentation?.transport != .remoteHTTP)
    }

    var body: some View {
        ZStack {
            // Animated gradient background
            backgroundLayer

            // Content card
            approvalCard
        }
        .ignoresSafeArea()
        .onAppear {
            resetAlwaysAllowForCurrentPresentation()
            withAnimation(.easeInOut(duration: 0.3)) {
                isAnimating = true
            }
            // Start pulse animation
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseScale = 1.08
            }
        }
        .onChange(of: approvalStateIdentity) { _, _ in
            resetAlwaysAllowForCurrentPresentation()
        }
        .onChange(of: canPersistTrust) { _, canPersistTrust in
            if !canPersistTrust {
                alwaysAllow = false
            }
        }
    }

    // MARK: - Background Layer

    private var backgroundLayer: some View {
        ZStack {
            // Dark overlay
            Color.black.opacity(0.5)

            // Subtle radial gradient from center
            RadialGradient(
                gradient: Gradient(colors: [
                    Color.accentColor.opacity(0.15),
                    Color.clear
                ]),
                center: .center,
                startRadius: 100,
                endRadius: 400
            )
        }
        .opacity(isAnimating ? 1 : 0)
    }

    // MARK: - Approval Card

    private var approvalCard: some View {
        VStack(spacing: 0) {
            // Header with icon
            headerSection

            Divider()
                .background(Color.primary.opacity(0.1))

            // Main content
            contentSection

            Divider()
                .background(Color.primary.opacity(0.1))

            // Actions
            actionsSection
        }
        .frame(width: 420)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 10)
        .scaleEffect(isAnimating ? 1 : 0.9)
        .opacity(isAnimating ? 1 : 0)
    }

    private var cardBackground: some View {
        ZStack {
            // Base material
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)

            // Subtle border
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.2),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Animated connection icon
            ZStack {
                // Outer pulse ring
                Circle()
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 80, height: 80)
                    .scaleEffect(pulseScale)

                // Inner circle with icon
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor,
                                Color.accentColor.opacity(0.8)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 10)

                Image(systemName: "link.badge.plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)

            Text(presentation?.transport == .remoteHTTP ? "Remote Connection Request" : "Connection Request")
                .font(.title2.weight(.semibold))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(spacing: 20) {
            // Client info card
            clientInfoCard

            if let remoteDetails {
                remoteInfoCard(remoteDetails)
            }

            if let warning = presentation?.warning {
                warningCard(warning)
            }

            // Always allow toggle
            alwaysAllowToggle
        }
        .padding(24)
    }

    private var clientInfoCard: some View {
        HStack(spacing: 16) {
            // Client icon
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 48, height: 48)

                Image(systemName: clientIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(clientID)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(presentation?.transport == .remoteHTTP ? "wants remote HTTP access to RepoPrompt" : "wants to connect to RepoPrompt")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private var remoteDetails: [(label: String, value: String)]? {
        guard presentation?.transport == .remoteHTTP else { return nil }
        var details: [(String, String)] = []
        if let address = presentation?.remoteAddress, !address.isEmpty {
            details.append(("Address", address))
        }
        if let fingerprint = presentation?.tokenFingerprint, !fingerprint.isEmpty {
            details.append(("Token", fingerprint))
        }
        return details.isEmpty ? nil : details
    }

    private func remoteInfoCard(_ details: [(label: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(details, id: \.label) { detail in
                HStack(alignment: .firstTextBaseline) {
                    Text(detail.label)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 56, alignment: .leading)
                    Text(detail.value)
                        .font(.caption.monospaced())
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func warningCard(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(warning)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private var clientIcon: String {
        if presentation?.transport == .remoteHTTP {
            return "network.badge.shield.half.filled"
        }
        let lowercased = clientID.lowercased()
        if lowercased.contains("claude") {
            return "brain"
        } else if lowercased.contains("cursor") {
            return "cursorarrow.rays"
        } else if lowercased.contains("vscode") || lowercased.contains("code") {
            return "chevron.left.forwardslash.chevron.right"
        } else if lowercased.contains("codex") {
            return "terminal"
        } else if lowercased.contains("gemini") {
            return "sparkles"
        } else {
            return "app.connected.to.app.below.fill"
        }
    }

    private var canPersistTrust: Bool {
        presentation?.canPersistTrust ?? true
    }

    private var trustPersistenceDescription: String? {
        presentation?.trustPersistenceDescription
    }

    private var approvalStateIdentity: String {
        [
            clientID,
            String(describing: presentation?.transport),
            presentation?.remoteAddress ?? "",
            presentation?.tokenFingerprint ?? "",
            String(canPersistTrust)
        ].joined(separator: "|")
    }

    private func resetAlwaysAllowForCurrentPresentation() {
        alwaysAllow = canPersistTrust && presentation?.transport != .remoteHTTP
    }

    private var alwaysAllowToggle: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $alwaysAllow)
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                .labelsHidden()
                .disabled(!canPersistTrust)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation?.transport == .remoteHTTP ? "Trust this remote client for future connections" : "Always allow this client")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)

                Text(trustPersistenceDescription ?? "Skip approval for future connections")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var allowButtonTitle: String {
        guard alwaysAllow && canPersistTrust else { return "Allow Once" }
        return presentation?.transport == .remoteHTTP ? "Trust Future" : "Always Allow"
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        HStack(spacing: 12) {
            // Deny button
            Button(action: { Task { await deny() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Deny")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            }
            .buttonStyle(MCPDenyButtonStyle())

            // Allow button
            Button(action: { Task { await allow() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text(allowButtonTitle)
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            }
            .buttonStyle(MCPAllowButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    // MARK: - Actions

    private func allow() async {
        withAnimation(.easeInOut(duration: 0.2)) {
            isAnimating = false
        }
        // Small delay for animation
        try? await Task.sleep(nanoseconds: 150_000_000)
        await server.resolveApproval(allow: true, alwaysAllow: alwaysAllow && canPersistTrust)
    }

    private func deny() async {
        withAnimation(.easeInOut(duration: 0.2)) {
            isAnimating = false
        }
        // Small delay for animation
        try? await Task.sleep(nanoseconds: 150_000_000)
        await server.resolveApproval(allow: false, alwaysAllow: false)
    }
}

// MARK: - Custom Button Styles

private struct MCPAllowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.green,
                                Color.green.opacity(0.85)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct MCPDenyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
