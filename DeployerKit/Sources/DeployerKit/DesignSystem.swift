import SwiftUI

/// The recurring visual idioms shared with Intune Deployer, packaged as
/// small components so both apps read the same way.

/// Capsule status pill, e.g. "Managed", "Test tenant".
public struct StatusBadge: View {
    public enum Style {
        /// Accent-tinted pill for affirmative states.
        case tinted
        /// Quiet pill for neutral metadata.
        case neutral
        /// Yellow pill for states that need attention.
        case warning
    }

    private let text: String
    private let style: Style

    public init(_ text: String, style: Style = .tinted) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }

    private var background: AnyShapeStyle {
        switch style {
        case .tinted: AnyShapeStyle(.tint.opacity(0.15))
        case .neutral: AnyShapeStyle(.quaternary)
        case .warning: AnyShapeStyle(.yellow.opacity(0.25))
        }
    }
}

/// The shared pass/fail/warning iconography.
public enum StatusIndicator: Sendable {
    case success
    case failure
    case warning
    case neutral
    case running

    @MainActor
    @ViewBuilder
    public var icon: some View {
        switch self {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Passed")
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Failed")
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityLabel("Needs attention")
        case .neutral:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not applicable")
        case .running:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("In progress")
        }
    }
}

/// The shared sheet skeleton: titled header with a busy spinner, divider,
/// content, divider, footer row.
public struct SheetFrame<Content: View, Footer: View>: View {
    private let title: String
    private let systemImage: String
    private let isBusy: Bool
    private let content: Content
    private let footer: Footer

    public init(
        title: String,
        systemImage: String,
        isBusy: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isBusy = isBusy
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.title3.bold())
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .padding()

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                footer
            }
            .padding()
        }
    }
}

/// The shared detail-page header: large tinted symbol, bold title and a
/// monospaced secondary subtitle.
public struct DetailHeader: View {
    private let systemImage: String
    private let title: String
    private let subtitle: String?

    public init(systemImage: String, title: String, subtitle: String? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.bold())
                if let subtitle {
                    Text(subtitle)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
