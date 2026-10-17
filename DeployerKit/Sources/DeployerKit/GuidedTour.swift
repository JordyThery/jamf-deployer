import SwiftUI

/// One step of the first-launch guided tour.
public struct TourStep<AnchorID: Hashable & Sendable>: Sendable {
    public var title: String
    public var text: String
    /// The view the step points at; nil for full-screen steps like Welcome.
    public var anchorID: AnchorID?
    /// Toolbar items can't carry anchor preferences, so toolbar steps pin the
    /// card top-trailing with an upward arrow instead of a spotlight.
    public var pointsAtToolbar: Bool

    public init(
        title: String,
        text: String,
        anchorID: AnchorID? = nil,
        pointsAtToolbar: Bool = false
    ) {
        self.title = title
        self.text = text
        self.anchorID = anchorID
        self.pointsAtToolbar = pointsAtToolbar
    }
}

/// Drives the guided tour: which step is showing, and first-launch detection.
@Observable
public final class TourState<AnchorID: Hashable & Sendable> {
    public private(set) var index: Int?
    public let steps: [TourStep<AnchorID>]
    private let firstLaunchDefaultsKey: String
    private let defaults: UserDefaults

    public init(
        steps: [TourStep<AnchorID>],
        firstLaunchDefaultsKey: String,
        defaults: UserDefaults = .standard
    ) {
        self.steps = steps
        self.firstLaunchDefaultsKey = firstLaunchDefaultsKey
        self.defaults = defaults
    }

    public var currentStep: TourStep<AnchorID>? {
        guard let index, steps.indices.contains(index) else { return nil }
        return steps[index]
    }

    public func start() {
        index = 0
    }

    public func end() {
        index = nil
    }

    public func next() {
        guard let current = index else { return }
        if current + 1 < steps.count {
            index = current + 1
        } else {
            end()
        }
    }

    public func back() {
        guard let current = index, current > 0 else { return }
        index = current - 1
    }

    /// Marks the tour seen *before* starting it, so skipping and relaunching
    /// doesn't restart it.
    public func startOnFirstLaunch() {
        guard !defaults.bool(forKey: firstLaunchDefaultsKey) else { return }
        defaults.set(true, forKey: firstLaunchDefaultsKey)
        start()
    }
}

/// Collects the bounds of tour targets. A modifier on a List Section lands on
/// every row, so values merge into arrays and the overlay unions the rects.
nonisolated struct TourAnchorPreferenceKey: PreferenceKey {
    // An immutable empty dictionary; Anchor<CGRect> just lacks a Sendable
    // annotation.
    nonisolated(unsafe) static let defaultValue: [AnyHashable: [Anchor<CGRect>]] = [:]

    static func reduce(
        value: inout [AnyHashable: [Anchor<CGRect>]],
        nextValue: () -> [AnyHashable: [Anchor<CGRect>]]
    ) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

extension View {
    /// Marks this view as the target of a tour step.
    public func tourAnchor(_ id: some Hashable & Sendable) -> some View {
        anchorPreference(key: TourAnchorPreferenceKey.self, value: .bounds) {
            [AnyHashable(id): [$0]]
        }
    }

    /// Attaches the tour overlay to the root view and starts the tour on
    /// first launch.
    public func guidedTour<AnchorID: Hashable & Sendable>(_ tour: TourState<AnchorID>) -> some View {
        overlayPreferenceValue(TourAnchorPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                if let step = tour.currentStep {
                    TourOverlay(tour: tour, step: step, anchors: anchors, proxy: proxy)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: tour.index)
        }
        .task {
            tour.startOnFirstLaunch()
        }
    }
}

private struct TourOverlay<AnchorID: Hashable & Sendable>: View {
    var tour: TourState<AnchorID>
    var step: TourStep<AnchorID>
    var anchors: [AnyHashable: [Anchor<CGRect>]]
    var proxy: GeometryProxy

    private var targetRect: CGRect? {
        guard let anchorID = step.anchorID,
              let found = anchors[AnyHashable(anchorID)], !found.isEmpty
        else { return nil }
        let rects = found.map { proxy[$0] }.filter { $0.width > 1 && $0.height > 1 }
        guard var union = rects.first else { return nil }
        for rect in rects.dropFirst() {
            union = union.union(rect)
        }
        return union
    }

    var body: some View {
        let target = targetRect
        ZStack(alignment: .topLeading) {
            dimLayer(cutout: target)
                .contentShape(Rectangle())
                .onTapGesture {} // swallow clicks under the tour

            card
                .frame(width: 400)
                .offset(cardOffset(target: target))
        }
        // No ignoresSafeArea() here: it would shift the whole coordinate
        // space by the title-bar inset and misalign the cutout. The dim path
        // already extends past the safe areas by hand.
    }

    private func dimLayer(cutout: CGRect?) -> some View {
        // Extend beyond the proxy's bounds so the dim covers title bar and
        // safe areas without relying on the overlay's own coordinate space.
        var path = Path()
        let full = CGRect(
            x: -200, y: -200,
            width: proxy.size.width + 400,
            height: proxy.size.height + 400
        )
        path.addRect(full)
        if let cutout {
            path.addRoundedRect(
                in: cutout.insetBy(dx: -4, dy: -4),
                cornerSize: CGSize(width: 8, height: 8)
            )
        }
        return path.fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if step.pointsAtToolbar {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(.tint)
                }
                Text(step.title)
                    .font(.headline)
                Spacer()
                if let index = tour.index {
                    Text("\(index + 1) / \(tour.steps.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(step.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip Tour") { tour.end() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if let index = tour.index, index > 0 {
                    Button("Back") { tour.back() }
                }
                Button(isLastStep ? "Done" : "Next") { tour.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
    }

    private var isLastStep: Bool {
        tour.index == tour.steps.count - 1
    }

    private func cardOffset(target: CGRect?) -> CGSize {
        let cardWidth: CGFloat = 400
        let estimatedCardHeight: CGFloat = 160
        let margin: CGFloat = 16

        if step.pointsAtToolbar {
            return CGSize(width: proxy.size.width - cardWidth - margin, height: margin)
        }
        guard let target else {
            // Center full-screen steps.
            return CGSize(
                width: (proxy.size.width - cardWidth) / 2,
                height: (proxy.size.height - estimatedCardHeight) / 2
            )
        }

        func clamp(_ offset: CGSize) -> CGSize {
            CGSize(
                width: min(max(offset.width, margin), proxy.size.width - cardWidth - margin),
                height: min(max(offset.height, margin), proxy.size.height - estimatedCardHeight - margin)
            )
        }

        // Right of the target, else left, else below.
        if target.maxX + margin + cardWidth < proxy.size.width {
            return clamp(CGSize(width: target.maxX + margin, height: target.minY))
        }
        if target.minX - margin - cardWidth > 0 {
            return clamp(CGSize(width: target.minX - margin - cardWidth, height: target.minY))
        }
        return clamp(CGSize(width: target.minX, height: target.maxY + margin))
    }
}
