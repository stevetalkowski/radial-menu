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

    /// A VOLUME places itself and you move it by hand, so the distance and
    /// height knobs have nothing to act on — the system bar under the box is
    /// the placement control, and a second one in the panel would just disagree
    /// with it. Scale still applies: that is about the menu, not about where the
    /// box is.
    var inVolume = false
    @State private var holdTask: Task<Void, Never>?
    @State private var hands = HandTracker()
    /// Where the pinch STARTED, in world metres. The menu draws centred and the
    /// pointer is the displacement from here — the same contract the mouse and
    /// the touch paths already use, so the component learns nothing new.
    @State private var pinchOrigin: SIMD3<Float>?
    /// Where the menu should sit while a hand is carrying it. `nil` means it is
    /// wherever the placement knobs say.
    @State private var carried: SIMD3<Float>?
    /// So a right-hand pinch commits once per pinch instead of every frame.
    @State private var rightWasPinched = false

    /// One id, named once.
    private static let attachmentID = "radialmenu.attachment"

    /// The plane the menu lives on, in POINTS. Big enough for any tuning the
    /// canvas can reach, and transparent, so the slack costs nothing to LOOK at.
    /// It costs plenty to PINCH through, which is what `interactiveSide` is for.
    private static let planeSide: CGFloat = 1400

    /// How much of the plane accepts a pinch: the menu's own footprint, with a
    /// little room to summon it off-center, and never the whole plane.
    private var interactiveSide: CGFloat {
        let canvas = model.metrics.canvas
        return min(Self.planeSide, max(canvas * 1.15, 320))
    }

    var body: some View {
        realityBody
            .task(id: model.handsOn) {
                guard MenuModel.handDemoEnabled, !inVolume else { return }
                if model.handsOn { await hands.start() } else { hands.stop() }
                model.handNote = hands.status
            }
            // A middle-finger pinch is not a gesture, so there is no gesture
            // callback to hang this on — observing the tracker's published
            // values IS the event stream.
            .onChange(of: hands.right.gap) { _, _ in absorbHands() }
            .onChange(of: hands.left.gap) { _, _ in absorbHands() }
            .onChange(of: hands.right.pinched) { _, _ in absorbHands() }
            .onChange(of: hands.left.pinched) { _, _ in absorbHands() }
            .onDisappear { hands.stop() }
    }

    /// Pinch down summons, movement steers, release confirms — the same three
    /// beats as a mouse drag, which is exactly why nothing below the host has to
    /// change to accept a gesture the system does not report.
    private func absorbHands() {
        guard MenuModel.handDemoEnabled,
              model.handsOn, !inVolume, !model.previewOn else { return }
        model.handNote = hands.status
        switch model.handScheme {
        case .oneHanded: oneHanded()
        case .twoHanded: twoHanded()
        }
    }

    /// EITHER hand, which is the fix for "it only worked on the right".
    ///
    /// There was never a reason for a side here — I read `hands.right` and
    /// stopped. A one-handed gesture belongs to whichever hand you happened to
    /// use, and a left-hander discovering the app works for other people is the
    /// worst possible way to learn about a hardcoded assumption.
    private func oneHanded() {
        carried = nil
        let h: HandTracker.Hand = hands.right.pinched ? hands.right
                                : hands.left.pinched  ? hands.left
                                : (hands.right.gap <= hands.left.gap ? hands.right : hands.left)
        model.handGap = Double(h.gap.isFinite ? h.gap : 0)

        if h.pinched {
            if pinchOrigin == nil {
                pinchOrigin = h.position
                model.menuShown = true
            }
            guard let o = pinchOrigin else { return }
            steer(by: h.position - o)
        } else if pinchOrigin != nil {
            pinchOrigin = nil
            commit()
        }
    }

    /// Left carries, right reaches, right pinch commits.
    ///
    /// The pointer is the RIGHT hand's offset from the LEFT — not from a fixed
    /// point in the room — which is what makes this survive you turning around
    /// or walking to the window. Both terms move together, so their difference
    /// only changes when you actually reach for something.
    private func twoHanded() {
        let l = hands.left, r = hands.right
        model.handGap = Double(l.gap.isFinite ? l.gap : 0)

        guard l.pinched, l.tracked else {
            if model.menuShown { commit() }
            carried = nil; pinchOrigin = nil; rightWasPinched = false
            return
        }

        model.menuShown = true
        // Held a little in FRONT of the hand rather than inside it: at the
        // joint itself your own fingers occlude the middle of the ring, which
        // is exactly where the label goes.
        carried = l.position + SIMD3<Float>(0, 0.02, 0.06)
        pinchOrigin = l.position

        if r.tracked { steer(by: r.position - l.position) }

        // Edge, not level. Committing on the level would fire every frame the
        // right hand stayed closed.
        if r.pinched && !rightWasPinched {
            commit()
            model.menuShown = true       // stays up: the left hand still holds it
        }
        rightWasPinched = r.pinched
    }

    /// Metres to points, on the plane's own axes. RealityKit y is up, SwiftUI y
    /// is down; divided by scale because a plane drawn at half size needs twice
    /// the points for the same amount of arm.
    private func steer(by d: SIMD3<Float>) {
        let k = model.handPointsPerMetre / max(model.spatialScale, 0.05)
        let g = max(model.style.pointerGain, 0.05)
        model.pointer = CGPoint(x: CGFloat(Double(d.x) * k * g),
                                y: CGFloat(Double(-d.y) * k * g))
    }

    private func commit() {
        model.lastConfirmed = model.highlight.action == nil
            ? "cancelled (center)" : model.highlight.labelText
        model.pointer = nil
        model.menuShown = false
    }

    private var realityBody: some View {
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
        // A hand carrying it beats every other placement, because the whole
        // point of that scheme is that the menu goes where you put your hand.
        e.position = inVolume
            ? .zero                       // the volume's own centre
            : carried ?? SIMD3<Float>(0,
                                      Float(model.spatialHeight),
                                      -Float(model.spatialDistance))
        e.scale = SIMD3<Float>(repeating: Float(max(model.spatialScale, 0.05)))
    }

    private var plane: some View {
        ZStack {
            // THE INTERACTIVE SURFACE, and note the two things bounding it.
            //
            // It exists only in LIVE. In preview there is nothing to pinch, and
            // a hit-testable plane hanging in front of you is not neutral — an
            // indirect pinch is aimed by gaze, so an invisible surface between
            // you and the window swallows every glance meant for the panel
            // behind it. A full-plane version of this left no way to reach the
            // toggle that turns it off. Preview now hit-tests nothing at all.
            //
            // And it is the size of the MENU, not the size of the plane. The
            // plane is deliberately oversized so no tuning can outgrow it; that
            // is a layout allowance, and turning a layout allowance into a
            // gaze-blocking wall was the actual mistake.
            //
            // Not `Color.clear`: gaze needs something to land on, and fully
            // transparent content is not a reliable target. A thousandth of an
            // alpha is invisible and unambiguously there.
            if !model.previewOn {
                Color.white.opacity(0.001)
                    .frame(width: interactiveSide, height: interactiveSide)
                    .contentShape(Rectangle())
            }

            // THE SAME EDGE, around the part that is actually live.
            //
            // Steve found this boundary the hard way: by noticing he could only
            // reach the app panels from OUTSIDE it. That is the boundary working
            // and being invisible about it, which is the same thing as not
            // working — you learn where it is by bumping into it.
            //
            // Deliberately the same dashes as the preview edge below, because it
            // states the same kind of fact: here is where this plane's authority
            // ends. Brighter, because in live it is competing with a room rather
            // than a dark canvas. Never hit-tested — it sits ON the surface it
            // describes, and a label that swallowed the thing it labels would be
            // its own small joke.
            if !model.previewOn && model.spatialShowReach && !inVolume {
                Rectangle()
                    .strokeBorder(.white.opacity(0.24),
                                  style: StrokeStyle(lineWidth: 2, dash: [18, 14]))
                    .frame(width: interactiveSide, height: interactiveSide)
                    .allowsHitTesting(false)
            }

            // A hairline of the plane's own bounds while you are POSITIONING it.
            // Not in live: chrome is the one thing this view exists to remove.
            // But "I opened it and saw nothing" and "it is behind me" look
            // identical without an edge to find.
            if model.previewOn {
                Rectangle()
                    .strokeBorder(.white.opacity(0.10),
                                  style: StrokeStyle(lineWidth: 2, dash: [18, 14]))
                    .allowsHitTesting(false)
            }

            // LIVE, with nothing summoned: say where to pinch.
            //
            // The window has always had this — it is the hint under the stage's
            // material. In the room it matters more, not less: there the plane is
            // invisible by design, so without it you are being asked to pinch at
            // a patch of your living room and guess whether anything received it.
            // Which is exactly the position this round started in.
            if !model.previewOn && !model.menuShown {
                VStack(spacing: 12) {
                    Image(systemName: MenuPlatform.invocationGlyph)
                        .font(.system(size: 54, weight: .light))
                    Text(MenuPlatform.hint(for: model.layout))
                        .font(.title3)
                    Text("anywhere on this plane — the menu appears where you pinch")
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.55))
                .allowsHitTesting(false)
            }

            let c = CGPoint(x: Self.planeSide / 2, y: Self.planeSide / 2)
            // ALWAYS the middle of the plane, unlike the window.
            //
            // In a window the menu belongs at the pinch, because the window has
            // visible edges you aimed within. A plane in a room has no visible
            // edges at all — so pinching near one of its corners put the menu
            // half outside a boundary you could not see, cropped and unreadable,
            // with nothing on screen to explain why.
            //
            // Centring costs nothing, because `pointer` is a DELTA from wherever
            // the pinch began: your hand still drives it from where your hand
            // actually is. Only the drawing moves.
            let anchor = c

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

            let origin = (model.menuShown || !model.centerOnIcons)
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
                        ? "cancelled (center)" : model.highlight.labelText
                }
                model.menuShown = false
                model.pointer = nil
            }
        )
    }
}
#endif
