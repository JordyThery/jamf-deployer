import Foundation
import DeployerKit

/// The first-launch guided tour, re-openable from Help → Guided Tour.
enum JamfDeployerTour {
    static func makeState() -> TourState<TourAnchor> {
        TourState(
            steps: steps,
            firstLaunchDefaultsKey: "hasSeenGuidedTour"
        )
    }

    private static let steps: [TourStep<TourAnchor>] = [
        TourStep(
            title: "Welcome to Jamf Deployer",
            text: "Set up new Jamf tenants to a solid baseline in minutes, keep every tenant healthy over time, and keep a record of every change. This short tour shows you around."
        ),
        TourStep(
            title: "Fleet",
            text: "The dashboard lists every connected tenant: deployment status, Jamf Pro version and expiring Apple tokens, all in one table.",
            anchorID: .fleet
        ),
        TourStep(
            title: "Tenants",
            text: "Connect a tenant with its Jamf API credentials. A preflight checks version, permissions and connections before anything else happens.",
            anchorID: .tenants
        ),
        TourStep(
            title: "Building blocks",
            text: "Baselines are assembled from building blocks — enrollment, FileVault, software updates, compliance and more. Pick blocks on a tenant, fill in their settings, and deploy.",
            anchorID: .catalog
        ),
        TourStep(
            title: "Preview, then deploy",
            text: "Nothing is ever written to a tenant without a preview. You see exactly what would be created, changed or removed — and deploying always asks for confirmation.",
            pointsAtToolbar: true
        ),
        TourStep(
            title: "Everything is recorded",
            text: "Every preview and deploy lands in History, and the Activity Log window (⌘⇧L) shows each call the app makes. Secrets are never logged."
        ),
        TourStep(
            title: "Try it on a test tenant",
            text: "The best first step: connect a test tenant (tick “This is a test tenant” in the wizard) and run its preflight. Production tenants get extra guardrails."
        ),
        TourStep(
            title: "That's the tour",
            text: "Replay it any time from Help → Guided Tour. Now connect your first tenant."
        ),
    ]
}
