//
//  SpatialMenuView.swift — the same menu, in the room instead of in a pane
//
//  visionOS only. It exists to answer one question a window cannot: what does
//  this look like at arm's length with nothing behind it? A pane gives the menu
//  a frame, a background and a scale that a room will not, so every judgement
//  made inside one is partly a judgement about the pane.
//
//  ── why a RealityView and not just the view ──────────────────────────────────
//  The first version put the SwiftUI hierarchy straight into the ImmersiveSpace,
//  which compiled, opened, and drew almost nothing — the menu flickered into
//  view for a frame when state changed and vanished again. An immersive space
//  expects RealityKit content; SwiftUI goes in as an ATTACHMENT, which is a real
//  entity with a real transform that persists between state changes.
//
//  The tell was that it appeared exactly when something forced a re-render and
//  not otherwise. Content that only exists during a change is content that was
//  never given anywhere to live.
//
//  ── what did NOT change ──────────────────────────────────────────────────────
//  RadialMenu.swift. It takes a pointer offset and publishes a highlight, and
//  has no opinion about whether it is inside a window, a volume, or an entity
//  floating in someone's living room.
//

#if os(visionOS)
import RealityKit
import SwiftUI

struct SpatialMenuView: View {
    @Bindable var model: MenuModel
    @State private var holdTask: Task<Void, Never>?

    /// One id, named once.
    private static let attachmentID = "radialmenu.attachment"

    /// The plane the menu lives on, in POINTS. Big enough for any tuning the
    /// canvas can reach, and transparent, so the slack costs nothing to look at.
    private static let planeSide: CGFloat = 1400

    var body: some View {
        RealityView { content, attachments in
            guard let menu = attachments.entity(for: Self.attachmentID) else { return }
            place(menu)
            content.add(menu)
        } update: { _, attachments in
            // Re-placed rather than rebuilt: the sliders move an entity that is
            // already in the scene, which is the whole reason this survives a
            // state change when the bare view did not.
            if let menu = attachments.entity(for: Self.attachmentID) { place(menu) }
        } attachments: {
            Attachment(id: Self.attachmentID) { plane }
        }
    }

    /// METRES here, unlike everywhere else in this project, because RealityKit
    /// transforms are metres and converting at the slider would just move the
    /// confusion somewhere it is harder to see.
    private func place(_ e: Entity) {
        e.position = SIMD3<Float>(0,
                                  Float(model.spatialHeight),
                                  -Float(model.spatialDistance))
        e.scale = SIMD3<Float>(repeating: Float(max(model.spatialScale, 0.05)))
    }

    private var plane: some View {
        ZStack {
            // No material, no rounded rectangle, no border. The absence IS the
            // feature — this is the view that tells you whether the menu reads on
            // its own or has been leaning on a panel behind it.
            Color.clear.contentShape(Rectangle())

            // A hairline of the plane's own bounds while you are POSITIONING it.
            // Not in live: chrome is the one thing this view exists to remove.
            // But "I opened it and saw nothing" and "it is behind me" look
            // identical without an edge to find.
            if model.previewOn {
                Rectangle()
                    .strokeBorder(.white.opacity(0.10),
                                  style: StrokeStyle(lineWidth: 2, dash: [18, 14]))
            }

            let c = CGPoint(x: Self.planeSide / 2, y: Self.planeSide / 2)
            let anchor = (model.menuShown && model.menuCenter != .zero) ? model.menuCenter : c

            // Solved here rather than read back from `model.metrics`, for the
            // reason the pane does the same: the published copy is always last
            // frame's answer, so the icons and the origin would sit one frame
            // apart whenever a knob moved.
            let m = model.style.resolved(
                itemCount: model.visibleItems.count,
                maxChildren: model.visibleItems.map(\.children.count).max() ?? 0,
                // nil = unconstrained. There are no window edges in a room, so
                // `fit` has nothing to shrink for and the menu draws at exactly
                // its design size. The only place in the app where you see that.
                available: nil)

            let origin = (model.menuShown || !model.centreOnIcons)
                ? anchor
                : CGPoint(x: anchor.x - m.contentCenter.x, y: anchor.y - m.contentCenter.y)

            RadialMenu(items: model.visibleItems,
                       style: model.style,
                       pointer: model.pointer,
                       isPresented: model.menuShown || model.previewOn,
                       highlight: $model.highlight,
                       available: nil,
                       preview: model.previewOn ? model.previewPose : nil,
                       onResolve: { model.metrics = $0 })
                .position(origin)
        }
        .frame(width: Self.planeSide, height: Self.planeSide)
        .menuInvocation(
            enabled: !model.previewOn,
            onChanged: { start, current in
                guard !model.previewOn else { return }
                if holdTask == nil && !model.menuShown {
                    model.menuCenter = start
                    let delay = model.config.hold
                    holdTask = Task {
                        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                        guard !Task.isCancelled else { return }
                        model.menuShown = true
                    }
                }
                let g = max(model.style.pointerGain, 0.05)
                model.pointer = CGPoint(x: (current.x - model.menuCenter.x) * g,
                                        y: (current.y - model.menuCenter.y) * g)
            },
            onEnded: {
                guard !model.previewOn else { return }
                holdTask?.cancel(); holdTask = nil
                if model.menuShown {
                    model.lastConfirmed = model.highlight.action == nil
                        ? "cancelled (centre)" : model.highlight.labelText
                }
                model.menuShown = false
                model.pointer = nil
            }
        )
    }
}
#endif
