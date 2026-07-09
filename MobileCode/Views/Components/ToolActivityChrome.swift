//
//  ToolActivityChrome.swift
//  CodeAgentsMobile
//
//  Quiet in-chat chrome for tool use / tool result activity rows.
//

import SwiftUI

enum ToolActivityStatus {
    case idle
    case running
    case success
    case error
}

/// Compact, secondary activity row. Expanded technical detail stays behind a tap.
struct ToolActivityChrome<ExpandedContent: View>: View {
    let icon: String
    let title: String
    let detail: String?
    let status: ToolActivityStatus
    let canExpand: Bool
    @Binding var isExpanded: Bool
    @ViewBuilder var expandedContent: () -> ExpandedContent

    @State private var rotation: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard canExpand else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                headerRow
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(canExpand ? (isExpanded ? "Collapse details" : "Show details") : "")
            .accessibilityAddTraits(canExpand ? .isButton : [])

            if isExpanded && canExpand {
                expandedContent()
                    .padding(.top, 8)
                    .padding(.leading, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ToolActivitySurfaceModifier())
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(status == .running ? rotation : 0))
                .onChange(of: status) { _, newValue in
                    updateSpin(for: newValue)
                }
                .onAppear {
                    updateSpin(for: status)
                }

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let detail, !detail.isEmpty {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if status == .success {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            } else if status == .error {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.75))
            }

            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.quaternary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
    }

    private var iconColor: Color {
        switch status {
        case .error:
            return .red.opacity(0.7)
        case .running:
            return .secondary
        case .success, .idle:
            return Color.secondary.opacity(0.7)
        }
    }

    private var accessibilityLabel: String {
        var parts = [title]
        if let detail, !detail.isEmpty {
            parts.append(detail)
        }
        switch status {
        case .running: parts.append("in progress")
        case .success: parts.append("completed")
        case .error: parts.append("failed")
        case .idle: break
        }
        return parts.joined(separator: ", ")
    }

    private func updateSpin(for status: ToolActivityStatus) {
        if status == .running {
            rotation = 0
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            rotation = 0
        }
    }
}

// MARK: - Surface (Liquid Glass + fallback)

private struct ToolActivitySurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
        } else {
            content
                .background(
                    Color(.secondarySystemFill).opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        ToolActivityChrome(
            icon: "server.rack",
            title: "Listed tools",
            detail: "5 tools",
            status: .success,
            canExpand: true,
            isExpanded: .constant(false)
        ) {
            Text("details")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }

        ToolActivityChrome(
            icon: "terminal",
            title: "Running command",
            detail: "ls -la",
            status: .running,
            canExpand: true,
            isExpanded: .constant(false)
        ) {
            EmptyView()
        }

        ToolActivityChrome(
            icon: "xmark.circle",
            title: "Ran command",
            detail: "Permission denied",
            status: .error,
            canExpand: true,
            isExpanded: .constant(true)
        ) {
            Text("exit 1: permission denied")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }
    .padding()
}
