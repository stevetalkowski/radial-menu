//
//  SpatialMenuView.swift — the same menu, in the room instead of in a pane
//
//  visionOS only. It exists to answer one question you cannot answer from a
//  window: what does this thing look like at arm's length with nothing behind
//  it? A pane gives the menu a frame, a background and a scale that the room
//  will not, and every judgement you make about ring size and icon size inside
//  that pane is a judgement about the pane as much as the menu.
//
//  Note what is NOT here: any change to RadialMenu.swift. The component takes a
//  pointer offset and publishes a highlight, and has no opinion about whether
//  the thing holding it is a window, a volume or a patch of your living room.
//  That contract was drawn at the start of this project and this file is the
//  bill of health for it — a whole new kind of scene, and the component did not
//  notice.
//

#if os(visionOS)
import SwiftUI

struct SpatialMenuView: View {
    @Bindable var model: MenuModel
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // No material, no rounded rectangle, no border. The absence is
                // the feature — this is the view that tells you whether the menu
                // reads on its own or has been leaning on a panel behind it.
                Color.clear.contentShape(Rectangle())

                // A hairline of the plane's own bounds, while you are POSITIONING
                // it. Not in live: chrome is the one thing this view exists to
                // remove. But "I opened it and saw nothing" and "it is behind me"
                // look identical without an edge to find, and at 2400 pt across
                // the plane is easy to be standing inside.
                if model.previewOn {
                    Rectangle()
                        .strokeBorder(.white.opacity(0.12),
                                      style: StrokeStyle(lineWidth: 2, dash: [18, 14]))
                }

                let anchor = (model.menuShown && model.menuCenter != .zero)
                    ? model.menuCenter
                    : CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

                // Same rule as the pane: a preview is centred by its ICONS, a
                // live gesture by its origin, because during a gesture the
                // origin IS the pinch and moving it would break the one contract
                // the component has.
                let origin = model.menuShown
                    ? anchor
                    : CGPoint(x: anchor.x - model.metrics.contentCenter.x,
                              y: anchor.y - model.metrics.contentCenter.y)

                RadialMenu(items: model.visibleItems,
                           style: model.style,
                           pointer: model.pointer,
                           isPresented: model.menuShown || model.previewOn,
                           highlight: $model.highlight,
                           // nil = unconstrained. There are no window edges in a
                           // room, so `fit` has nothing to shrink for and the
                           // menu draws at exactly its design size. This is the
                           // only place in the app where you see that.
                           available: nil,
                           preview: model.previewOn ? model.previewPose : nil,
                           onResolve: { model.metrics = $0 })
                    .position(origin)
            }
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
        // Big enough that an unconstrained menu at any tuning has room, and
        // transparent, so the extra area costs nothing visually.
        .frame(width: 2400, height: 1800)
        .scaleEffect(model.spatialScale)
        // Up off the floor and out in front of you. Both are knobs: the right
        // arm's length for a headset is not a number anybody picks correctly in
        // a text editor, which is the premise of this whole app turned on itself.
        .offset(y: -model.spatialHeight)
        .offset(z: -model.spatialDistance)
    }
}
#endif
