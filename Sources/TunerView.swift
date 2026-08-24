//
//  TunerView.swift — the app around the component
//
//  Everything app-specific lives here: how the menu is invoked, where the
//  pointer offset comes from, the live knob panel, and import/export. None of it
//  belongs in the component, and keeping the line clean is what lets
//  RadialMenu.swift be one droppable file.
//
//  WHY A GESTURE AND NOT HAND TRACKING: the menu only needs "how far has the
//  hand moved since the gesture began", and a SwiftUI DragGesture reports
//  exactly that — on visionOS gaze picks the spot and the pinch drags. So there
//  is no ARKit, no entitlements and no permission prompt, and it runs in the
//  Simulator, which means the feel can be iterated without a device round-trip.
//  Moving to hand-tracked joints later swaps the source of the offset and leaves
//  the component untouched.
//
//  EACH LAYOUT KEEPS ITS OWN TUNING: switching radial ⇄ vertical ⇄ horizontal
//  swaps the whole knob set, so the three can be compared honestly rather than
//  sharing one compromise. Everything is written to
//  `Documents/radialmenu-presets.json`, which is readable off the device.
//
//  The knob panel has two modes:
//    • responsive ON  — the sliders are RATIOS of icon size, and the panel
//      prints the points they resolve to. Drag `icon size` and every other
//      number moves with it; drag `icons` or `visible` and the ring re-packs.
//    • responsive OFF — plain absolute point sliders, for pinning an exact
//      layout.
//
//  DESIGN.md explains why each knob exists, and what went wrong before it did.
//

import SwiftUI
import UniformTypeIdentifiers

/// One saved tuning: the component's style plus the two host-side knobs.
struct MenuPreset: Codable, Equatable {
    var style = RadialMenuStyle()
    var hold: Double = 0
    var icons: Int = 8
}

/// What lands in `Documents/radialmenu-presets.json`.
struct PresetFile: Codable {
    /// Bumped when the schema changes; the style decoder is lenient either way.
    var version: Int = 7
    /// The live tuning per layout, keyed "radial" / "vertical" / "horizontal".
    var current: [String: MenuPreset] = [:]
    /// Saved slots, keyed "radial.1" … "horizontal.3".
    var slots: [String: MenuPreset] = [:]

    init(version: Int = 7, current: [String: MenuPreset] = [:], slots: [String: MenuPreset] = [:]) {
        self.version = version
        self.current = current
        self.slots = slots
    }

    // Spelled out rather than synthesised: providing `init(from:)` by hand makes
    // the synthesis rules fiddly, and this file is the one thing standing between
    // a bad decode and losing every number tuned on device.
    private enum CodingKeys: String, CodingKey { case version, current, slots }

    // Tolerant of a round-1..6 file, which has no `version` key at all.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? 1
        current = ((try? c.decodeIfPresent([String: MenuPreset].self, forKey: .current)) ?? nil) ?? [:]
        slots   = ((try? c.decodeIfPresent([String: MenuPreset].self, forKey: .slots)) ?? nil) ?? [:]
    }
}

/// What lands in `Documents/radialmenu-items.json` — the MENU CONTENT, kept
/// deliberately apart from `radialmenu-presets.json`, which holds the FEEL.
///
/// Two files because they are edited in different places by different means: the
/// feel is dialled in by hand, on device, with sliders; the content is typed,
/// with a keyboard, on a Mac. Pushing one has no business disturbing the other.
struct ItemsFile: Codable {
    var version: Int = 1
    var items: [RadialMenuItem] = []

    init(version: Int = 1, items: [RadialMenuItem] = []) {
        self.version = version
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case version, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? 1
        items = ((try? c.decodeIfPresent([RadialMenuItem].self, forKey: .items)) ?? nil) ?? []
    }
}

/// ONE FILE that carries a whole menu: the content AND the feel.
///
/// This is the handoff format. A developer describes their real menu — their
/// categories, their sub-items, their SF Symbols — imports it, tunes it against
/// their own icons rather than someone else's placeholders, and exports it back.
/// One file in, one file out, no Xcode in the middle.
///
/// Decoding is deliberately forgiving: `tuning` may be absent (content only),
/// and a file that is just an items list still loads. Someone hand-writing their
/// first menu should not have to get a wrapper object right to see anything.
struct MenuProject: Codable {
    var version: Int = 1
    var items: [RadialMenuItem] = []
    /// Keyed "radial" / "vertical" / "horizontal".
    var tuning: [String: MenuPreset] = [:]

    init(version: Int = 1, items: [RadialMenuItem] = [], tuning: [String: MenuPreset] = [:]) {
        self.version = version
        self.items = items
        self.tuning = tuning
    }

    private enum CodingKeys: String, CodingKey { case version, items, tuning }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? 1
        items = ((try? c.decodeIfPresent([RadialMenuItem].self, forKey: .items)) ?? nil) ?? []
        tuning = ((try? c.decodeIfPresent([String: MenuPreset].self, forKey: .tuning)) ?? nil) ?? [:]
    }
}

/// One in-flight drag in arrange mode.
///
/// `source` and `target` are both indices into the FULL item list, never into
/// the ring — because the tray and the ring are two views of ONE array, and a
/// drag between them is therefore just a move within it. Every other way of
/// modelling this ended up with two orders that had to be kept in step.
struct ArrangeDrag: Equatable {
    /// Index in `allItems` of the thing being dragged.
    var source: Int
    /// Live position, in the stage's coordinate space.
    var at: CGPoint
    /// Where it would land on release. nil = nowhere; releasing is a no-op.
    var target: Int?
}

struct TunerView: View {
    /// Everything the MENU is. Shared, because on visionOS a second scene draws
    /// the same menu in the room, and two scenes cannot share `@State`.
    @Bindable var model: MenuModel

    // ── shims ────────────────────────────────────────────────────────────────
    //
    // One-line forwards, so every call site below reads exactly as it did when
    // these were `@State`. Deliberate: the extraction is a change of OWNERSHIP,
    // not of behaviour, and mixing the two would have made a mechanical move
    // impossible to review.

    private var layout: RadialMenuLayout {
        get { model.layout } nonmutating set { model.layout = newValue }
    }
    private var configs: [String: MenuPreset] {
        get { model.configs } nonmutating set { model.configs = newValue }
    }
    private var slots: [String: MenuPreset] {
        get { model.slots } nonmutating set { model.slots = newValue }
    }
    private var allItems: [RadialMenuItem] {
        get { model.allItems } nonmutating set { model.allItems = newValue }
    }
    private var previewOn: Bool {
        get { model.previewOn } nonmutating set { model.previewOn = newValue }
    }
    private var previewPose: RadialMenuPreview {
        get { model.previewPose } nonmutating set { model.previewPose = newValue }
    }
    private var menuShown: Bool {
        get { model.menuShown } nonmutating set { model.menuShown = newValue }
    }
    private var menuCenter: CGPoint {
        get { model.menuCenter } nonmutating set { model.menuCenter = newValue }
    }
    private var pointer: CGPoint? {
        get { model.pointer } nonmutating set { model.pointer = newValue }
    }
    private var highlight: RadialMenuHighlight {
        get { model.highlight } nonmutating set { model.highlight = newValue }
    }
    private var lastConfirmed: String {
        get { model.lastConfirmed } nonmutating set { model.lastConfirmed = newValue }
    }
    private var metrics: RadialMenuMetrics {
        get { model.metrics } nonmutating set { model.metrics = newValue }
    }
    private var savedNote: String {
        get { model.savedNote } nonmutating set { model.savedNote = newValue }
    }
    private var itemsNote: String {
        get { model.itemsNote } nonmutating set { model.itemsNote = newValue }
    }
    private var symbolReport: String {
        get { model.symbolReport } nonmutating set { model.symbolReport = newValue }
    }

    private var config: MenuPreset {
        get { model.config }
        nonmutating set { model.configs[layout.rawValue] = newValue; persistSoon() }
    }
    private var style: RadialMenuStyle { model.style }
    private var visibleItems: [RadialMenuItem] { model.visibleItems }

    /// True while the immersive scene owns the menu. Always false off visionOS,
    /// so every `!inRoom` below compiles away to nothing on the other three.
    private var inRoom: Bool {
        #if os(visionOS)
        return model.spatialOn
        #else
        return false
        #endif
    }

    #if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    #endif

    // ── local: how the PANEL is being operated, which no other scene needs ───

    @State private var holdTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var showKnobs = true

    // arrange — the visual item editor.
    //
    // PREVIEW ONLY, and that is not a limitation: arranging needs the menu held
    // open and needs every drag for itself, which is exactly the trade preview
    // mode already makes. In live mode the same drags belong to the menu.
    /// Panel-local, like every other `@State` here: the sound belongs to this
    /// window, not to the menu. The spatial scene writes the same `highlight`,
    /// and this view is always alive to hear it, so one player covers both.
    @State private var audio = MenuAudio()

    @State private var arrangeOn = true
    @State private var drag: ArrangeDrag?
    @State private var picked: String?
    @State private var itemsSaveTask: Task<Void, Never>?

    // export
    @State private var showExport = false
    @State private var exportName = "RadialMenuKit"
    @State private var exportStandalone = true
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var projectURL: URL?

    var body: some View {
        // Siblings, not an overlay. The stage's GeometryReader now measures
        // exactly the space it owns, so the preview centers on what you can SEE
        // and `fit` is true by construction — no panel width written down twice.
        SplitStage {
            ZStack(alignment: .topLeading) {
                stage
                VStack(alignment: .leading, spacing: 4) {
                    Text("last confirmed: \(lastConfirmed)")
                    // On the stage rather than in the panel, because the one
                    // moment you need this is while a drag is in progress — and
                    // you cannot read the panel and drag at the same time.
                    if let r = pointerReadout { Text(r).monospacedDigit() }
                    // The center hint is hidden while the menu is up, so while
                    // previewing it moves here — otherwise nothing on screen
                    // would say how to actually invoke the thing.
                    if previewOn { Text("PREVIEW — switch to live to use it") }
                    if !savedNote.isEmpty {
                        Text(savedNote).foregroundStyle(.green)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(28)
            }
        } panel: {
            knobs
        }
        .task { loadItems(); load() }
        // A POP WHEN THE PICK MOVES — not when the pointer does.
        //
        // `highlight` already changes only on a real landing, which is why this
        // reads off the value rather than off the gesture: no throttle, no
        // "has it been 80 ms", no second definition of what counts as arriving
        // somewhere. The component decided that once; this just listens.
        //
        // Deliberately silent on the way OUT. Returning to the centre is not an
        // arrival, and a menu that pops when you leave every icon as well as
        // when you reach one says the same thing twice as loudly.
        // Hear it the moment you choose it — a cue you have to go and trigger
        // to audition is a cue you compare from memory.
        .onChange(of: model.cue) { _, _ in
            audio.cue = model.cue
            if model.sfxOn { audio.audition() }
        }
        .onChange(of: model.sfxVolume) { _, v in audio.volume = Float(v) }
        .task { audio.cue = model.cue; audio.volume = Float(model.sfxVolume) }
        .onChange(of: model.highlight) { was, now in
            guard model.sfxOn else { return }
            let arrived = now.child ?? now.parent
            let left = was.child ?? was.parent
            guard let arrived, arrived != left else { return }
            audio.pop()
        }
        #if os(macOS)
        // Driven off the VALUE, not the gesture, so every route into and out of
        // "the menu is up" restores the arrow — including ones added later.
        // Still here, and still driven off the VALUE rather than the gesture:
        // the cursor rect only covers the STAGE, and the raw mouse under a 1.35
        // gain travels further than the drawn dot — often across the divider and
        // into the panel. This covers the rest of the window; the rect covers
        // the part you are actually looking at.
        .onChange(of: menuShown && style.showPointer) { _, ownPointer in
            if ownPointer { SystemCursor.hide() } else { SystemCursor.show() }
        }
        .onDisappear { SystemCursor.show() }
        #endif
        #if os(visionOS)
        // Driven from the toggle's VALUE rather than from its action, so the
        // scene follows the state even if something else flips it.
        .onChange(of: model.spatialOn) { _, on in
            Task {
                guard on else { return await dismissSpace() }
                // Report WHICH failure. "Could not open" is not a diagnosis, and
                // the three cases have three different causes: `.error` is
                // almost always the scene not being registered (a missing
                // `UIApplicationSupportsMultipleScenes` will do it), while
                // `.userCancelled` is the system declining, not the app.
                switch await openSpace(id: RadialMenuApp.spatialSpaceID) {
                case .opened:
                    break                       // the scene reads the same model
                case .userCancelled:
                    model.spatialOn = false
                    note("the system cancelled the immersive space")
                case .error:
                    model.spatialOn = false
                    // Deliberately not naming a cause. The first version guessed
                    // "scene not registered", which sent us looking in the Swift
                    // and was wrong — the scene was in the binary all along. The
                    // plist was stale.
                    note("the immersive space refused to open — try ./Tools/build.sh clean vision")
                @unknown default:
                    model.spatialOn = false
                    note("unknown result opening the immersive space")
                }
            }
        }
        #endif
    }

    // MARK: the thing you pinch

    /// The stage, plus the one control you need without reaching for the panel.
    ///
    /// A VStack, not an overlay, and that is load-bearing on macOS: the
    /// invocation gesture is an AppKit view covering the whole field, and in
    /// LIVE mode — the exact mode you need this button in — it claims every
    /// mouse event over its bounds. A sibling strip is simply not inside it.
    /// The alternative was teaching the catcher a rectangle to ignore, which is
    /// the button's geometry written down in a second place.
    private var stage: some View {
        VStack(spacing: 0) {
            stageField
            modeBar
        }
    }

    private var modeBar: some View {
        Picker("mode", selection: $model.previewOn) {
            Text("preview").tag(true)
            Text("live").tag(false)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 300)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private var stageField: some View {
        GeometryReader { geo in
            // The tray is a real STRIP of the stage, not a floating bar. The
            // menu is then centered in what is left, so turning arrange on slides
            // the ring down out of the way instead of parking a panel on top of
            // it — the same lesson SplitStage taught: siblings cannot lie to
            // each other about size.
            let tray = arrangeOn ? Self.trayReserve : 0
            let field = CGSize(width: geo.size.width,
                               height: max(geo.size.height - tray, 1))
            ZStack {
                backdrop

                // ALWAYS at the pinch point — never animate in from screen center
                // it must appear exactly where the gesture began. menuCenter is
                // set on pinch-down, before `menuShown` flips, so the eased
                // appearance happens in place.
                //
                // A PREVIEW, though, belongs in the middle: it is there to be
                // looked at while knobs move, and it should not sit wherever the
                // last test gesture happened to land — least of all in a corner,
                // where fit-to-container would shrink it and skew what you see.
                let anchor = (menuShown && menuCenter != .zero)
                    ? menuCenter
                    : CGPoint(x: field.width / 2, y: tray + field.height / 2)

                // ...and it belongs there by its ICONS, not by its origin. On an
                // arc the origin sits in empty space off to one side of the
                // icons, so every change to gutter, icon size or sweep — all of
                // which move the ring radius — swung the whole layout across the
                // stage. Offsetting by `contentCenter` pins what you can SEE, so
                // the arc now grows and re-spaces in place.
                //
                // Preview only: during a real gesture the origin IS the pinch
                // point, and moving it would break the one contract the component
                // has.
                //
                // SOLVED HERE, not read back from `metrics`. That is the jitter
                // fix, and it was a lag rather than a wobble: `metrics` is
                // published by the component through `onResolve`, so it is always
                // LAST frame's answer. The icons were drawn from this frame's
                // solve and the origin from the previous one, so on a slider drag
                // — arc sweep, arc start, anything that moves `contentCenter` —
                // the two were permanently one frame out of step and the whole
                // layout shimmered along behind the hand.
                //
                // `resolved()` is pure, so calling it twice a frame costs
                // arithmetic and buys exact agreement. `available` still comes
                // from `anchor` and never from `origin`: THAT would be a real
                // loop, metrics → available → metrics.
                let room = centeredRoom(at: CGPoint(x: anchor.x, y: anchor.y - tray),
                                       in: field)
                let m = style.resolved(itemCount: visibleItems.count,
                                       maxChildren: visibleItems.map(\.children.count).max() ?? 0,
                                       available: room)
                let origin = (menuShown || !model.centerOnIcons)
                    ? anchor
                    : CGPoint(x: anchor.x - m.contentCenter.x,
                              y: anchor.y - m.contentCenter.y)

                if inRoom {
                    // ONE scene draws a menu at a time. Both would publish
                    // `metrics` and both would recompute `highlight`, from two
                    // different `available` boxes — so they would fight over the
                    // readout and the pick. Standing down is also honest: you
                    // asked to look at it in the room.
                    VStack(spacing: 8) {
                        Image(systemName: "visionpro")
                            .font(.system(size: 40, weight: .light))
                        Text("showing in the room")
                        Text("turn off `spatial view` to bring it back here")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else {
                RadialMenu(items: visibleItems, style: style, pointer: pointer,
                           isPresented: menuShown || previewOn, highlight: $model.highlight,
                           // The second half of responsive. NOT the stage size:
                           // the menu is centered on the pinch, so the room it has
                           // is the largest box CENTRED THERE that still fits —
                           // half of it is whatever the nearest edge allows.
                           // Handing it the full stage reported "fit 100%" while
                           // a corner pinch drew (and happily hit-tested) icons
                           // past the window edge where they could not be seen.
                           available: room,
                           preview: previewOn ? previewPose : nil,
                           onResolve: { metrics = $0 })
                    .position(origin)
                }

                if arrangeOn && !inRoom {
                    // Chrome, drawn by the HOST. None of this belongs in
                    // RadialMenu.swift: that file is the thing colleagues paste
                    // into their own projects, and it has no business knowing an
                    // editor exists. It publishes its metrics; the editor reads
                    // them and draws on top.
                    // The same fresh solve, for the same reason: dashed seats
                    // read from last frame's metrics would drift off the icons
                    // they are targets for, every time a knob moved.
                    arrangeLayer(origin: origin, width: geo.size.width, m)
                }
            }
            .coordinateSpace(name: Self.stageSpace)
            .contentShape(Rectangle())
            // minimumDistance 0 so the pinch itself starts the gesture — the hold
            // timer, not travel, is what summons the menu.
            //
            // DISABLED in preview, which is new and load-bearing. On macOS this
            // is an AppKit overlay that claims every mouse event in the stage —
            // fine when the stage is one big button, fatal once there are chips
            // to drag inside it. It was already a no-op in preview (the handler
            // returned immediately); now it gets out of the way properly.
            .menuInvocation(
                enabled: !previewOn && !inRoom,
                // macOS only. Puts a BLANK cursor under the mouse while the menu
                // draws its own dot — a fact about the stage that AppKit keeps
                // re-applying, rather than a suppression it keeps lifting.
                hidesCursor: menuShown && style.showPointer,
                onChanged: { start, current in
                    // PREVIEW is for looking; LIVE is for using. Letting a
                    // gesture half-drive a previewed menu meant the pose and the
                    // hand fought over the same pointer, and neither state was
                    // legible. Two clean modes instead of one blended one.
                    guard !previewOn else { return }
                    if holdTask == nil && !menuShown {
                        menuCenter = start
                        let delay = config.hold
                        holdTask = Task {
                            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                            guard !Task.isCancelled else { return }
                            menuShown = true
                        }
                    }
                    // Control–display gain, applied HERE and nowhere else.
                    // The component receives an offset and asks no questions
                    // about the hand that produced it; that is the contract
                    // that lets the same view run off a mouse, a finger and a
                    // pinch. Scaling the offset is the whole mechanism.
                    let g = max(config.style.pointerGain, 0.05)
                    pointer = CGPoint(x: (current.x - menuCenter.x) * g,
                                      y: (current.y - menuCenter.y) * g)
                },
                onEnded: {
                    guard !previewOn else { return }
                    holdTask?.cancel(); holdTask = nil
                    // Release CONFIRMS whatever is highlighted, then the menu goes.
                    if menuShown {
                        lastConfirmed = highlight.action == nil
                            ? "cancelled (center)" : highlight.labelText
                    }
                    menuShown = false
                    pointer = nil
                }
            )
        }
    }

    private var backdrop: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(.regularMaterial)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: MenuPlatform.invocationGlyph)
                        .font(.system(size: 44, weight: .light))
                    Text(hint).font(.title3)
                }
                .foregroundStyle(.secondary)
                .opacity(menuShown || previewOn || inRoom ? 0 : 1)
                .animation(.easeOut(duration: style.easeDuration), value: menuShown)
            }
            .padding(24)
    }

    /// The biggest box centered on `c` that still fits inside `size`, less the
    /// stage's own 24 pt inset on each side. Doubling the distance to the NEAREST
    /// edge is what makes a corner pinch shrink the menu instead of clipping it.
    private func centeredRoom(at c: CGPoint, in size: CGSize) -> CGSize {
        let w = 2 * min(c.x, size.width - c.x) - 48
        let h = 2 * min(c.y, size.height - c.y) - 48
        return CGSize(width: max(w, 1), height: max(h, 1))
    }

    private var hint: String { MenuPlatform.hint(for: layout) }

    /// How far your hand has actually gone, against the bound `pointer reach`
    /// gives it. If the dot has stopped and this keeps climbing, the clamp is
    /// doing its job; if they climb together, it is not.
    ///
    /// The bound shown is the DIAL's. Land on a category with children and the
    /// real bound opens up to the trigger and then to the children — see
    /// `pointerBound` — so a number above this one is not always a clamp.
    private var pointerReadout: String? {
        guard menuShown, let p = pointer else { return nil }
        let r = layout == .radial ? hypot(p.x, p.y) : max(abs(p.x), abs(p.y))
        let bound = layout == .radial
            ? metrics.pointerReach.width
            : max(metrics.pointerReach.width, metrics.pointerReach.height)
        let over = r > bound + 0.5
        return "hand \(pt(r)) · reach bound \(pt(bound))" + (over ? " · past it" : "")
    }

    // MARK: arrange — the category list, edited where you can see it
    //
    // The problem this replaces: the only way to change what the menu contained
    // was to hand-edit JSON, quit, relaunch and look. So the ORDER got tuned to
    // suit the tuner rather than the app — a parent shuffled to index 1 purely
    // so that a two-icon menu still had a sub-menu to look at. Wrong direction:
    // the tool was being fixed by editing the example.
    //
    // Here the list is a strip of chips across the top and the ring below shows
    // dashed outlines at every seat. Drag a chip onto a seat and it moves there;
    // drag a seat back into the strip and it drops out of view. One array, two
    // views of it, and no order that exists only inside the editor.

    /// The tray's geometry, in one place. `stage` reserves `trayReserve` at the
    /// top, `itemTray` fills exactly that, and `dropTarget` uses the same number
    /// to decide what counts as a drop into the strip — so the space the menu
    /// gave up and the space the tray occupies can never disagree.
    ///
    /// `trayTop` is not padding for its own sake: the stage's status lines
    /// ("last confirmed…", "PREVIEW…") are an overlay at the top left, and the
    /// strip was landing on top of them.
    private static let trayTop: CGFloat = 76
    private static let trayHeight: CGFloat = 104
    private static var trayReserve: CGFloat { trayTop + trayHeight }
    private static let stageSpace = "radialMenuStage"

    @ViewBuilder
    private func arrangeLayer(origin: CGPoint, width: CGFloat,
                              _ m: RadialMenuMetrics) -> some View {
        seatTargets(origin: origin, width: width, m)
        itemTray(origin: origin, width: width, m)
        dragProxy(m)
    }

    // MARK: the dashed seats

    /// A hollow outline at every seat the menu currently has, from the SAME
    /// `seat(_:)` the component uses to place its icons — so an outline can
    /// never be a pixel off the thing it is a target for.
    ///
    /// Seat k holds item k, always — there is no window and nothing scrolls.
    @ViewBuilder
    private func seatTargets(origin: CGPoint, width: CGFloat,
                             _ m: RadialMenuMetrics) -> some View {
        let seats = max(min(m.seats, config.icons), 0)
        ForEach(Array(0..<seats), id: \.self) { k in
            let c = seatCenter(k, origin: origin, m)
            let lit = drag?.target == k
            let filled = k < allItems.count
            let d = m.iconSize * (lit ? 1.30 : 1.14)

            Circle()
                .strokeBorder(lit ? Color.accentColor : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: lit ? 3 : 1.5,
                                                 dash: lit ? [] : [7, 6]))
                .frame(width: d, height: d)
                .position(c)
                .allowsHitTesting(false)

            // The drag HANDLE, invisible, sitting over the real icon. Separate
            // from the outline above so the outline can stay non-interactive and
            // keep growing when a drop is pending without swallowing the drag.
            if filled {
                Color.clear
                    .frame(width: m.iconSize, height: m.iconSize)
                    .contentShape(Circle())
                    .position(c)
                    .onTapGesture { picked = allItems[k].id }
                    .gesture(moveGesture(from: k, origin: origin, width: width, m))
            }
        }
    }

    private func seatCenter(_ k: Int, origin: CGPoint, _ m: RadialMenuMetrics) -> CGPoint {
        let s = m.seat(k)
        return CGPoint(x: origin.x + s.x, y: origin.y + s.y)
    }

    // MARK: the tray

    // Laid out by hand rather than in a ScrollView, and for once that IS the
    // simpler option. A scroll view would fight every drag for ownership on
    // touch, and its content offset would have to be tracked to know which chip
    // a drop landed on. Absolute positions from one pitch: the chips shrink to
    // fit instead of scrolling, and `trayIndex(atX:)` is the exact inverse of
    // `trayX(_:)` rather than an approximation of it.

    private func trayPitch(_ width: CGFloat) -> CGFloat {
        let n = CGFloat(allItems.count + 1)          // + the add button
        return min(max((width - 64) / max(n, 1), 30), 78)
    }

    private func trayLeft(_ width: CGFloat) -> CGFloat {
        let span = trayPitch(width) * CGFloat(allItems.count + 1)
        return max((width - span) / 2, 24)
    }

    private func trayX(_ i: Int, _ width: CGFloat) -> CGFloat {
        trayLeft(width) + trayPitch(width) * (CGFloat(i) + 0.5)
    }

    private func trayIndex(atX x: CGFloat, width: CGFloat) -> Int {
        let i = Int(floor((x - trayLeft(width)) / trayPitch(width)))
        return min(max(i, 0), max(allItems.count - 1, 0))
    }

    @ViewBuilder
    private func itemTray(origin: CGPoint, width: CGFloat,
                          _ m: RadialMenuMetrics) -> some View {
        let pitch = trayPitch(width)
        let side = min(pitch - 10, 58)
        let y = Self.trayTop + Self.trayHeight / 2

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20)
                .fill(.thinMaterial)
                .frame(height: Self.trayHeight - 16)
                .overlay(alignment: .topLeading) {
                    Text("\(allItems.count) categories · drag onto a seat")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.leading, 14).padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .position(x: width / 2, y: y)
                .allowsHitTesting(false)

            ForEach(Array(allItems.enumerated()), id: \.element.id) { i, item in
                trayChip(item, index: i, side: side, showLabel: pitch >= 56,
                         origin: origin, width: width, m)
                    .position(x: trayX(i, width), y: y + 6)
            }

            Button { addItem() } label: {
                Image(systemName: "plus")
                    .font(.system(size: side * 0.4, weight: .medium))
                    .frame(width: side, height: side)
            }
            .buttonStyle(.bordered)
            .position(x: trayX(allItems.count, width), y: y + 6)
        }
        // Fix the strip's own height, then pin the strip to the top of the
        // stage. `trayHeight` is reserved once, in `stage`, and consumed here —
        // so the space the menu gave up and the space the tray occupies are the
        // same number rather than two that have to agree.
        .frame(height: Self.trayReserve)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func trayChip(_ item: RadialMenuItem, index i: Int, side: CGFloat,
                          showLabel: Bool, origin: CGPoint, width: CGFloat,
                          _ m: RadialMenuMetrics) -> some View {
        // Beyond `icons` an item is still in the list, just not on the ring.
        // Dimmed rather than hidden: "off the menu" is a state you need to see
        // in order to drag something back out of it.
        let onRing = i < min(config.icons, max(m.seats, 1))
        let isPicked = picked == item.id
        let lifted = drag?.source == i

        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.26)
                    .fill(isPicked ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.16))
                RoundedRectangle(cornerRadius: side * 0.26)
                    .strokeBorder(isPicked ? Color.accentColor : Color.clear, lineWidth: 2)
                glyph(item, size: side * 0.46)
                if !item.children.isEmpty {
                    // The one thing about an item you cannot see from its glyph,
                    // and the one that changes how it behaves.
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: side * 0.16, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: side, height: side, alignment: .bottomTrailing)
                        .padding(.trailing, 2)
                }
            }
            .frame(width: side, height: side)

            if showLabel {
                Text(item.label)
                    .font(.system(size: 9)).lineLimit(1)
                    .frame(width: side + 8)
                    .foregroundStyle(onRing ? Color.primary : Color.secondary)
            }
        }
        .opacity(lifted ? 0.2 : (onRing ? 1 : 0.45))
        .contentShape(Rectangle())
        .onTapGesture { picked = isPicked ? nil : item.id }
        .gesture(moveGesture(from: i, origin: origin, width: width, m))
    }

    // MARK: dragging

    /// One gesture for both ends. A chip and a seat are the same thing being
    /// dragged — an index into `allItems` — so there is one recogniser, one
    /// hit-test and one move. Anything else would be two code paths that have to
    /// agree about where a drop lands.
    private func moveGesture(from i: Int, origin: CGPoint, width: CGFloat,
                             _ m: RadialMenuMetrics) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.stageSpace))
            .onChanged { v in
                let t = dropTarget(v.location, origin: origin, width: width, m)
                drag = ArrangeDrag(source: i, at: v.location, target: t)
            }
            .onEnded { v in
                let t = dropTarget(v.location, origin: origin, width: width, m)
                drag = nil
                guard let t, t != i else { return }
                moveItem(from: i, to: t)
            }
    }

    /// What a drop at `p` would do. Seats win over the tray when both are in
    /// range, because the ring is what the drag is FOR.
    private func dropTarget(_ p: CGPoint, origin: CGPoint, width: CGFloat,
                            _ m: RadialMenuMetrics) -> Int? {
        let seats = max(min(m.seats, config.icons), 0)
        var best: (index: Int, distance: CGFloat)?
        for k in 0..<seats {
            let c = seatCenter(k, origin: origin, m)
            let d = hypot(p.x - c.x, p.y - c.y)
            // Half the pitch, so the catch areas tile the ring without
            // overlapping — the same rule the pick itself uses.
            guard d <= max(m.iconSize, m.pitch / 2) else { continue }
            if best == nil || d < best!.distance { best = (k, d) }
        }
        if let best { return best.index }
        guard p.y <= Self.trayReserve else { return nil }
        return trayIndex(atX: p.x, width: width)
    }

    /// The thing under your hand while it is in flight. Drawn at the top of the
    /// ZStack so it passes over both the tray and the ring.
    @ViewBuilder
    private func dragProxy(_ m: RadialMenuMetrics) -> some View {
        if let d = drag, allItems.indices.contains(d.source) {
            let side = max(m.iconSize * 0.7, 44)
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                glyph(allItems[d.source], size: side * 0.44)
            }
            .frame(width: side, height: side)
            .shadow(radius: 8, y: 3)
            .position(d.at)
            .allowsHitTesting(false)
        }
    }

    // MARK: editing the list

    /// Move, not swap. Dropping onto an occupied seat pushes that item along
    /// rather than trading places with it — swap keeps two items in view and
    /// silently reverses a third, which is never what the hand meant.
    private func moveItem(from: Int, to: Int) {
        guard allItems.indices.contains(from) else { return }
        var out = allItems
        let item = out.remove(at: from)
        out.insert(item, at: min(max(to, 0), out.count))
        allItems = out
        picked = item.id
        // Dragging something onto a seat that only exists because `icons` is
        // high is fine; dragging onto seat 5 when `icons` is 4 cannot happen,
        // because that seat is not drawn. Nothing to clamp.
        saveItemsSoon()
    }

    private func addItem() {
        // A menu tops out at twelve, so the LIST does too. It could have kept
        // going and parked the extras in the tray as alternates — but a bench of
        // spares you cannot put on the ring is a way to accumulate junk, and you
        // found that out by adding a thirteenth.
        guard allItems.count < MenuModel.maxIcons else {
            note("twelve is the ceiling — edit one you have, or delete one first")
            return
        }
        let n = allItems.count + 1
        var id = "item.\(n)"
        var bump = n
        while allItems.contains(where: { $0.id == id }) { bump += 1; id = "item.\(bump)" }
        allItems.append(.init(id: id, systemImage: "circle", label: "New \(bump)"))
        // It lands at the END of the list, which usually means OFF the ring —
        // and deliberately so. Bumping `icons` to swallow every addition would
        // silently re-tune the layout you are in the middle of judging. It is in
        // the tray, dimmed, ready to drag onto a seat; the note says so, because
        // "nothing appeared on the ring" otherwise reads as a broken button.
        picked = id
        symbolReport = validateSymbols()
        saveItemsSoon()
        note(allItems.count <= config.icons
             ? "added — it is on the ring"
             : "added to the tray — drag it onto a seat to put it on the ring")
    }

    private func deleteItem(_ i: Int) {
        guard allItems.indices.contains(i), allItems.count > 2 else {
            note("a menu needs at least two categories"); return
        }
        allItems.remove(at: i)
        var c = config
        c.icons = max(2, min(c.icons, allItems.count, MenuModel.maxIcons))
        config = c
        picked = nil
        symbolReport = validateSymbols()
        saveItemsSoon()
    }

    /// Debounced, exactly like the presets: typing a label should not write the
    /// file on every keystroke.
    private func saveItemsSoon() {
        itemsSaveTask?.cancel()
        itemsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            writeItems()
        }
    }

    @ViewBuilder
    private func glyph(_ item: RadialMenuItem, size: CGFloat) -> some View {
        switch item.icon {
        case .system(let name):
            Image(systemName: name).font(.system(size: size, weight: .regular))
        case .asset(let name):
            Image(name).resizable().scaledToFit().frame(width: size, height: size)
        }
    }

    // MARK: arrange — panel side

    /// The switch, plus the editor for whatever is currently picked.
    ///
    /// The tray does POSITION; this does CONTENT. Splitting them that way is
    /// what keeps the stage purely visual — nothing on the stage is a text field
    /// you have to aim at through a headset.
    @ViewBuilder
    private var arrangeControls: some View {
        Toggle("arrange categories", isOn: $arrangeOn)
            .disabled(!previewOn)
        caption(previewOn
                ? "the tray across the top IS your category list. Drag a chip onto a dashed seat to place it, or drag a seat back into the tray to take it off the ring."
                : "arrange needs PREVIEW — in live mode every drag belongs to the menu.")
        if arrangeOn && previewOn {
            if let i = pickedIndex {
                itemEditor(i)
            } else {
                caption("tap a category — in the tray or on the ring — to rename it, change its symbol, or give it a sub-menu.")
            }
            HStack(spacing: 8) {
                Button("reset categories") { resetItems() }
                    .buttonStyle(.bordered)
                    .tint(.red)
                Spacer()
            }
            caption("back to the twelve shipped examples. The only way out of a list you have made a mess of, short of deleting one at a time.")
        }
    }

    private func resetItems() {
        allItems = MenuModel.defaultItems
        picked = nil
        var c = config
        c.icons = max(2, min(c.icons, allItems.count, MenuModel.maxIcons))
        config = c
        symbolReport = validateSymbols()
        saveItemsSoon()
        note("restored the \(MenuModel.defaultItems.count) example categories")
    }

    private var pickedIndex: Int? {
        guard let picked else { return nil }
        return allItems.firstIndex { $0.id == picked }
    }

    @ViewBuilder
    private func itemEditor(_ i: Int) -> some View {
        if allItems.indices.contains(i) {
            itemEditorBody(i)
        }
    }

    @ViewBuilder
    private func itemEditorBody(_ i: Int) -> some View {
        let item = allItems[i]
        let raw = symbolText(item.icon)
        let ok = MenuPlatform.symbolExists(raw.hasPrefix("asset:") ? "" : raw)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                glyph(item, size: 16)
                Text(item.id).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { deleteItem(i) } label: {
                    Label("delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(allItems.count <= 2)
            }
            TextField("label", text: itemLabel(i)).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                TextField("SF Symbol", text: itemSymbol(i)).textFieldStyle(.roundedBorder)
                // Live, one field at a time — the whole-list report at the
                // bottom of the panel tells you THAT something is wrong; this
                // tells you while you are still typing it.
                Image(systemName: raw.hasPrefix("asset:")
                      ? "photo" : (ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(raw.hasPrefix("asset:")
                                     ? Color.secondary : (ok ? Color.green : Color.orange))
            }
            caption("any SF Symbol name. Prefix `asset:` to use art from your own catalog instead.")
            childEditor(i)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func childEditor(_ i: Int) -> some View {
        let kids = allItems.indices.contains(i) ? allItems[i].children : []
        HStack {
            Text("sub-menu · \(kids.count)").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("add") { addChild(i) }.buttonStyle(.borderless)
        }
        ForEach(Array(kids.enumerated()), id: \.element.id) { j, _ in
            HStack(spacing: 4) {
                TextField("label", text: childLabel(i, j)).textFieldStyle(.roundedBorder)
                TextField("symbol", text: childSymbol(i, j))
                    .textFieldStyle(.roundedBorder).frame(width: 92)
                Button { removeChild(i, j) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        if kids.isEmpty {
            caption("no sub-menu — this category fires on release. Add one and it becomes a parent, with an arrow and a fan.")
        }
    }

    // MARK: item bindings
    //
    // All index-guarded. A binding outlives the row that made it by exactly one
    // layout pass, and deleting an item while its field is focused is the case
    // that finds out.

    private func symbolText(_ icon: RadialMenuIcon) -> String {
        switch icon {
        case .system(let n): n
        case .asset(let n): "asset:" + n
        }
    }

    private func iconFrom(_ raw: String) -> RadialMenuIcon {
        raw.hasPrefix("asset:") ? .asset(String(raw.dropFirst(6))) : .system(raw)
    }

    private func itemLabel(_ i: Int) -> Binding<String> {
        Binding(get: { allItems.indices.contains(i) ? allItems[i].label : "" },
                set: { v in
                    guard allItems.indices.contains(i) else { return }
                    allItems[i].label = v; saveItemsSoon()
                })
    }

    private func itemSymbol(_ i: Int) -> Binding<String> {
        Binding(get: { allItems.indices.contains(i) ? symbolText(allItems[i].icon) : "" },
                set: { v in
                    guard allItems.indices.contains(i) else { return }
                    allItems[i].icon = iconFrom(v)
                    symbolReport = validateSymbols(); saveItemsSoon()
                })
    }

    private func childLabel(_ i: Int, _ j: Int) -> Binding<String> {
        Binding(get: { child(i, j)?.label ?? "" },
                set: { v in
                    guard child(i, j) != nil else { return }
                    allItems[i].children[j].label = v; saveItemsSoon()
                })
    }

    private func childSymbol(_ i: Int, _ j: Int) -> Binding<String> {
        Binding(get: { child(i, j).map { symbolText($0.icon) } ?? "" },
                set: { v in
                    guard child(i, j) != nil else { return }
                    allItems[i].children[j].icon = iconFrom(v)
                    symbolReport = validateSymbols(); saveItemsSoon()
                })
    }

    private func child(_ i: Int, _ j: Int) -> RadialMenuItem? {
        guard allItems.indices.contains(i),
              allItems[i].children.indices.contains(j) else { return nil }
        return allItems[i].children[j]
    }

    private func addChild(_ i: Int) {
        guard allItems.indices.contains(i) else { return }
        let parent = allItems[i]
        var n = parent.children.count
        var id = "\(parent.id).\(n)"
        while parent.children.contains(where: { $0.id == id }) { n += 1; id = "\(parent.id).\(n)" }
        allItems[i].children.append(.init(id: id, systemImage: "circle", label: "Child \(n + 1)"))
        saveItemsSoon()
    }

    private func removeChild(_ i: Int, _ j: Int) {
        guard child(i, j) != nil else { return }
        allItems[i].children.remove(at: j)
        symbolReport = validateSymbols()
        saveItemsSoon()
    }

    // MARK: live knobs — every feel constant, tunable on-device, PER LAYOUT

    @ViewBuilder
    private var knobs: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("feel · \(layout.rawValue)").font(.headline)
                Spacer()
                Button(showKnobs ? "hide" : "knobs") { showKnobs.toggle() }
                    .buttonStyle(.borderless)
            }
            if showKnobs {
                // The panel grew past a headset's comfortable reach in round 7, so
                // it scrolls rather than running off the bottom of the window.
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            layoutPicker
                            previewControls
                            // Grouped so the stack stays inside the ViewBuilder
                            // maximum of 10 direct children.
                            Group {
                                Divider().padding(.vertical, 4)
                                arrangeControls
                            }
                            Divider().padding(.vertical, 4)
                            countKnobs
                            Divider().padding(.vertical, 4)
                            geometryKnobs
                            Divider().padding(.vertical, 4)
                            togglesAndPresets
                        }
                        // Clear of the scroll bar: the right-hand VALUES are the
                        // whole point of these rows, and a scroll indicator
                        // drawn on top of the number you are reading is worse
                        // than one you cannot see. How much clearance that takes
                        // is a per-platform fact — see MenuPlatform.
                        .padding(.trailing, MenuPlatform.scrollGutter)
                    }
                    // The split gives the panel real bounds, so it simply fills
                    // its column and scrolls when the knobs outrun it. No height
                    // cap to pick per platform any more.
                    .frame(maxHeight: .infinity, alignment: .top)
                    // `show` used to reveal the export rows BELOW the fold. The
                    // button that reveals them sits at the very bottom of the
                    // panel, so by the time you can tap it you are already
                    // scrolled to the end — and tapping it looked like it had
                    // done nothing until you scrolled further. Expanding a
                    // section should bring the section with it.
                    //
                    // Anchored to the TOP of the block, not the bottom: expanded
                    // it is often taller than the panel, and `.bottom` would jump
                    // you past the file-name field to the share button at its end.
                    .onChange(of: showExport) { _, on in
                        guard on else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            scroller.scrollTo(Self.exportAnchor, anchor: .top)
                        }
                    }
                }
            }
        }
        .font(.caption)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var layoutPicker: some View {
        Picker("layout", selection: $model.layout) {
            Text("radial").tag(RadialMenuLayout.radial)
            Text("vertical").tag(RadialMenuLayout.vertical)
            Text("horizontal").tag(RadialMenuLayout.horizontal)
        }
        .pickerStyle(.segmented)
        .padding(.bottom, 6)
    }

    /// Pin the menu open so it can be SEEN while it is tuned.
    ///
    /// Before this, the menu only existed for as long as a gesture was held — so
    /// reaching for a slider dismissed the very thing the slider was changing,
    /// and every adjustment had to be judged against a memory of the last one.
    ///
    /// It is not a mock-up: the component builds the pose out of the same
    /// `position()` the drawing uses, so what you see here goes through the
    /// identical pick, nudge, threshold and label path a real gesture takes.
    @ViewBuilder
    private var previewControls: some View {
        Picker("mode", selection: $model.previewOn) {
            Text("preview").tag(true)
            Text("live").tag(false)
        }
        .pickerStyle(.segmented)
        .padding(.bottom, 4)
        // Arrange cannot survive the switch to live: the stage hands every drag
        // back to the menu, so the tray would still be drawn and nothing on it
        // would respond. Put it away rather than leave dead chrome on screen.
        .onChange(of: previewOn) { _, on in
            if !on { arrangeOn = false; drag = nil }
        }
        if previewOn {
            Picker("depth", selection: $model.previewPose.depth) {
                Text(config.style.submenuOnHighlight ? "on category" : "menu")
                    .tag(RadialMenuPreview.Depth.menu)
                Text(config.style.submenuOnHighlight ? "on child" : "+ submenu")
                    .tag(RadialMenuPreview.Depth.submenu)
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 2)
            // Asking for a sub-menu while sitting on an item that has none shows
            // nothing, which reads as broken. Go where there IS one.
            .onChange(of: previewPose.depth) { _, d in
                if d == .submenu, !itemAtPreviewSlotHasChildren { jumpToParent() }
            }
            knob("on item", bindPreviewSlot(), 0...Double(max(metrics.seats - 1, 1)), "",
                 decimals: 2)
            caption("fractional values sit BETWEEN icons — where the falloff and the pointer live")
            HStack(spacing: 8) {
                Button("jump to a parent") { jumpToParent() }
                    .buttonStyle(.bordered)
                    .disabled(firstParentSlot == nil)
                Spacer()
            }
            if firstParentSlot == nil {
                warn("no item on the ring has children — raise `icons`, or turn on ARRANGE and drag a parent onto a seat", .orange)
            }
            Group {
                Toggle("pin arrows", isOn: $model.previewPose.pinArrows)
                Toggle("measure guides", isOn: $model.previewPose.showGuides)
                Picker("center on", selection: $model.centerOnIcons) {
                    Text("origin").tag(false)
                    Text("icons").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.top, 2)
                caption("what the STAGE holds still while you turn a knob. Framing only — it moves nothing in the menu, changes no exported value, and live ignores it entirely, because live already has an origin: the point you clicked.")
                caption(model.centerOnIcons
                        ? "ICONS — the drawn icons are kept in the middle of the stage, so an arc sits centred instead of hanging off a corner. Uses the stage better. The cost is that the box being held still changes SHAPE as `arc sweep` moves the ring radius — so its centre holds while the icons themselves visibly travel, which reads as the layout wobbling. It isn't; the box is."
                        : "ORIGIN — the menu's centre is pinned and NOTHING moves, ever. Also exactly what a live gesture does, since there the origin is your click, so preview and live agree about where things are. The cost is that on a partial arc the icons sit off to one side of the stage — because on an arc they do.")
            }
            caption(previewBlurb)
        } else {
            caption("LIVE — \(MenuPlatform.gestureNoun) on the stage to use the menu for real. Switch to preview to lay it out.")
        }
    }

    /// SubD by preference — the worked example in the default set — then any other
    /// parent. Arrows and sub-menus only exist on items that have children, so
    /// this is the only place those knobs can be judged.
    private var firstParentSlot: Int? {
        if let i = visibleItems.firstIndex(where: { $0.id == "subdiv" }) { return i }
        return visibleItems.firstIndex { !$0.children.isEmpty }
    }

    private var itemAtPreviewSlotHasChildren: Bool {
        let i = Int(previewPose.slot.rounded())
        guard visibleItems.indices.contains(i) else { return false }
        return !visibleItems[i].children.isEmpty
    }

    private func jumpToParent() {
        guard let i = firstParentSlot else { return }
        previewPose.slot = Double(min(i, max(metrics.seats - 1, 0)))
        // Pin them too, or landing on a parent with the sub-menu already out
        // would retire the very arrow you came to look at.
        previewPose.pinArrows = true
    }

    private var previewBlurb: String {
        let name = highlight.action?.label ?? "nothing"
        switch previewPose.depth {
        case .menu: return "\(name) highlighted. Held still and centered on the icons — switch to LIVE to try it with your hand."
        case .submenu: return "\(name) with its children out"
        }
    }

    /// No `fallback`, on purpose: this picks WHICH SEAT the preview highlights,
    /// and "the factory seat" is not a thing anyone means. The row gets no reset
    /// arrow, which is the honest answer.
    private func bindPreviewSlot() -> Knob {
        Knob(value: Binding(get: { previewPose.slot }, set: { previewPose.slot = $0 }))
    }

    /// The two knobs that change WHAT IS ON SCREEN. In responsive mode both of
    /// them re-pack the layout, which is the whole point of round 7.
    @ViewBuilder
    private var countKnobs: some View {
        caption("every value below can be TYPED — tap the number, enter the one you want. The arrow beside it puts that knob back to what it shipped as, and is dim when it already is.")
        knob("hold", bindDouble(\.hold), 0...1.2, "s")
        knob("icons", bindIcons(), 2...Double(MenuModel.maxIcons), "")
        caption(iconsBlurb)
    }

    /// Three different things the icon count can be saying, and the slider alone
    /// says none of them: it stops at your LIST length, so with eight categories
    /// it stops at eight and the ceiling of twelve is invisible.
    private var iconsBlurb: String {
        let on = config.icons, n = allItems.count, cap = MenuModel.maxIcons
        if on >= cap {
            return "a full clock face, and the ceiling. Past twelve a hand stops being able to aim without looking, and the answer is a sub-menu rather than a bigger ring."
        }
        if n > on {
            return "\(on) on the ring; your other \(n - on) are in the tray, dimmed. Drag one onto a seat in ARRANGE to swap it in."
        }
        return "\(on) on the ring, all of them on screen — nothing scrolls, because an item that moves is an item your hand cannot learn. Drag up to \(cap) and past the end of your list it makes new categories for you to name."
    }

    // MARK: the responsive block

    @ViewBuilder
    private var geometryKnobs: some View {
        Toggle("responsive", isOn: bindBool(\.responsive))
        caption(config.style.responsive
                ? "spacing is DERIVED from icon size, count and arc"
                : "spacing is pinned to absolute points")

        // The base unit. In responsive mode this is the only length you need.
        knob("icon size", bind(\.iconSize), 24...160, "pt")
        caption(iconSizeBlurb)

        if config.style.responsive {
            ratio("gutter", bind(\.gutterRatio), 0...1.2,
                  resolved: "\(pt(metrics.gutter)) clear")
            caption(layout == .radial
                    ? "the RULE: keep this much clear between icon rims. The ring radius is SOLVED to obey it."
                    : "the RULE: keep this much clear between icon rims. That IS the pitch.")
            if layout == .radial {
                ratio("ring fit", bind(\.ringSlack), 0.6...2.5,
                      resolved: "ring \(pt(metrics.ringRadius))")
                caption("an OVERRIDE on the solved answer. 1.00 = the tightest ring the gutter allows; above that the ring moves out and the gutter grows as a side effect. Unlike gutter, this does not touch child spacing.")
                knob("child spread", bindStyleDouble(\.childSpread), 10...180, "°")
                regionPicker
                knob("arc start", bindStyleDouble(\.arcStartDegrees), -180...360, "°")
                caption(config.style.arcSweepDegrees >= 359.9
                        ? "on a FULL ring this repeats every step — \(deg(metrics.stepDegrees)) at \(metrics.seats) icons. 0° and \(deg(metrics.stepDegrees)) draw an identical ring; what moved is which ITEM sits at 12 o'clock."
                        : "rotates the whole arc. 0° puts the first item at 12 o'clock.")
                knob("arc sweep", bindArcSweep(), 30...360, "°")
                caption("an open arc runs out at \(deg(maxOpenSweep)) with \(metrics.seats) icons — that is where its step equals its wrap and the spacing is already uniform all the way round. Past it snaps to a full ring, because past it there is no new layout to reach.")
            } else {
                ratio("child pitch", bind(\.childSpacingScale), 0.5...1.6,
                      resolved: pt(metrics.childSpacing))
                ratio("label gap", bind(\.labelGapRatio), 0...1.5,
                      resolved: pt(metrics.labelGap))
            }
            // Grouped: this branch was at the ViewBuilder maximum of 10 direct
            // children, and `nudge spread` would have been the eleventh.
            Group {
                ratio("nudge", bind(\.nudgeRatio), 0...0.8, resolved: pt(metrics.nudge))
                knob("nudge spread", bind(\.nudgeSpread), 0...3, " seats")
                caption(config.style.nudgeSpread < 0.01
                        ? "0 = only the selected icon moves"
                        : "neighbours lean in proportion to how near your hand is — continuous feedback BETWEEN icons")
                // ONE dead-zone knob per layout, not two. Radial measures
                // against the trip to the icons; the linear layouts have no ring
                // to measure against and keep the icon-relative one. Showing
                // both at once is how you get a panel nobody trusts.
                if layout == .radial {
                    ratio("pick at", bind(\.deadZoneOfRing), 0...0.9,
                          resolved: "\(pt(metrics.deadZone)) of \(pt(metrics.ringRadius))")
                } else {
                    ratio("dead zone", bind(\.deadZoneRatio), 0...2,
                          resolved: pt(metrics.deadZone))
                }
                caption(deadZoneBlurb)
                ratio("submenu at", bind(\.submenuReachRatio), 0.1...4,
                      resolved: pt(metrics.submenuThreshold))
                caption(submenuBlurb + (layout == .radial ? " · × ring radius" : " · × icon size"))
                if metrics.submenuThresholdFloored {
                    warn("raised to \(pt(metrics.submenuThreshold)) — you asked for a boundary INSIDE the icons, which would let a tangential drift along the ring pick children you never reached for. Raise `submenu at` past \(layout == .radial ? "the rim" : "half an icon").", .orange)
                }
                if layout != .radial { childSidePicker }
            }
            // Grouped for the same reason as above — and because these belong
            // together anyway: everything a sub-menu does.
            Group {
                ratio("child gap", bind(\.childGapRatio), 0.2...3,
                      resolved: pt(metrics.childGap))
                ratio("child nudge", bind(\.childNudgeRatio), 0...0.8,
                      resolved: pt(metrics.childNudge))
                caption("the same pop-out, for the highlighted CHILD — × child icon, not parent icon. In a row or a column it pops ACROSS the run, never along it: along would shove it straight into its own neighbour.")
                ratio("child icon", bind(\.childIconScale), 0.4...1.2,
                      resolved: pt(metrics.childIconSize))
                ratio("label size", bind(\.labelFontScale), 0.15...0.8,
                      resolved: pt(metrics.labelFontSize))
            }
        } else {
            if layout == .radial {
                knob("ring radius", bind(\.ringRadius), 40...400, "pt")
                knob("child spread", bindStyleDouble(\.childSpread), 10...180, "°")
                regionPicker
                knob("arc start", bindStyleDouble(\.arcStartDegrees), -180...360, "°")
                caption(config.style.arcSweepDegrees >= 359.9
                        ? "on a FULL ring this repeats every step — \(deg(metrics.stepDegrees)) at \(metrics.seats) icons. 0° and \(deg(metrics.stepDegrees)) draw an identical ring; what moved is which ITEM sits at 12 o'clock."
                        : "rotates the whole arc. 0° puts the first item at 12 o'clock.")
                knob("arc sweep", bindArcSweep(), 30...360, "°")
                caption("an open arc runs out at \(deg(maxOpenSweep)) with \(metrics.seats) icons — that is where its step equals its wrap and the spacing is already uniform all the way round. Past it snaps to a full ring, because past it there is no new layout to reach.")
            } else {
                knob("row pitch", bind(\.linearSpacing), 40...220, "pt")
                knob("child pitch", bind(\.childSpacingScale), 0.5...1.6, "×")
                knob("label gap", bind(\.labelGap), 0...80, "pt")
            }
            knob("nudge", bind(\.nudge), 0...48, "pt")
            knob("nudge spread", bind(\.nudgeSpread), 0...3, " seats")
            knob("dead zone", bind(\.deadZone), 0...120, "pt")
            knob("submenu at", bind(\.submenuThreshold), 20...400, "pt")
            caption(submenuBlurb)
            knob("child gap", bind(\.childRingGap), 20...260, "pt")
        }

        // Grouped to stay inside the ViewBuilder maximum of 10 direct children.
        Group {
            ratio("hand gain", bind(\.pointerGain), 0.4...3,
                  resolved: "\(Int((metrics.ringRadius / max(config.style.pointerGain, 0.05)).rounded())) pt hand")
            caption(config.style.pointerGain > 1.02
                    ? "control–display gain. Your hand moves LESS than the menu — the readout is the REAL travel to reach the ring."
                    : (config.style.pointerGain < 0.98
                       ? "control–display gain below 1: your hand moves MORE than the menu. Finer, and slower."
                       : "control–display gain. 1.00 = your hand travels exactly the distances printed in this panel."))

            knob("ease frames", bindStyleDouble(\.easeFrames), 1...30, "f")
            knob("arrow size", bind(\.arrowScale), 0.08...0.40, "×")
            ratio("arrow gap", bind(\.arrowGapRatio), 0...0.8,
                  resolved: pt(metrics.iconSize * config.style.arrowGapRatio))
        }

        Toggle("fit to window", isOn: bindBool(\.fitToContainer))
        metricsReadout
    }

    /// The honest answer to "what did those ratios actually become". Everything
    /// here comes back from the component itself, not from a second copy of the
    /// maths in the panel — so if the two ever disagreed, this is where it shows.
    @ViewBuilder
    private var metricsReadout: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("resolved").font(.caption2).foregroundStyle(.secondary)
            Text(layout == .radial
                 ? "ring \(pt(metrics.ringRadius)) · step \(deg(metrics.stepDegrees)) · gutter \(pt(metrics.gutter))"
                 : "pitch \(pt(metrics.pitch)) · gutter \(pt(metrics.gutter))")
                .monospacedDigit()
            Text("icon \(pt(metrics.iconSize)) · canvas \(pt(metrics.canvas)) · fit \(Int((metrics.fit * 100).rounded()))%")
                .monospacedDigit()
                // Color on both arms on purpose: `.secondary` here is a
                // HierarchicalShapeStyle, and a ternary needs one type.
                .foregroundStyle(metrics.fit < 0.999 ? Color.orange : Color.secondary)
            // The reviewer's "feedback dead zone", quantified. `across` is the
            // gutter under another name — the tool can now show you what a wider
            // ring costs in blind travel, instead of leaving it to be felt.
            Text("blind travel \(pt(metrics.blindAcross)) across · \(pt(metrics.blindAlong)) \(layout == .radial ? "in/out" : "sideways")")
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
            warnings
        }
        .font(.caption2)
        .padding(.top, 4)
    }

    /// Everything that is wrong right now, in words. The whole reason to derive
    /// geometry is that the bad cases become detectable — so they get said out
    /// loud instead of leaving you to wonder why an icon won't light up.
    @ViewBuilder
    private var warnings: some View {
        if metrics.fit < 0.999 {
            warn("shrunk to fit — pinch nearer the middle, or turn off “fit to window”", .orange)
        }
        if metrics.gutter < 0 {
            warn("icons OVERLAP by \(pt(-metrics.gutter)) — raise gutter\(layout == .radial ? ", ring fit, or arc sweep" : "")", .red)
        }
        if metrics.childGutter < 0 {
            warn("sub-menu icons OVERLAP by \(pt(-metrics.childGutter)) — raise child gap or child spread", .red)
        }
        if metrics.reachableCount < metrics.seats {
            warn("only the first \(metrics.reachableCount) of \(metrics.seats) can be reached — widen the arc, or use fewer icons", .red)
        }
        if deadZoneSwallowsMenu {
            warn("dead zone is past the icons — nothing can highlight", .red)
        }
    }

    /// A dead zone larger than the menu itself is silently fatal: the guard in
    /// `recomputeHighlight` rejects every sample and nothing ever lights up.
    private var deadZoneSwallowsMenu: Bool {
        let reach = layout == .radial
            ? metrics.ringRadius
            : metrics.pitch * CGFloat(max(metrics.seats - 1, 1)) / 2 + metrics.iconSize / 2
        return metrics.deadZone > reach
    }

    @ViewBuilder
    private func warn(_ s: String, _ tint: Color) -> some View {
        Text(s)
            .font(.caption2).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var regionPicker: some View {
        // A few icons usually want a REGION, not the whole ring.
        Picker("region", selection: quadrantBinding) {
            Text("full").tag(-1)
            Text("12–3").tag(0)
            Text("3–6").tag(1)
            Text("6–9").tag(2)
            Text("9–12").tag(3)
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var togglesAndPresets: some View {
        // EVERYTHING that gets drawn, in one place, visible in every mode.
        //
        // These used to be split: label and the sub-menu flags here, the pointer
        // and the center ring inside the preview-only section. Which meant that
        // in LIVE — the mode where you are actually using the thing — none of
        // the pointer switches could be reached at all.
        Group {
            Text("what gets drawn").font(.subheadline.weight(.semibold))
            Toggle("label", isOn: bindBool(\.showLabel))
            Toggle("submenu arrow", isOn: bindBool(\.showSubmenuArrow))
            Toggle("submenu guide", isOn: bindBool(\.showSubmenuGuide))
            caption("the dashed trigger and its dotted landing circle: a TUNING overlay, and the one thing in this list nobody ships. Everything else here is the menu's design.")
        }
        pointerControls
        Group {
            Toggle("sound", isOn: $model.sfxOn)
            if model.sfxOn {
                cuePicker
                knob("level", $model.sfxVolume, 0...1, "", decimals: 2, resetTo: 0.6)
                caption(model.cue.blurb)
                if audio.missingClips {
                    warn("no .wav files in the bundle — the sampled option needs them in Sources/Sounds/. They are gitignored, so a fresh clone has none. Every other cue is generated in code and always works.", .orange)
                }
                caption("fires when the pick LANDS somewhere new, and never on the way back out — leaving an icon is not arriving anywhere. Each cue has five variants and never repeats one twice running, because a repeat is the one thing an ear notices.")
            }
        }
        Group {
            Toggle("open on highlight", isOn: bindBool(\.submenuOnHighlight))
            caption(config.style.submenuOnHighlight
                    ? "children appear the moment you land on their category, and `submenu at` is only where you start choosing one. Off, you travel out to reveal them first — a second reach for a decision you already made."
                    : "TWO-STAGE — travel past `submenu at` to reveal the children, then further to pick one. Worth it on a dense ring, where sweeping past several parents blooms several fans.")
        }

        Divider().padding(.vertical, 4)
        presetRow

        Button("reset \(layout.rawValue)") { config = MenuModel.factory(for: layout) }
            .padding(.top, 2)

        #if os(visionOS)
        Group {
            Divider().padding(.vertical, 4)
            spatialControls
        }
        #endif

        Group {
            Divider().padding(.vertical, 4)
            exportBlock
            buildStamp
        }
    }

    /// A GRID, not a segmented control.
    ///
    /// Nine cues in a segmented control gives each one 35 pt on a phone and an
    /// unreadable sliver in a headset — and this is a control you operate by
    /// tapping every option in turn, so the target size IS the feature. Wrapping
    /// buttons stay legible at any panel width and grow to a real gaze target.
    private var cuePicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
            ForEach(MenuCue.allCases) { c in
                Button { model.cue = c } label: {
                    Text(c.label)
                        .font(.caption)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: MenuPlatform.controlMinHeight * 0.72)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(model.cue == c ? Color.accentColor.opacity(0.8)
                                                     : Color.white.opacity(0.10))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    /// WHICH BUILD AM I LOOKING AT, and on what.
    ///
    /// With four devices in the room this stops being a nicety. Deploy, pick a
    /// device up, and there is otherwise no way to tell whether you are seeing
    /// the change you just made or the one from an hour ago — so a fix that did
    /// not install looks exactly like a fix that did not work, which is the
    /// worst pair of things to be unable to tell apart.
    ///
    /// It also makes screenshots self-describing: a photo of a headset and a
    /// photo of a phone now say which build each was, which is the whole
    /// difference between comparing two devices and guessing about them.
    private var buildStamp: some View {
        Text("\(BuildStamp.text) · \(BuildStamp.platformName)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .textSelection(.enabled)
    }

    #if os(visionOS)
    /// Take it out of the pane and put it in the room.
    ///
    /// The distances are knobs rather than constants because nobody can pick
    /// "the right arm's length" for a headset from a text editor — which is the
    /// premise of this entire app, applied to itself.
    @ViewBuilder
    private var spatialControls: some View {
        Label("in the room", systemImage: "visionpro")
            .font(.headline)
        Toggle("spatial view", isOn: $model.spatialOn)
        caption(model.spatialOn
                ? "the pane has stopped drawing a menu — one solve at a time, so two of them cannot fight over the metrics readout. Look around you."
                : "opens an immersive space and draws the SAME menu there, with no window behind it. The component does not change at all: it takes a pointer offset and has no opinion about what is holding it.")
        if model.spatialOn {
            knob("distance", $model.spatialDistance, 0.3...2.5, " m",
                 decimals: 2, resetTo: 0.7)
            knob("height", $model.spatialHeight, -0.5...2.2, " m",
                 decimals: 2, resetTo: 1.2)
            knob("scale", $model.spatialScale, 0.2...3, "×",
                 decimals: 2, resetTo: 1)
            caption("metres, from where you were standing when the space opened. Height goes NEGATIVE on purpose — which way is up in there is a thing to confirm by dragging, not by assuming.")
            Toggle("show reach", isOn: $model.spatialShowReach)
            caption("dashes the edge of the area that catches your pinch, while live. Outside it your gaze goes straight through to the windows behind — worth being able to SEE rather than discover. It tracks the menu, so it grows and shrinks as you tune.")
        }
    }
    #endif

    /// The pointer WAS invisible by design — it is the component's whole input
    /// contract, not a thing on screen. That was also exactly the usability
    /// complaint from a reviewer: between icons nothing changes, so the hand is
    /// steering blind. These turn it into something you can see.
    ///
    /// Which makes them FEEDBACK, not instrumentation, and they are on in the
    /// shipped defaults. An earlier version of the "guides" switch swept them off
    /// along with the tuning overlays — the same error as counting the origin
    /// ring as a guide, and wrong for the same reason. Anyone who does not want a
    /// visible cursor turns off the one toggle; nothing else decides for them.
    @ViewBuilder
    private var pointerControls: some View {
        Toggle("show pointer", isOn: bindBool(\.showPointer))
        if config.style.showPointer {
            Toggle("pointer spoke", isOn: bindBool(\.showPointerTrail))
            Toggle("rubber band", isOn: bindBool(\.showPointerLeader))
            ratio("pointer size", bind(\.pointerScale), 0.05...0.5,
                  resolved: pt(metrics.iconSize * config.style.pointerScale))
            knob("pointer fade", bindStyleDouble(\.pointerOpacity), 0.1...1, "")
            ratio("pointer reach", bind(\.pointerReachRatio), 0...1,
                  resolved: pt(layout == .radial ? metrics.pointerReach.width
                                                 : metrics.pointerReach.height))
            caption(config.style.pointerReachRatio > 0.99
                    ? "the dot may run all the way out to where the sub-menus land. Overshoot keeps MOVING, which keeps telling you something."
                    : config.style.pointerReachRatio < 0.01
                    ? "pinned to the icons. Past them the dot stops dead and further hand travel is silent — cleaner, and it gives up the one cue that says you have gone too far."
                    : "between the icons and the menu's full extent. Display only: the PICK always reads your raw hand.")
            caption("a hard radial stop on any category with no sub-menu — push all you like, the dot will not pass it. Land on one that HAS children and the bound opens to let you reach them.")
            if previewOn {
                warn("LIVE only. A preview pose puts the pointer exactly ON a seat — there is no overshoot for this to bound, so the dot will not move however you drag it. The resolved figure above does change; switch to live to feel it.", .orange)
            }
        }
        Toggle("show center", isOn: bindBool(\.showOrigin))
        if config.style.showOrigin {
            ratio("center size", bind(\.originScale), 0.05...6,
                  resolved: pt(metrics.iconSize * config.style.originScale))
            ratio("center weight", bind(\.originLineWidth), 0.002...0.2,
                  resolved: pt(metrics.iconSize * config.style.originLineWidth))
        }
    }

    // MARK: export

    @ViewBuilder
    private var exportBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Sized up deliberately. This is the section that turns a tuning
            // session into something you can hand someone, and it was the
            // quietest thing on the panel — a caption-sized label above a
            // borderless word.
            HStack {
                Label("export", systemImage: "square.and.arrow.up")
                    .font(.headline)
                Spacer()
                Button(showExport ? "hide" : "show") { showExport.toggle() }
                    .font(.callout.weight(.semibold))
                    .buttonStyle(.bordered)
            }
            .padding(.bottom, 2)
            if showExport {
                swiftExportRows
                Divider().padding(.vertical, 2)
                projectRows
            }
        }
        // Attached here rather than to the whole panel so the sheet cannot be
        // summoned by anything else on screen.
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { importProject($0) }
        .id(Self.exportAnchor)
    }

    /// Constant, so `.id` never changes this block's identity — it is only ever
    /// a scroll target.
    private static let exportAnchor = "exportBlock"

    /// Out to a developer's project: Swift they can paste and build.
    @ViewBuilder
    private var swiftExportRows: some View {
        TextField("file name", text: $exportName)
            .textFieldStyle(.roundedBorder)
        Picker("kind", selection: $exportStandalone) {
            Text("standalone").tag(true)
            Text("config only").tag(false)
        }
        .pickerStyle(.segmented)
        caption(exportStandalone
                ? "one file: the component + this tuning. Nothing else needed."
                : "just the tuning — pair it with RadialMenu.swift.")
        Button("export Swift · \(layout.rawValue)") { runExport() }
            .buttonStyle(.borderedProminent)
        if let url = exportURL {
            ShareLink(item: url) {
                Label("share \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// In and out as JSON — the round trip a colleague actually uses.
    ///
    /// Import is the piece that turns this from a personal tuner into a tool you
    /// can hand someone: without it the only way in is `devicectl`, which needs
    /// Xcode and a paired device, which means it is not really a handoff at all.
    @ViewBuilder
    private var projectRows: some View {
        Text("menu content").font(.subheadline.weight(.semibold))
        HStack(spacing: 6) {
            Button("import…") { showImporter = true }
                .buttonStyle(.borderedProminent)
            Button("export JSON") { exportProject() }
                .buttonStyle(.bordered)
            Spacer()
        }
        caption("\(allItems.count) items. Import a .json of your own menu — icons, labels, order, children — tune it against your real content, then export it back with the tuning inside.")
        if !symbolReport.isEmpty {
            warn(symbolReport, .orange)
        }
        if let url = projectURL {
            ShareLink(item: url) {
                Label("share \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func runExport() {
        let name = exportName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = name.isEmpty ? "RadialMenuKit" : name
        // Resolve without a container so the exported numbers are the DESIGN
        // values, not whatever this window happened to squeeze them down to.
        let m = style.resolved(itemCount: visibleItems.count,
                               maxChildren: visibleItems.map(\.children.count).max() ?? 0,
                               available: nil)
        let text = exportStandalone
            ? RadialMenuExport.standalone(style: style, items: visibleItems, metrics: m, name: safe)
            : RadialMenuExport.configOnly(style: style, items: visibleItems, metrics: m, name: safe)

        RadialMenuExport.copyToPasteboard(text)
        if let url = RadialMenuExport.write(text, filename: "\(safe).swift") {
            exportURL = url
            note("exported \(safe).swift · \(text.count) chars")
        } else {
            note("export failed to write")
        }
    }

    // MARK: the round trip

    /// Tolerant by design: a full project, a bare items file, or a naked array
    /// all load. Someone writing their first menu should not have to get a
    /// wrapper object right before anything appears on screen.
    private func importProject(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            note("import cancelled"); return
        }
        // Files handed over by the system picker are security-scoped, and
        // reading one without claiming it fails silently.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            note("could not read \(url.lastPathComponent)"); return
        }
        let dec = JSONDecoder()

        if let proj = try? dec.decode(MenuProject.self, from: data), proj.items.count >= 2 {
            apply(proj)
            note("imported \(proj.items.count) items\(proj.tuning.isEmpty ? "" : " + tuning")")
        } else if let bare = try? dec.decode([RadialMenuItem].self, from: data), bare.count >= 2 {
            apply(MenuProject(items: bare))
            note("imported \(bare.count) items")
        } else {
            note("no menu found in \(url.lastPathComponent)")
        }
    }

    private func apply(_ project: MenuProject) {
        if project.items.count >= 2 { allItems = project.items }
        for (key, preset) in project.tuning {
            var p = preset
            // Their item count may be smaller than whatever `icons` was saved at.
            p.icons = max(2, min(p.icons, allItems.count, MenuModel.maxIcons))
            configs[key] = p
        }
        for key in configs.keys {
            configs[key]?.icons = max(2, min(configs[key]?.icons ?? 8, allItems.count, MenuModel.maxIcons))
        }
        symbolReport = validateSymbols()
        writeItems()
        persistSoon()
    }

    private func exportProject() {
        let name = exportName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = (name.isEmpty ? "RadialMenu" : name) + ".json"
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(MenuProject(items: allItems, tuning: configs)) else {
            note("could not encode the project"); return
        }
        let url = RadialMenuExport.documentsDirectory.appendingPathComponent(safe)
        guard (try? data.write(to: url)) != nil else { note("could not write \(safe)"); return }
        projectURL = url
        note("wrote \(safe) · \(allItems.count) items + all three layouts")
    }

    /// A missing SF Symbol draws as nothing at all, which reads as a layout bug
    /// rather than a typo. Naming them turns twenty minutes into ten seconds.
    private func validateSymbols() -> String {
        var missing: [String] = []
        func walk(_ items: [RadialMenuItem]) {
            for item in items {
                if case .system(let n) = item.icon, !MenuPlatform.symbolExists(n) {
                    missing.append(n)
                }
                walk(item.children)
            }
        }
        walk(allItems)
        guard !missing.isEmpty else { return "" }
        let uniq = Array(Set(missing)).sorted()
        let shown = uniq.prefix(5).joined(separator: ", ")
        return "\(uniq.count) symbol\(uniq.count == 1 ? "" : "s") not found — these draw blank: "
            + shown + (uniq.count > 5 ? " …" : "")
    }

    /// The question this answers gets asked by everyone exactly once: why does
    /// raising `icon size` grow the whole dial instead of growing the icons in
    /// place? Because that is what "base unit" means, and the alternative is the
    /// bug responsive mode was built to remove.
    private var iconSizeBlurb: String {
        guard config.style.responsive else {
            return "ABSOLUTE — the icons grow on their own centers and the ring stays where it is, so eventually they touch. That collision is exactly what responsive mode exists to make impossible."
        }
        switch layout {
        case .radial:
            return "the BASE UNIT: the ring is solved FROM this, so bigger icons mean a bigger ring and the whole dial scales. To grow icons in PLACE, lower `gutter` instead — they eat the gap and the ring holds."
        case .vertical, .horizontal:
            return "the BASE UNIT: the pitch is solved FROM this, so bigger icons spread the column. To grow icons in PLACE, lower `gutter` instead — they eat the gap and the pitch holds."
        }
    }

    private var submenuBlurb: String {
        let flipped = config.style.childrenFlipped
        // What this distance MEANS changed with `open on highlight`: it is the
        // commit boundary now, not the reveal.
        let what = config.style.submenuOnHighlight
            ? "before you are choosing a child rather than the category"
            : "before children appear"
        switch layout {
        case .radial: return "how far OUT past the ring \(what)"
        case .vertical:
            return "how far \(flipped ? "LEFT" : "RIGHT") of the column \(what)"
        case .horizontal:
            return "how far \(flipped ? "DOWN from" : "UP from") the row \(what)"
        }
    }

    /// Which side of the row/column the sub-menu comes out on. Radial has no
    /// choice to make — there is exactly one "outward" — so it never appears.
    @ViewBuilder
    private var childSidePicker: some View {
        HStack(spacing: 8) {
            Text("submenu").frame(width: 84, alignment: .leading)
            Picker("", selection: bindBool(\.childrenFlipped)) {
                Text(layout == .vertical ? "right" : "above").tag(false)
                Text(layout == .vertical ? "left" : "below").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Three slots PER LAYOUT — save a variant, load it back, and it all lands in
    /// the JSON so the numbers can be read on the Mac.
    @ViewBuilder
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("presets · \(layout.rawValue)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("save").frame(width: 38, alignment: .leading)
                ForEach(1...3, id: \.self) { i in
                    Button("\(i)") { savePreset(i) }.buttonStyle(.bordered)
                }
            }
            HStack(spacing: 6) {
                Text("load").frame(width: 38, alignment: .leading)
                ForEach(1...3, id: \.self) { i in
                    Button("\(i)") { loadPreset(i) }
                        .buttonStyle(.bordered)
                        .disabled(slots[slotKey(i)] == nil)
                }
            }
            // Save was one-way until now: a slot you filled by accident stayed
            // filled, and the only way out was to overwrite it with something
            // you did not want either.
            HStack(spacing: 6) {
                Text("clear").frame(width: 38, alignment: .leading)
                ForEach(1...3, id: \.self) { i in
                    Button("\(i)") { clearPreset(i) }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(slots[slotKey(i)] == nil)
                }
            }
        }
    }

    // MARK: row builders

    /// No `@ViewBuilder` here, deliberately. The body is a `let` and then ONE
    /// expression, so the builder has nothing to build — and an explicit
    /// `return` switches it off anyway, which is what the warning was saying:
    /// the attribute was decoration claiming to do work. Plain Swift is the
    /// honest spelling. The `ratio` twin below has no `let`, so it keeps its
    /// builder and needs no return.
    private func knob(_ name: String, _ k: Knob,
                      _ range: ClosedRange<Double>, _ unit: String,
                      decimals: Int? = nil) -> some View {
        let places = decimals ?? (unit.isEmpty ? 0 : 2)
        return HStack(spacing: 8) {
            Text(name).frame(width: 84, alignment: .leading)
            Slider(value: k.value, in: range)
            ValueField(text: String(format: "%.\(places)f\(unit)", k.value.wrappedValue),
                       subtitle: nil, knob: k, range: range, width: 58)
        }
    }

    /// The few knobs that drive `MenuModel` directly rather than a style key
    /// path — the spatial placement — where there is no `factory(for:)` to ask
    /// and the shipped value is a literal. Pass it as `resetTo:`, or leave it
    /// off and the row simply has no reset arrow.
    @ViewBuilder
    private func knob(_ name: String, _ value: Binding<Double>,
                      _ range: ClosedRange<Double>, _ unit: String,
                      decimals: Int? = nil, resetTo: Double? = nil) -> some View {
        knob(name, Knob(value: value, fallback: resetTo), range, unit, decimals: decimals)
    }

    /// A ratio slider that also prints what it currently RESOLVES to, so the
    /// abstract multiplier and the concrete distance are never separated.
    @ViewBuilder
    private func ratio(_ name: String, _ k: Knob,
                       _ range: ClosedRange<Double>, resolved: String) -> some View {
        HStack(spacing: 8) {
            Text(name).frame(width: 84, alignment: .leading)
            Slider(value: k.value, in: range)
            ValueField(text: String(format: "%.3f×", k.value.wrappedValue),
                       subtitle: resolved, knob: k, range: range, width: 78)
        }
    }

    @ViewBuilder
    private func caption(_ s: String) -> some View {
        Text(s)
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 2).padding(.bottom, 2)
    }

    /// The knob that was there the whole time, doing nothing, with nothing said
    /// about it. Steve went looking for a bug in the pointer for two rounds
    /// because a slider called "dead zone" sitting at 0 does not announce that
    /// it is the reason a single pixel of movement picks an icon.
    private var deadZoneBlurb: String {
        layout == .radial
        ? "NOTHING highlights until your hand has travelled this far — measured as a fraction of the trip out to the icons. At 0 the first pixel of movement picks whatever happens to lie along that heading, which is a compass that has already made up its mind. Raise it and an icon only takes hold once you are most of the way to it."
        : "nothing highlights until your hand has travelled this far from where the menu opened, × icon size. At 0 the first pixel of movement picks."
    }

    private func pt(_ v: CGFloat) -> String { String(format: "%.0f pt", v) }
    private func deg(_ v: Double) -> String { String(format: "%.1f°", v) }

    // MARK: bindings into the CURRENT layout's config

    // Each of these hands back a `Knob` rather than a bare `Binding<Double>`,
    // and the reason is the reset arrow. A binding is two closures with no
    // memory of where it came from, so the row builder receiving one cannot
    // possibly know what the knob shipped as. Here we still have the KEY PATH,
    // which is exactly what `factory(for:)` needs — so the factory value gets
    // attached at the only point in the program that can supply it.
    //
    // Nothing at the call sites changed: `knob("icon size", bind(\.iconSize), …)`
    // reads the same, because `knob` now takes a `Knob`.
    private func bind(_ kp: WritableKeyPath<RadialMenuStyle, CGFloat>) -> Knob {
        Knob(value: Binding(get: { Double(config.style[keyPath: kp]) },
                            set: { var c = config; c.style[keyPath: kp] = CGFloat($0); config = c }),
             fallback: Double(MenuModel.factory(for: layout).style[keyPath: kp]))
    }
    private func bindStyleDouble(_ kp: WritableKeyPath<RadialMenuStyle, Double>) -> Knob {
        Knob(value: Binding(get: { config.style[keyPath: kp] },
                            set: { var c = config; c.style[keyPath: kp] = $0; config = c }),
             fallback: MenuModel.factory(for: layout).style[keyPath: kp])
    }
    private func bindBool(_ kp: WritableKeyPath<RadialMenuStyle, Bool>) -> Binding<Bool> {
        Binding(get: { config.style[keyPath: kp] },
                set: { var c = config; c.style[keyPath: kp] = $0; config = c })
    }
    private func bindDouble(_ kp: WritableKeyPath<MenuPreset, Double>) -> Knob {
        Knob(value: Binding(get: { config[keyPath: kp] },
                            set: { var c = config; c[keyPath: kp] = $0; config = c }),
             fallback: MenuModel.factory(for: layout)[keyPath: kp])
    }
    private func bindIcons() -> Knob {
        Knob(value: Binding(get: { Double(config.icons) },
                set: { v in
                    let want = min(max(Int(v.rounded()), 2), MenuModel.maxIcons)
                    // Dragging UP past the end of the list MAKES categories.
                    //
                    // The slider used to stop at whatever you happened to have,
                    // which meant the ceiling of twelve was invisible with eight
                    // items and "dial in 12 icons" simply did not work. This is a
                    // CONSTRUCT tool: asking for twelve should produce twelve
                    // seats to fill, not refuse on the grounds that you have not
                    // filled them yet.
                    //
                    // Dragging back down never deletes — the extras stay in the
                    // tray — so the gesture is reversible, which is what makes it
                    // safe to be this eager.
                    if want > allItems.count { fillTo(want) }
                    var c = config
                    c.icons = want
                    config = c
                }),
             fallback: Double(MenuModel.factory(for: layout).icons))
    }

    /// Grow the list to `n` with placeholder categories, ready to be named.
    private func fillTo(_ n: Int) {
        guard n > allItems.count else { return }
        var out = allItems
        var bump = out.count
        while out.count < n {
            bump += 1
            var id = "item.\(bump)"
            while out.contains(where: { $0.id == id }) { bump += 1; id = "item.\(bump)" }
            out.append(.init(id: id, systemImage: "circle", label: "New \(bump)"))
        }
        allItems = out
        symbolReport = validateSymbols()
        saveItemsSoon()
    }
    /// The widest an OPEN arc can usefully be, given the icon count.
    ///
    /// An open arc of `S` degrees with `n` seats has a step of `S/(n−1)` between
    /// neighbours and a WRAP of `360 − S` between its last seat and its first.
    /// Those are equal when
    ///
    ///     S = 360·(n−1)/n
    ///
    /// and at that sweep the spacing is uniform the whole way round — which is
    /// a full ring, drawn as an open arc. 330° at twelve icons, 270° at four.
    ///
    /// Past it you are asking for the wrap to be TIGHTER than the neighbours:
    /// more crowded than a full ring, in exchange for nothing. There is no
    /// layout up there, which is why it snaps.
    private var maxOpenSweep: Double {
        let n = Double(max(metrics.seats, 2))
        return 360 * (n - 1) / n
    }

    /// Snaps the top of the range to a true full turn, at the exact boundary
    /// above.
    ///
    /// Two earlier versions of this line were guesses: a fixed `>= 355`, and
    /// then "once the wrap falls below half a step" (344° at twelve icons).
    /// Both let you into the degenerate band, because both were reasoning about
    /// when it gets BAD rather than when it stops meaning anything new.
    private func bindArcSweep() -> Knob {
        Knob(value: Binding(get: { config.style.arcSweepDegrees },
                            set: { v in
                                var c = config
                                c.style.arcSweepDegrees = v >= maxOpenSweep ? 360 : v
                                config = c
                            }),
             fallback: MenuModel.factory(for: layout).style.arcSweepDegrees)
    }

    /// Quadrants in clock terms — 0° is 12 o'clock, sweeping clockwise. -1 = the
    /// full ring. Writes straight into arcStart/arcSweep, which stay hand-tunable.
    private var quadrantBinding: Binding<Int> {
        Binding(
            get: {
                let s = config.style
                guard s.arcSweepDegrees < 359.9 else { return -1 }
                let q = Int((s.arcStartDegrees / 90).rounded()) % 4
                return abs(s.arcSweepDegrees - 90) < 0.1 ? (q + 4) % 4 : -1
            },
            set: { q in
                var c = config
                if q < 0 {
                    c.style.arcStartDegrees = 0; c.style.arcSweepDegrees = 360
                } else {
                    c.style.arcStartDegrees = Double(q) * 90
                    c.style.arcSweepDegrees = 90
                }
                config = c
            })
    }

    // MARK: presets + persistence

    private func slotKey(_ i: Int) -> String { "\(layout.rawValue).\(i)" }

    private func savePreset(_ i: Int) {
        slots[slotKey(i)] = config
        note("saved \(layout.rawValue) preset \(i)")
        persistSoon()
    }

    private func clearPreset(_ i: Int) {
        guard slots[slotKey(i)] != nil else { return }
        slots[slotKey(i)] = nil
        note("cleared \(layout.rawValue) preset \(i)")
        persistSoon()
    }

    private func loadPreset(_ i: Int) {
        guard var p = slots[slotKey(i)] else { return }
        p.style.layout = layout
        config = p
        note("loaded \(layout.rawValue) preset \(i)")
    }

    private func note(_ s: String) {
        savedNote = s
        Task { try? await Task.sleep(for: .seconds(2)); savedNote = "" }
    }

    // MARK: menu content

    private static var itemsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("radialmenu-items.json")
    }

    /// Read the items file if it exists; write the defaults out if it does not.
    ///
    /// Writing on first launch matters more than it looks: without it the file
    /// only appears after you have already gone looking for it, and "edit the
    /// JSON" turns into "guess the schema".
    private func loadItems() {
        if let data = try? Data(contentsOf: Self.itemsURL),
           let file = try? JSONDecoder().decode(ItemsFile.self, from: data),
           file.items.count >= 2 {
            allItems = file.items
            symbolReport = validateSymbols()
            itemsNote = "\(file.items.count) items from radialmenu-items.json"
        } else {
            writeItems()
            itemsNote = "wrote the default items to radialmenu-items.json"
        }
    }

    @discardableResult
    private func writeItems() -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(ItemsFile(items: allItems)) else { return false }
        return (try? data.write(to: Self.itemsURL)) != nil
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("radialmenu-presets.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let file = try? JSONDecoder().decode(PresetFile.self, from: data) else { return }
        // The back-solve happens HERE, not in the decoder, because it needs the
        // item count — and the count lives on the preset, not on the style. Each
        // entry is migrated against its OWN `icons`, so a file with four radial
        // items and one with eight both come back at the ring they were tuned to.
        slots = file.slots.mapValues(migrated)
        for (k, v) in file.current { configs[k] = migrated(v) }
        if file.version < 7 {
            note("upgraded round-\(file.version) presets — ratios back-solved")
        }
    }

    private func migrated(_ p: MenuPreset) -> MenuPreset {
        var out = p
        out.style.backSolveRatios(itemCount: max(2, min(p.icons, allItems.count, MenuModel.maxIcons)))
        return out
    }

    /// Debounced so a slider drag doesn't write on every frame.
    private func persistSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let file = PresetFile(current: configs, slots: slots)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(file) { try? data.write(to: Self.fileURL) }
        }
    }
}

// MARK: - a knob's value, and the two ways to set it that are not dragging

/// A `Binding<Double>` that also remembers what it SHIPPED as.
///
/// The reset arrow needs somewhere to go back to, and the row builders had no
/// way to know it. A binding is a pair of closures with no memory of where it
/// came from — `knob("icon size", bind(\.iconSize), …)` hands over the ability
/// to read and write a number and nothing else. The key path, which is what
/// `MenuModel.factory(for:)` needs, only exists one level up inside `bind`. So
/// that is where the factory value gets attached, and this is the thing that
/// carries it down.
///
/// `fallback` is optional because not every knob HAS a shipped value that means
/// anything. `on item` chooses which seat the preview highlights; there is no
/// factory seat, and pretending otherwise would put a live arrow on a row where
/// pressing it means nothing.
struct Knob {
    let value: Binding<Double>
    var fallback: Double? = nil
}

/// The number at the right-hand end of a knob row — which is also an input.
///
/// A slider is a coarse instrument, and this panel's whole premise is that you
/// tune by feel and then keep the number. Feel gets you to 0.449; the value you
/// actually want is often the one that came off a headset, or a round figure, or
/// something a colleague read out to you. None of those are reachable by
/// dragging a 340 pt track, and up to now the only way in was to export, edit
/// JSON and import it back.
///
/// So: tap the number, type it, press return. And an arrow back to whatever it
/// shipped as, because the fastest way to be brave with a knob is to know the
/// way back is one tap and not a memory test.
private struct ValueField: View {
    let text: String
    let subtitle: String?
    let knob: Knob
    let range: ClosedRange<Double>
    let width: CGFloat

    /// `nil` means "not editing". One piece of state rather than a Bool and a
    /// String that can disagree with each other.
    @State private var draft: String?

    var body: some View {
        HStack(spacing: 4) {
            readout
            resetButton
        }
        // Editing happens in a popover beside the number rather than in the row
        // itself, so the row never changes shape and the sliders never shuffle
        // under you mid-tune.
        .popover(isPresented: Binding(get: { draft != nil },
                                      set: { if !$0 { commit() } })) {
            NumberPad(draft: Binding(get: { draft ?? "" }, set: { draft = $0 }),
                      allowsNegative: range.lowerBound < 0,
                      onCommit: commit)
                // Without this an iPhone turns a popover into a sheet, which is
                // a whole modal page for typing one number.
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: reading it

    /// A BUTTON, not a `Text` with a tap gesture on it — and the difference is
    /// the whole fix for "still hard to pick the number".
    ///
    /// Two things were wrong and they compounded. The target was a line of type
    /// about 17 pt tall, which a mouse hits every time and a gaze does not. And
    /// nothing about it looked pressable, so there was no way to tell whether
    /// you had missed or whether it simply did not do anything — the failure and
    /// the no-op were indistinguishable, which is the worst way for a control to
    /// fail.
    ///
    /// A real button gets the system's own hover treatment: in a headset it
    /// lights up when your eyes land on it, which turns aiming into looking.
    /// Boxed and padded so it reads as a field before you touch it, and floored
    /// at `controlMinHeight` so there is something to land on.
    private var readout: some View {
        Button(action: beginEditing) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(text)
                    .monospacedDigit()
                    // The figures are not all the same length — "75.67pt" is
                    // wider than "0.45×" — and a fixed column that fits the
                    // short ones silently truncates the long ones. Shrinking
                    // beats clipping: a slightly small number is still a number.
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: width, alignment: .trailing)
            // Headroom, not a box. The tall frame is INVISIBLE — it exists so
            // there is something to land on, and it draws nothing. A drawn box
            // costs the two-line ratio readouts the width they need and puts
            // permanent chrome on forty-odd rows to solve a problem that only
            // exists in the half-second you are aiming at one of them.
            .frame(minHeight: MenuPlatform.controlMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if !os(macOS)
        // THIS is what makes it pickable, and it costs nothing when you are not
        // looking: the system lights the target as your eyes arrive and takes
        // the highlight away again when they leave. Feedback exactly when it is
        // useful, and no ink the rest of the time.
        .hoverEffect(.highlight)
        #endif
    }

    // MARK: typing it

    private func beginEditing() {
        // The NUMBER only. Handing back "75.67pt" would mean deleting the unit
        // the field itself just printed before you could type anything.
        //
        // Setting it non-nil is what opens the pad — see `body`.
        draft = ValueField.digits(text)
    }

    private func commit() {
        defer { draft = nil }
        guard let d = draft, let v = Double(ValueField.digits(d)) else { return }
        // Clamped, not rejected. Typing 500 into a 0…400 knob means "as far as
        // it goes", and going there beats doing nothing and explaining nothing.
        knob.value.wrappedValue = min(max(v, range.lowerBound), range.upperBound)
    }

    /// Whatever a person typed, reduced to something `Double` will take: a unit
    /// left on the end, a comma for a decimal point, a stray space.
    private static func digits(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." || $0 == "-" }
    }

    // MARK: putting it back

    private var resetButton: some View {
        let target = knob.fallback
        let home = target.map { abs(knob.value.wrappedValue - $0) < 0.0005 } ?? true
        return Button {
            guard let t = target else { return }
            draft = nil
            knob.value.wrappedValue = t
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .frame(minWidth: MenuPlatform.controlMinWidth,
                       minHeight: MenuPlatform.controlMinHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(home)
        // Dimmed rather than hidden. A control that vanishes when it has nothing
        // to do takes the row's layout with it, and every knob you touch would
        // shuffle by 20 pt at the moment you touched it.
        .opacity(home ? 0.22 : 1)
    }
}

/// A number pad with a RETURN key, because UIKit does not have one.
///
/// This is not a preference. `.numberPad` and `.decimalPad` have no return key
/// on any Apple platform — not a hidden one, and not one `.submitLabel` can
/// summon, because that modifier renames an existing key rather than creating a
/// slot for a new one. The documented workaround is an accessory toolbar above
/// the keyboard, which is an iPhone idiom; and `.numbersAndPunctuation`, which
/// does have a return, is the numeric PAGE of a full QWERTY — a whole alphabet
/// on screen so you can type "0.45".
///
/// In a headset it is worse than an inconvenience. The system keyboard arrives
/// as a slab somewhere in the room, at a distance it picks, while the number you
/// are editing is on a panel at arm's length in front of you. You end up looking
/// away from the thing you are tuning in order to tune it.
///
/// Fourteen keys, drawn next to the value, identical on every platform. Less
/// code than either workaround, and no keyboard ever appears.
private struct NumberPad: View {
    @Binding var draft: String
    let allowsNegative: Bool
    let onCommit: () -> Void

    #if os(macOS)
    /// A Mac has a real keyboard with a real Return on it. The pad is still
    /// there to click, but nobody should have to.
    @FocusState private var typing: Bool
    #endif

    private var keyHeight: CGFloat { max(MenuPlatform.controlMinHeight, 34) }

    var body: some View {
        VStack(spacing: 10) {
            display
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.08))
                )

            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    key("7"); key("8"); key("9")
                    key(symbol: "delete.left", action: backspace)
                }
                GridRow {
                    key("4"); key("5"); key("6")
                    key("C", action: { draft = "" })
                }
                GridRow {
                    key("1"); key("2"); key("3")
                    key("−", action: negate).disabled(!allowsNegative)
                }
                GridRow {
                    key("0").gridCellColumns(2)
                    key(".")
                    key(symbol: "return", prominent: true, action: onCommit)
                }
            }
        }
        .padding(14)
        .frame(width: 250)
    }

    @ViewBuilder
    private var display: some View {
        #if os(macOS)
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(.title3, design: .monospaced))
            .focused($typing)
            .onSubmit(onCommit)
            .task { typing = true }
        #else
        // A Text, NOT a TextField. A focused text field is exactly what summons
        // the system keyboard, which is the thing this whole view exists to
        // avoid — one stray `.focused` here and the slab comes back.
        Text(draft.isEmpty ? "0" : draft)
            .font(.system(.title3, design: .monospaced))
        #endif
    }

    // MARK: keys

    /// One key. `title` for the digits, `symbol` for the two that are pictures.
    private func key(_ title: String? = nil, symbol: String? = nil,
                     prominent: Bool = false,
                     action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() } else if let title { append(title) }
        } label: {
            Group {
                if let symbol { Image(systemName: symbol) } else { Text(title ?? "") }
            }
            .font(.system(size: 19, design: .rounded))
            .frame(maxWidth: .infinity)
            .frame(height: keyHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(prominent ? Color.accentColor : nil)
    }

    private func append(_ s: String) {
        // One decimal point, and never a leading one that `Double` would choke
        // on — "." alone is not a number, ".5" is only sometimes.
        if s == "." {
            guard !draft.contains(".") else { return }
            if draft.isEmpty || draft == "-" { draft += "0" }
        }
        draft += s
    }

    private func backspace() { if !draft.isEmpty { draft.removeLast() } }

    /// A sign toggle rather than a minus key: on a pad there is no cursor, so
    /// "put a minus at the front" is the only thing the key could sensibly mean.
    private func negate() {
        if draft.hasPrefix("-") { draft.removeFirst() } else { draft = "-" + draft }
    }
}

/// When this binary was written, read off the binary itself.
///
/// Deliberately NOT a constant stamped in by a build script. A generated file
/// is one more thing that can be stale — forget the build phase on a new target
/// and it reports the wrong date confidently, which is worse than reporting
/// nothing. The executable's modification time is written by the linker and
/// cannot disagree with the executable it describes.
///
/// On a device this can read as the INSTALL time rather than the link time,
/// since the bundle is copied and re-signed on the way over. That is fine, and
/// arguably the more useful of the two: the question being asked is "is this
/// device running what I just sent it", and install time answers exactly that.
enum BuildStamp {
    static let text: String = {
        guard let url = Bundle.main.executableURL,
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate
        else { return "build unknown" }
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return "built \(f.string(from: date))"
    }()

    /// So a screenshot says which machine it came from without being asked.
    static var platformName: String {
        switch MenuPlatform.current {
        case .vision: "Vision Pro"
        case .mac:    "macOS"
        case .pad:    "iPad"
        case .phone:  "iPhone"
        }
    }
}
