import SwiftUI
import JTKit

/// What demo mode says about the actions it can't run.
enum DemoModeText {
    /// Why an action is dimmed in demo mode.
    /// Kept short, as a tooltip (and VoiceOver hint) should be; the error
    /// a refused action shows explains it in full.
    static let unavailable = "Unavailable in Demo Mode: needs OpenTofu, jamformer or Git"
    /// The preview's footer: demo mode stops at the plan.
    static let deployUnavailable = "Deploying isn't available in Demo Mode."
    /// Settings tabs that work on the real store.
    static let realStoreOnly = "Demo Mode is on. These settings are for your real store; turn off Demo Mode in the Tenant menu to change them."
}

extension View {
    /// Dims an action demo mode can't run, saying why.
    func unavailableInDemoMode(_ isDemo: Bool) -> some View {
        modifier(UnavailableInDemoMode(isDemo: isDemo))
    }

    /// A Settings tab that works on the real store: dimmed with a note
    /// while demo mode is on.
    func realStoreOnly(_ demo: DemoMode) -> some View {
        modifier(RealStoreOnly(demo: demo))
    }
}

private struct UnavailableInDemoMode: ViewModifier {
    let isDemo: Bool

    func body(content: Content) -> some View {
        if isDemo {
            content
                .disabled(true)
                .help(DemoModeText.unavailable)
        } else {
            content
        }
    }
}

private struct RealStoreOnly: ViewModifier {
    let demo: DemoMode

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if demo.isOn {
                Label(DemoModeText.realStoreOnly, systemImage: "testtube.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .top])
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
                .disabled(demo.isOn)
        }
    }
}

/// In place of a screen demo mode can't show (capture and adopt need jamformer).
struct DemoModeUnavailableView: View {
    let title: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "testtube.2")
        } description: {
            Text("Not available in Demo Mode: it runs OpenTofu, jamformer or Git, which would reach Jamf or Git itself instead of the sample data.")
        }
    }
}
