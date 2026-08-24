//
//  RadialMenu.swift — the component
//
//  THIS IS THE FILE YOU TAKE. Copy it into your target and you are done: no
//  package, no dependencies, no resources, no app types.
//
//  Self-contained on purpose, and it contains no gesture code at all. The HOST
//  owns input and feeds this view a pointer offset; this view owns layout,
//  highlighting, sub-menus, the label and the eased show/hide.
//
//  That split is the whole design. It is why the same view runs off a mouse on
//  macOS, a finger on iOS, a pinch on visionOS, and — with no change here — off
//  hand-tracked joint positions in an ImmersiveSpace. The source of the offset
//  changes; the menu does not.
//
//  Interaction contract:
//    • host sets `pointer` (points, relative to the menu's center) every frame
//      the gesture is held;
//    • this view publishes `highlight` — the deepest item the pointer is over;
//    • host reads `highlight` on release to confirm, then sets `isPresented`
//      false.
//
//  THREE LAYOUTS off one config. Each has its OWN grammar for where the label
//  sits and which way children grow — all three arrived at on device:
//
//      radial      ring          label at the CENTRE     children fan outward
//      vertical    column        label LEFT of the icon  children go RIGHT, in a row
//      horizontal  row           label BELOW the icon    children go UP, in a column
//
//  ─────────────────────────────────────────────────────────────────────────────
//  RESPONSIVE (round 7, 2026-08-22)
//
//  Every measurement used to be an independent absolute in points, which meant
//  dragging `icon size` from 62 to 100 grew the icons but left the ring at 105 —
//  they overlapped. Now there is ONE base unit, `iconSize`, and one packing
//  constraint; everything else is a RATIO of it, resolved fresh each frame by
//  `RadialMenuStyle.resolved(...)` into a `RadialMenuMetrics`.
//
//  The constraint that does the real work: neighbouring icons must sit at least
//  `iconSize × (1 + gutterRatio)` apart, center to center. In a row that IS the
//  pitch. On a ring it's a chord, so the radius falls out of it:
//
//        chord = 2·R·sin(step/2) ≥ pitch     →     R = pitch / (2·sin(step/2))
//
//  …and `step` is itself a function of how many icons are on screen and how wide
//  the arc is. So icon size, icon count and arc sweep ALL feed the radius, which
//  is the behaviour you want: change any one, and spacing follows.
//
//  Second half: `fitToContainer`. The host passes the space it has; if the ideal
//  menu doesn't fit, every metric is multiplied by one `fit` factor. Scaling the
//  METRICS rather than the view is deliberate — a `.scaleEffect` would put the
//  drawn geometry and the incoming pointer in different coordinate spaces, and
//  hit-testing would drift away from what you can see.
//
//  ⚠️ One place still does exactly that, knowingly: the `appearScale` spring on
//  show. For `easeFrames/60` seconds the menu is drawn at 0.86 → 1.0 while the
//  pointer is tested against full-size metrics, so during the appear the dashed
//  sub-menu guide sits ~12 pt inside its real trigger. It is the price of the
//  appear spring, it self-corrects, and at `hold = 0` your hand has barely
//  moved. If it ever reads as "sticky on the way in", that is this — fix it by
//  animating a present-scale THROUGH `resolved()` rather than over the view.
//
//  Set `responsive = false` to get the old absolute knobs back, unchanged.
//
//  WHY THERE IS NO SCROLLING
//  There was, for several rounds: a window of N seats over a longer list, with
//  the rest reached by pushing PAST an end. It worked, after a latch, a shelf
//  and a boost — and it was the wrong feature. A radial menu's entire value is
//  SPATIAL CONSTANCY: Delete is at 7 o'clock, it is always at 7 o'clock, and
//  your hand learns that in a week and keeps it for years. A list that slides
//  destroys exactly that, and replaces "flick to the thing" with fishing for
//  the thing to arrive somewhere you can reach it.
//
//  So the menu shows every item it has. Eight is the comfortable number, twelve
//  is the ceiling — a clock face, which is not a coincidence: twelve is about
//  as many directions as a hand can aim at without looking. Past that, the
//  answer is a sub-menu, not a longer ring. Depth is free; breadth is not.
//
//  Deleting it took ~460 lines with it, including every part of this file that
//  had ever been genuinely hard to reason about.
//
//  WHERE THE DEFAULTS COME FROM
//  Every stored default in `RadialMenuStyle` is a real tuning, arrived at on an
//  Apple Vision Pro with the menu open and a hand in it — not a round number
//  that looked sensible in a text editor. Drop this file into a project, write
//  `RadialMenu(items:pointer:isPresented:highlight:)` with no style at all, and
//  what you get is that tuning. The numbers are odd-looking (0.4492, 75.6715)
//  for the same reason a good curve has odd-looking control points.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  EMBED-VERSION: 7
//

import SwiftUI

// MARK: - Model

/// Where an item's glyph comes from.
///
/// Encodes as a PLAIN STRING so the items file stays hand-editable — `"trash"`
/// is an SF Symbol, `"asset:MyGlyph"` is a name in the host app's own catalog.
/// The synthesised enum encoding (`{"system":{"_0":"trash"}}`) is correct and
/// nobody would ever want to type it.
enum RadialMenuIcon: Equatable, Codable {
    /// An SF Symbol name. ~20k of them ship with the OS.
    case system(String)
    /// An image in the HOST APP's asset catalog. The component only names it;
    /// shipping the art is the host's business, which is what keeps this file
    /// droppable into someone else's project with no resources attached.
    case asset(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw.hasPrefix("asset:") ? .asset(String(raw.dropFirst(6))) : .system(raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .system(let n): try c.encode(n)
        case .asset(let n):  try c.encode("asset:" + n)
        }
    }
}

/// One action. `children` makes it a parent: its sub-items grow OUT of it.
struct RadialMenuItem: Identifiable, Equatable, Codable {
    let id: String
    var icon: RadialMenuIcon
    var label: String
    var children: [RadialMenuItem] = []

    init(id: String, icon: RadialMenuIcon, label: String, children: [RadialMenuItem] = []) {
        self.id = id
        self.icon = icon
        self.label = label
        self.children = children
    }

    /// Kept so every existing call site — and every exported file already in
    /// someone's hands — still compiles.
    init(id: String, systemImage: String, label: String, children: [RadialMenuItem] = []) {
        self.init(id: id, icon: .system(systemImage), label: label, children: children)
    }

    static func == (a: RadialMenuItem, b: RadialMenuItem) -> Bool { a.id == b.id }

    private enum CodingKeys: String, CodingKey { case id, icon, label, children }

    /// Lenient on purpose: this is read from a file a human edits by hand, and
    /// a missing `children` should mean "none", not a failed load that silently
    /// throws away the whole menu.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        icon = ((try? c.decodeIfPresent(RadialMenuIcon.self, forKey: .icon)) ?? nil)
            ?? .system("questionmark")
        children = ((try? c.decodeIfPresent([RadialMenuItem].self, forKey: .children)) ?? nil) ?? []
    }
}

/// Ring, column, or row. The interaction grammar is identical in all three.
enum RadialMenuLayout: String, CaseIterable, Identifiable, Codable {
    case radial, vertical, horizontal
    var id: String { rawValue }
}

// MARK: - Style

/// Everything about the FEEL, in one place. Every value here is a knob the
/// tuner app exposes as a live slider — the whole point is to set these by
/// hand, on a device, rather than guessing them.
///
/// Two families:
///   • RATIOS (`responsive == true`) — the portable ones. Multiples of
///     `iconSize`, so a colleague can drop this in at any icon size and the
///     proportions you dialled in survive.
///   • ABSOLUTES (`responsive == false`) — the original round-1..6 knobs, kept
///     so a hand-placed layout can still be pinned exactly.
///
/// The defaults are a real on-device tuning, not invented round numbers.
struct RadialMenuStyle: Codable, Equatable {

    // MARK: what it is
    var layout: RadialMenuLayout = .radial

    // MARK: the base unit
    /// Icon button diameter. In responsive mode EVERY other length derives from
    /// this, so it is the one knob that rescales the whole menu.
    var iconSize: CGFloat = 75.6715

    // MARK: responsive switches
    /// Derive spacing from `iconSize` + the packing constraint instead of using
    /// the absolute values below.
    var responsive: Bool = true
    /// Shrink the whole menu uniformly when it would not fit the space the host
    /// gives it. Independent of `responsive`.
    var fitToContainer: Bool = true

    // MARK: ratios (responsive mode)
    /// Clear space between neighbouring icon RIMS, as a fraction of icon
    /// diameter. Center-to-center pitch is `iconSize × (1 + gutterRatio)`.
    /// 0 = rims touching. The shipped radial default is 0.296; linear is 0.258.
    var gutterRatio: CGFloat = 0.4492
    /// Multiplier on the tightest-packing ring radius. 1 = as tight as the
    /// gutter allows; raise it to push the ring out without changing the gutter.
    var ringSlack: CGFloat = 0.8141
    /// Highlight pop-out distance, × icon diameter.
    var nudgeRatio: CGFloat = 0.5467
    /// How far the pop-out SPREADS to neighbouring icons, measured in seats.
    ///
    /// 0 keeps the original all-or-nothing behaviour: one icon is out, the rest
    /// are flat. Above 0 the nudge becomes a falloff — icons react in proportion
    /// to how near the pointer is, the way the Pinterest long-press menu and the
    /// macOS Dock both do.
    ///
    /// This is the cheapest answer to the "no in-between feedback" problem. A
    /// binary highlight can only say WHICH icon; two neighbours leaning by
    /// different amounts says WHERE BETWEEN THEM you are, continuously, using the
    /// icons themselves as the readout instead of adding a cursor on top.
    ///
    /// Seats, not points, because the unit has to survive every other knob: one
    /// seat is one seat whether the ring is 105 pt or 220 pt across.
    var nudgeSpread: CGFloat = 0
    /// The same pop-out for a highlighted CHILD, × child icon diameter.
    ///
    /// Its own knob rather than a reuse of `nudgeRatio`, because it is measured
    /// against `childIconSize` — a sub-menu icon is smaller, and a nudge that
    /// looks right on a 62 pt parent is a shove on a 51 pt child. Keeping the
    /// RATIO shared and the base different is what makes both read the same.
    ///
    /// Without it a sub-menu was the one place in the whole menu where the only
    /// confirmation you had picked something was the label text — the parent
    /// popped, the children never did.
    var childNudgeRatio: CGFloat = 0.5467
    /// Which side of the row/column the sub-menu comes out on.
    ///
    /// false = a column's children go RIGHT and a row's children go UP; true
    /// mirrors both. Ignored in radial, where "outward" has exactly one meaning.
    ///
    /// It is one flag rather than two because everything that has a side
    /// derives from the same vector: where the children land, which way the
    /// parent leans, which way its arrow points, which direction of travel
    /// opens the sub-menu, where the trigger guide is drawn, and which side the
    /// label takes so it stays clear of them. Two flags would be two things to
    /// keep in step.
    var childrenFlipped: Bool = false
    /// Parent ring/column/row → child group, × icon diameter.
    var childGapRatio: CGFloat = 1.8727
    /// Icon → label gap in the linear layouts, × icon diameter.
    var labelGapRatio: CGFloat = 0.258
    /// Travel below which nothing highlights, × icon diameter. 0 = react at once.
    var deadZoneRatio: CGFloat = 0

    /// RADIAL: how far out you must travel before anything highlights, as a
    /// fraction of the way to the icons. 0 falls back to `deadZoneRatio`.
    ///
    /// This exists because `deadZoneRatio` measures against the ICON and the
    /// question is about the RING. Shipping at 0 meant the guard fell through to
    /// its 0.75 pt epsilon, so the first pixel of travel picked whatever
    /// happened to lie along that heading — a menu with no neutral zone at all,
    /// which is not a marking menu, it is a compass that has already decided.
    ///
    /// And icon-relative was the wrong denominator for it anyway. The ring is
    /// SOLVED from icon size and count, so "0.8 × the icon" is a different
    /// fraction of the trip at four items than at twelve — the feel would drift
    /// every time the count changed, for a reason nothing on screen explains.
    /// What a hand actually knows is "am I most of the way there yet".
    var deadZoneOfRing: CGFloat = 0.6

    /// CONTROL–DISPLAY GAIN: virtual pointer distance ÷ real hand distance.
    ///
    /// 1.0 is 1:1 — a 220 pt ring costs 220 pt of hand. At 2.0 the same ring is
    /// 110 pt of hand, which on a headset is the difference between a shoulder
    /// movement and a wrist movement. The proper name for the trade is CD gain;
    /// a trackpad calls it tracking speed and a game calls it sensitivity.
    ///
    /// ⚠️ The COMPONENT DOES NOT READ THIS. Gain converts a physical input into
    /// the pointer offset, and the component's whole contract is that it is
    /// handed an offset and asks no questions about where it came from. Applying
    /// it here would mean the component knew about hands. The host multiplies by
    /// it before calling; this field exists so the number travels with the rest
    /// of the tuning, because a colleague shipping on visionOS needs it and
    /// cannot derive it.
    ///
    /// Raising it costs precision — tremor is amplified with everything else, so
    /// past about 2.5 the far items get twitchy. Non-linear gain (slow hand =
    /// fine, fast hand = far, the way macOS pointer acceleration works) is the
    /// real answer if a single number can't satisfy both ends.
    var pointerGain: CGFloat = 1.3508

    /// Show a parent's children the moment it is HIGHLIGHTED, rather than
    /// making you travel out to reveal them.
    ///
    /// `submenuThreshold` used to do two jobs at once: reveal the children, and
    /// switch the pick from the parent to one of them. Only the second earns the
    /// travel. Pointing at Material has already said "Material" — charging a
    /// second reach just to SEE what is in there bills you twice for one
    /// decision, and worse, it makes you commit that reach blind, before you
    /// know whether the thing you want is even in the fan.
    ///
    /// So the reveal is free and the COMMIT still costs: children appear on
    /// highlight, and `submenuThreshold` now means only "past here you are
    /// choosing a child rather than the parent". Which keeps a parent that is
    /// also an action selectable — the reason the two jobs could not simply be
    /// merged.
    ///
    /// Set false for the old two-stage behaviour. It is a real alternative on a
    /// dense ring, where sweeping past several parents blooms several fans.
    var submenuOnHighlight: Bool = true
    /// How far you slide before you are choosing a CHILD rather than the parent.
    /// (With `submenuOnHighlight` off, also how far before they appear at all.)
    /// radial: × RING RADIUS (1.45 — deliberately OUTSIDE the ring, see the
    /// commit floor in `resolved`). linear: × ICON DIAMETER (1.371).
    /// The base differs because "past the ring" and "sideways off a column" are
    /// different distances; each layout stores its own value anyway.
    var submenuReachRatio: CGFloat = 1.45
    /// Child icon diameter, × parent icon diameter.
    var childIconScale: CGFloat = 0.7113
    /// Label point size, × icon diameter.
    var labelFontScale: CGFloat = 0.2809
    /// Width of the label's justification runway, × icon diameter. Wide enough
    /// that long names never re-wrap; it is a layout box, not a visible edge.
    var labelRunwayScale: CGFloat = 8.39

    // MARK: absolutes (responsive == false)
    /// Distance from center to the icon ring (radial only).
    var ringRadius: CGFloat = 225.3376
    /// Row/column pitch (vertical + horizontal layouts).
    var linearSpacing: CGFloat = 78
    /// How far the highlighted icon pops OUTWARD.
    var nudge: CGFloat = 8.5
    /// Pointer travel below this = nothing highlighted.
    var deadZone: CGFloat = 0
    /// How far you slide past the icon before its children appear.
    var submenuThreshold: CGFloat = 85
    /// Gap between the parent ring/column/row and the child group.
    var childRingGap: CGFloat = 64
    /// Gap between the highlighted icon and its label (linear layouts).
    var labelGap: CGFloat = 16

    // MARK: shared (ratios already, in both modes)
    /// Total angular spread of a sub-menu's children, in degrees (radial only).
    var childSpread: Double = 30.394
    /// Child pitch, as a fraction of the top-level pitch.
    var childSpacingScale: CGFloat = 0.85
    /// Show/hide animation length, expressed in FRAMES at 60 Hz.
    var easeFrames: Double = 14
    /// Where the ring starts and how far it sweeps, in degrees. 0° = up,
    /// clockwise. A full 360 ring by default; narrow it for an arc. (radial only)
    var arcStartDegrees: Double = 0
    var arcSweepDegrees: Double = 360
    /// Scale the menu springs in from.
    var appearScale: CGFloat = 0.86
    /// The highlighted action's name. Placement follows the layout.
    var showLabel = true
    /// Draw the dashed "children appear past here" guide.
    var showSubmenuGuide = true
    /// A tiny triangle off the icon, pointing the way its children will appear.
    var showSubmenuArrow = true

    // MARK: pointer visibility (settings)
    //
    // Named differently from the view's own "visible pointer" section on
    // purpose: an identical heading in two scopes is how a whole block of view
    // code once got spliced into this struct.
    //
    // HCI note (a Step Into Vision developer, 2026-08-22): the component's whole
    // input contract is a pointer offset — and that pointer is INVISIBLE. The
    // user infers it only from which icon happens to be lit, so the feedback
    // channel has exactly as many states as there are icons. Move between them
    // and nothing on screen changes at all; you are steering something you
    // cannot see, with a lamp that lights only on arrival.
    //
    // Worse in radial, where selection is decided by ANGLE — the one quantity
    // proprioception cannot estimate — and worse the further apart the icons
    // sit, which is precisely what `gutter` and `ring fit` control. Every notch
    // of visual clarity is bought with blind travel.
    //
    // Off by default: it changes the look, and it should be a considered choice
    // rather than something a colleague inherits by surprise.
    var showPointer: Bool = true
    /// Dot diameter, × icon diameter.
    var pointerScale: CGFloat = 0.5
    /// The dashed spoke from the center out through the pointer. Not decoration
    /// in radial: its ANGLE is literally the thing that picks.
    var showPointerTrail: Bool = true
    /// The line from the pointer to whatever it currently has — the "rubber
    /// band". Separate from the spoke because they answer different questions:
    /// the spoke says where you are, the leader says what that means.
    var showPointerLeader: Bool = true
    /// How far the visible pointer may travel, from the icons out to the menu's
    /// full extent. 0 = it stops dead on the icon centers; 1 = it may run all
    /// the way out to where the sub-menus land.
    ///
    /// Purely a DISPLAY bound — the pick reads the raw offset, so pulling this in
    /// never costs you a sub-menu you could otherwise reach. What it changes is
    /// what overshooting LOOKS like: at 1 the dot keeps going and the clamp is a
    /// distant backstop; at 0 the dot pins to the icons the moment you pass them
    /// and every further millimetre of hand is silent.
    ///
    /// It bounds overshoot into EMPTY SPACE only. Land on a category with
    /// children and the bound opens up to cover the trigger and then the children
    /// themselves — see `pointerBound`. Otherwise this knob would make sub-menus
    /// blind at exactly the setting somebody chose for tidiness.
    ///
    /// Both are defensible and it is a matter of taste, which is why it is a
    /// knob. 1 is the shipped default because a dot that keeps moving keeps
    /// telling you something.
    var pointerReachRatio: CGFloat = 1
    var pointerOpacity: Double = 0.4877

    /// A hollow ring drawn at the menu's ORIGIN — the root of the hierarchy, the
    /// point every distance in this struct is measured from, and the place the
    /// gesture actually started.
    ///
    /// On a full ring the origin is obviously the middle. On an ARC it is not:
    /// the icons sit off to one side of a point with nothing at it, which is
    /// what made a quadrant menu look like it was drifting when the ring grew.
    /// Marking it turns an inferred point into a visible one.
    var showOrigin: Bool = true
    /// Diameter of that ring, × icon diameter. Ranges well past 1 on purpose —
    /// at the small end it is a dot marking the origin, at the large end it is a
    /// ring drawn around the center label.
    var originScale: CGFloat = 1.657
    /// Its stroke weight, × icon diameter. Independent of the diameter so a big
    /// ring can still be a hairline.
    var originLineWidth: CGFloat = 0.0174

    /// Triangle size, as a fraction of the icon it sits on.
    var arrowScale: CGFloat = 0.20
    /// How far the triangle stands off the icon's RIM, as a fraction of the icon
    /// diameter. Measured against the ICON rather than against the arrow on
    /// purpose: tie it to the arrow and `arrow size` drags the stand-off along
    /// with it, so the two knobs fight. Against the icon they are independent.
    /// 0.124 reproduces the original hard-coded `arrowWidth × 0.62` exactly.
    var arrowGapRatio: CGFloat = 0.2583
    /// Set by the decoder when the file it read predates the ratio fields.
    /// Deliberately absent from `CodingKeys`: it is a one-shot migration marker,
    /// not tuning, and must never be written back out.
    var needsRatioBackSolve = false

    var easeDuration: Double { max(easeFrames, 1) / 60 }

    init() {}

    // Hand-written so that a `presets.json` written by ANY earlier round still
    // decodes: every key is optional and falls back to the default above. The
    // synthesised Codable would throw on the first missing key and silently
    // drop every saved number in one go.
    private enum CodingKeys: String, CodingKey {
        case layout, iconSize, responsive, fitToContainer, gutterRatio, ringSlack
        case nudgeRatio, childNudgeRatio, childGapRatio, labelGapRatio, deadZoneRatio
        case deadZoneOfRing
        case childrenFlipped
        case submenuReachRatio, childIconScale, labelFontScale, labelRunwayScale
        case ringRadius, linearSpacing, nudge, deadZone, submenuThreshold
        case childRingGap, labelGap, childSpread, childSpacingScale, easeFrames
        case arcStartDegrees, arcSweepDegrees, appearScale, showLabel
        case showSubmenuGuide, showSubmenuArrow, arrowScale, arrowGapRatio
        case submenuOnHighlight
        case showPointer, pointerScale, showPointerTrail, pointerOpacity
        case nudgeSpread, showPointerLeader, pointerGain, pointerReachRatio
        case showOrigin, originScale, originLineWidth
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func num(_ k: CodingKeys, _ fallback: CGFloat) -> CGFloat {
            ((try? c.decodeIfPresent(CGFloat.self, forKey: k)) ?? nil) ?? fallback
        }
        func dbl(_ k: CodingKeys, _ fallback: Double) -> Double {
            ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil) ?? fallback
        }
        func flag(_ k: CodingKeys, _ fallback: Bool) -> Bool {
            ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? fallback
        }
        func whole(_ k: CodingKeys, _ fallback: Int) -> Int {
            ((try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil) ?? fallback
        }

        layout            = ((try? c.decodeIfPresent(RadialMenuLayout.self, forKey: .layout)) ?? nil) ?? layout
        iconSize          = num(.iconSize, iconSize)
        responsive        = flag(.responsive, responsive)
        fitToContainer    = flag(.fitToContainer, fitToContainer)
        gutterRatio       = num(.gutterRatio, gutterRatio)
        ringSlack         = num(.ringSlack, ringSlack)
        nudgeRatio        = num(.nudgeRatio, nudgeRatio)
        nudgeSpread       = num(.nudgeSpread, nudgeSpread)
        childNudgeRatio   = num(.childNudgeRatio, childNudgeRatio)
        childrenFlipped   = flag(.childrenFlipped, childrenFlipped)
        pointerGain       = num(.pointerGain, pointerGain)
        pointerReachRatio = num(.pointerReachRatio, pointerReachRatio)
        showOrigin        = flag(.showOrigin, showOrigin)
        originScale       = num(.originScale, originScale)
        originLineWidth   = num(.originLineWidth, originLineWidth)
        childGapRatio     = num(.childGapRatio, childGapRatio)
        labelGapRatio     = num(.labelGapRatio, labelGapRatio)
        deadZoneRatio     = num(.deadZoneRatio, deadZoneRatio)
        deadZoneOfRing    = num(.deadZoneOfRing, deadZoneOfRing)
        submenuReachRatio = num(.submenuReachRatio, submenuReachRatio)
        submenuOnHighlight = flag(.submenuOnHighlight, submenuOnHighlight)
        childIconScale    = num(.childIconScale, childIconScale)
        labelFontScale    = num(.labelFontScale, labelFontScale)
        labelRunwayScale  = num(.labelRunwayScale, labelRunwayScale)
        ringRadius        = num(.ringRadius, ringRadius)
        linearSpacing     = num(.linearSpacing, linearSpacing)
        nudge             = num(.nudge, nudge)
        deadZone          = num(.deadZone, deadZone)
        submenuThreshold  = num(.submenuThreshold, submenuThreshold)
        childRingGap      = num(.childRingGap, childRingGap)
        labelGap          = num(.labelGap, labelGap)
        childSpread       = dbl(.childSpread, childSpread)
        childSpacingScale = num(.childSpacingScale, childSpacingScale)
        easeFrames        = dbl(.easeFrames, easeFrames)
        arcStartDegrees   = dbl(.arcStartDegrees, arcStartDegrees)
        arcSweepDegrees   = dbl(.arcSweepDegrees, arcSweepDegrees)
        appearScale       = num(.appearScale, appearScale)
        showLabel         = flag(.showLabel, showLabel)
        showSubmenuGuide  = flag(.showSubmenuGuide, showSubmenuGuide)
        showSubmenuArrow  = flag(.showSubmenuArrow, showSubmenuArrow)
        arrowScale        = num(.arrowScale, arrowScale)
        arrowGapRatio     = num(.arrowGapRatio, arrowGapRatio)
        showPointer       = flag(.showPointer, showPointer)
        pointerScale      = num(.pointerScale, pointerScale)
        showPointerTrail  = flag(.showPointerTrail, showPointerTrail)
        showPointerLeader = flag(.showPointerLeader, showPointerLeader)
        pointerOpacity    = dbl(.pointerOpacity, pointerOpacity)

        // An old presets.json predates the ratio fields entirely. Only FLAG it
        // here — the back-solve itself needs the ITEM COUNT, which is not part of
        // the style (it lives on the host's `MenuPreset.icons`). Doing it inline
        // meant guessing, and a guess of 8 put the ring 25–50 pt out for every
        // saved file whose count wasn't 8.
        needsRatioBackSolve = !c.contains(.gutterRatio)
    }

    /// Recover the ratios from a round-1..6 file's ABSOLUTE values, so old tuning
    /// comes back looking identical instead of snapping to defaults — and is
    /// portable from that moment on. Call once, from the host, which knows the
    /// item count. Mirrors `resolved()`'s seat solve exactly; that is the point.
    mutating func backSolveRatios(itemCount: Int) {
        guard needsRatioBackSolve, iconSize > 0 else { return }
        needsRatioBackSolve = false

        let seats = max(itemCount, 1)
        let closed = arcSweepDegrees >= 359.9
        let step = closed ? arcSweepDegrees / Double(max(seats, 1))
                          : arcSweepDegrees / Double(max(seats - 1, 1))
        let half = min(max(step * .pi / 360, 0.0001), .pi / 2)
        let chord = 2 * ringRadius * CGFloat(sin(half))

        gutterRatio       = layout == .radial ? max(chord - iconSize, 0) / iconSize
                                              : max(linearSpacing - iconSize, 0) / iconSize
        nudgeRatio        = nudge / iconSize
        childGapRatio     = childRingGap / iconSize
        labelGapRatio     = labelGap / iconSize
        deadZoneRatio     = deadZone / iconSize
        submenuReachRatio = layout == .radial ? submenuThreshold / max(ringRadius, 1)
                                              : submenuThreshold / iconSize
    }
}

// MARK: - Metrics

/// The style, RESOLVED: real points for the current icon size, item count, arc
/// and available space. Nothing downstream reads `RadialMenuStyle` directly for
/// geometry — it reads this — so there is exactly one place where a ratio turns
/// into a number, and the drawing and the hit-testing cannot disagree.
struct RadialMenuMetrics: Equatable {
    // geometry, points
    var iconSize: CGFloat = 62
    var childIconSize: CGFloat = 51
    var ringRadius: CGFloat = 105
    /// Center-to-center spacing of neighbouring top-level icons (linear layouts).
    var pitch: CGFloat = 78
    var childSpacing: CGFloat = 66
    var nudge: CGFloat = 8.5
    var childNudge: CGFloat = 7
    var childGap: CGFloat = 64
    var submenuThreshold: CGFloat = 85
    var deadZone: CGFloat = 0
    var labelGap: CGFloat = 16
    var labelRunway: CGFloat = 520
    var labelFontSize: CGFloat = 21
    var canvas: CGFloat = 460
    /// Smallest angle between two children that still clears the gutter (radial).
    /// An ANGLE, so it is unaffected by `fit` — both radius and icon scale together.
    var childMinStepDegrees: Double = 0

    // shape — carried here so `seat(_:)` below is self-contained and the host can
    // ask where things are without a second copy of the layout maths
    var layout: RadialMenuLayout = .radial
    var arcStartDegrees: Double = 0

    /// How many seats the menu has — one per item, always.
    var seats: Int = 8
    var stepDegrees: Double = 45
    /// Highest item index the pointer can actually reach. On a narrow arc the
    /// angular pick wraps at ±180°, so a long list can run past the reachable
    /// band — silently, until this says so.
    var reachableCount: Int = 8

    /// Where the drawn icons actually SIT, relative to the menu's origin.
    ///
    /// For a full ring or a column this is (0,0) — the origin is in the middle of
    /// the icons. For an ARC it is not: four icons in the 12–3 quadrant all live
    /// up and to the right of an origin that has nothing at it. That is why
    /// nudging `ring fit` or `arc sweep` made the whole layout appear to swing
    /// across the screen — the geometry was rock steady, but the only part you
    /// can SEE was orbiting a point you can't.
    ///
    /// Top-level seats only, deliberately: including children would make the
    /// layout shift every time a sub-menu opened, which is the same complaint in
    /// a different costume.
    var contentCenter: CGPoint = .zero

    // diagnostics — the knob panel reads these back
    /// 1 = the menu fits as designed; below 1 = it was shrunk to fit the host.
    var fit: CGFloat = 1
    /// Edge-to-edge clear space between neighbouring icons, after everything.
    /// Negative means they overlap.
    var gutter: CGFloat = 18.36
    /// The same measurement for a sub-menu's children.
    var childGutter: CGFloat = 16.6
    /// True when `submenu at` asked for a boundary inside the icons and was
    /// raised to the rim. The knob is then not telling the whole truth, so the
    /// panel says so.
    var submenuThresholdFloored: Bool = false

    /// Half-extents of everything the menu draws. The ceiling for the visible
    /// pointer's clamp — see `pointerReach` for where it actually stops, which
    /// is a fraction of the way here. The clamp is itself feedback: it says
    /// "further buys you nothing".
    var reach: CGSize = CGSize(width: 230, height: 230)

    /// Where the visible pointer is actually clamped: `pointerReachRatio` of the
    /// way from the ICONS out to `reach`. At 1 the two are the same thing.
    var pointerReach: CGSize = CGSize(width: 230, height: 230)

    /// BLIND TRAVEL — how far the pointer moves with nothing changing on screen.
    ///
    /// `across` is the gap between adjacent pick regions, which turns out to be
    /// the gutter under another name: widen the ring for legibility and you buy
    /// exactly that much dead feedback space.
    ///
    /// `along` is the axis that does not pick at all — in radial, sliding in and
    /// out never changes the highlight, it only eventually crosses the sub-menu
    /// threshold. That axis is usually the bigger number, and it is the one that
    /// makes a wide ring feel vague.
    var blindAcross: CGFloat = 18
    var blindAlong: CGFloat = 85
}

extension RadialMenuMetrics {

    /// 0° = straight up, then clockwise — the way people describe a pie menu.
    /// Accepts out-of-range slots on purpose: the canvas solve asks where
    /// the phantom seats just past each end would be.
    func angle(_ slot: Int) -> CGFloat {
        let deg = arcStartDegrees + stepDegrees * Double(slot) - 90
        return CGFloat(deg * .pi / 180)
    }

    /// A seat's position at a CONTINUOUS coordinate — 3.5 is exactly between
    /// seats 3 and 4. Every formula below already took a real number; only the
    /// signature was pretending otherwise.
    func seatAt(_ t: Double) -> CGPoint {
        switch layout {
        case .radial:
            let deg = arcStartDegrees + stepDegrees * t - 90
            let a = CGFloat(deg * .pi / 180)
            return CGPoint(x: cos(a) * ringRadius, y: sin(a) * ringRadius)
        case .vertical:
            return CGPoint(x: 0, y: (CGFloat(t) - CGFloat(seats - 1) / 2) * pitch)
        case .horizontal:
            return CGPoint(x: (CGFloat(t) - CGFloat(seats - 1) / 2) * pitch, y: 0)
        }
    }

    /// A seat's position relative to the menu's origin, before the nudge.
    ///
    /// This lives on the METRICS rather than on the view so that the drawing, the
    /// hit-testing, the preview pose and the content-centering all read one
    /// function. Every time this logic has been duplicated it has drifted.
    func seat(_ slot: Int) -> CGPoint { seatAt(Double(slot)) }

    /// Middle of everything the menu DRAWS, in the menu's own coordinates.
    ///
    /// The seats used to be the whole story, and the icon radius was left out of
    /// it because a symmetric radius cancels. Both stopped being true when the
    /// origin ring grew up: at `originScale 1.66` it is a 125 pt circle with the
    /// menu's label inside it, and on a quarter-arc it is the one thing NOT in
    /// the arc. Centering on the seats alone pinned the arc beautifully and swung
    /// that ring — and the label with it — most of a ring radius off the anchor.
    ///
    /// So it is the union of the seat discs and the origin disc. Mixing two
    /// different radii is exactly why the icon radius has to be in there now.
    ///
    /// Children are still out, deliberately and for the original reason: they
    /// appear and disappear, so including them would shift the whole layout
    /// every time a sub-menu opened — which now happens on every highlight, so
    /// the menu would lurch each time you passed a parent. The label is out for the same reason in
    /// miniature — its width changes with the highlighted item's name, and the
    /// menu would breathe as you slid along the ring.
    fileprivate func drawnBoundsCenter(iconRadius: CGFloat,
                                       originRadius: CGFloat) -> CGPoint {
        guard seats > 0 else { return .zero }
        var lo = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
        var hi = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude)
        func include(_ p: CGPoint, _ r: CGFloat) {
            lo.x = min(lo.x, p.x - r); hi.x = max(hi.x, p.x + r)
            lo.y = min(lo.y, p.y - r); hi.y = max(hi.y, p.y + r)
        }
        for s in 0..<seats { include(seat(s), iconRadius) }
        // (0,0) is where the origin ring is drawn, always.
        if originRadius > 0 { include(.zero, originRadius) }
        guard lo.x <= hi.x else { return .zero }
        return CGPoint(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2)
    }
}

extension RadialMenuStyle {

    /// Turn ratios into points. Pure — no view state, no side effects — so it is
    /// safe to call from `body` and equally safe to call from the exporter.
    ///
    /// - Parameters:
    ///   - itemCount: how many items, and therefore how many seats.
    ///   - maxChildren: largest sub-menu, used only to size the canvas.
    ///   - available: space the host can give the menu. nil = unconstrained.
    func resolved(itemCount: Int, maxChildren: Int = 0, available: CGSize? = nil) -> RadialMenuMetrics {
        var m = RadialMenuMetrics()

        // ── seats ─────────────────────────────────────────────────────────────
        // One seat per item, always. See the header note on why a menu that
        // scrolls stopped being a thing this component does.
        let seats = max(itemCount, 1)

        // A CLOSED ring divides the sweep by n (last icon wraps onto the first);
        // an open arc divides by n-1 so the first and last land on the ends.
        let closedRing = arcSweepDegrees >= 359.9
        let step = closedRing
            ? arcSweepDegrees / Double(max(seats, 1))
            : arcSweepDegrees / Double(max(seats - 1, 1))

        m.layout = layout
        m.arcStartDegrees = arcStartDegrees
        m.seats = seats
        m.stepDegrees = step

        // How far the angular pick can actually see. `seatCoordinate` wraps the
        // pointer into a 360° band centered on the arc's MIDDLE, so the reachable
        // seat range is (seats-1)/2 ± 180/step. Anything past that is drawable
        // but unselectable, which is worth a warning rather than a mystery.
        if layout == .radial && !closedRing && step > 0.0001 {
            let mid = Double(seats - 1) / 2
            // Largest slot the band can express is `mid + 180/step` (exclusive);
            // `pointedIndex` rounds, so index i is reachable while i < that + 0.5.
            // Hence ceil, not round — `.rounded()` ties away from zero and would
            // over-report by one at exactly .5, which is the case that matters.
            let span = mid + 180 / step + 0.5
            m.reachableCount = min(Int(span.rounded(.up)), seats)
        } else {
            m.reachableCount = seats
        }

        // ── base unit ─────────────────────────────────────────────────────────
        let icon = max(iconSize, 8)

        // ── pitch and radius ──────────────────────────────────────────────────
        var pitch: CGFloat
        var ring: CGFloat

        if responsive {
            pitch = icon * (1 + max(gutterRatio, 0))

            // Solve from the TIGHTEST pair, which on a nearly-closed arc is not
            // the neighbours — it is the wrap, last seat back round onto first.
            //
            // This measurement already existed, in the gutter readout at the
            // bottom of this function, complete with a comment explaining why the
            // wrap can be the worst pair. It just never fed the SOLVE. So the
            // panel would correctly report icons overlapping while the packer sat
            // there insisting everything was fine — we were measuring the
            // collision and not preventing it.
            //
            // With twelve icons the two are equal at 330° (an open arc's spacing
            // matches a closed ring's at exactly 360·(n−1)/n); above that the
            // wrap is tighter, and the ring now grows to keep it clear rather
            // than letting the ends run into each other.
            let wrapDeg = closedRing ? step : max(360 - arcSweepDegrees, 0)
            let packStep = closedRing ? step : min(step, wrapDeg)
            // Clamped at a half-turn: past 180° the sine folds back and would
            // start growing the ring again for no reason. Floored well above
            // zero because the wrap gap goes there — an arc at 359.9° wants an
            // infinite radius, and `arc sweep` snaps to a full ring before it
            // can ask for one.
            let half = min(max(packStep * .pi / 360, 0.004), .pi / 2)
            let packed = pitch / (2 * CGFloat(sin(half)))
            ring = max(packed, icon * 0.75) * max(ringSlack, 0.2)
        } else {
            pitch = max(linearSpacing, 1)
            ring = max(ringRadius, 1)
        }

        // ── everything else ───────────────────────────────────────────────────
        var nudgePt      = responsive ? icon * nudgeRatio    : nudge
        var childGapPt   = responsive ? icon * childGapRatio : childRingGap
        var labelGapPt   = responsive ? icon * labelGapRatio : labelGap
        var deadZonePt   = responsive ? icon * deadZoneRatio : deadZone

        // The radial dead zone, measured against the trip rather than the icon.
        //
        // Solved from the PRE-`fit` ring on purpose: `fit` scales the ring and
        // this together a few lines down, so the fraction survives a window
        // resize untouched. Deriving it after would make the neutral zone a
        // different share of the dial in a small window than a large one.
        //
        // Capped below 1 so there is always somewhere left to stand that counts
        // as "on an icon". A dead zone that reached the ring would be a menu you
        // can point at and never pick from.
        if layout == .radial, responsive, deadZoneOfRing > 0 {
            deadZonePt = ring * min(deadZoneOfRing, 0.9)
        }
        var thresholdPt: CGFloat
        if responsive {
            thresholdPt = layout == .radial ? ring * submenuReachRatio
                                            : icon * submenuReachRatio
        } else {
            thresholdPt = submenuThreshold
        }
        var childPitch   = pitch * max(childSpacingScale, 0.05)
        var childIcon    = icon * max(childIconScale, 0.1)
        var runway       = icon * max(labelRunwayScale, 1)
        var fontSize     = icon * max(labelFontScale, 0.05)
        var iconPt       = icon

        // ── sub-menu packing ──────────────────────────────────────────────────
        // The children were the one part of the menu still laid out by an
        // ABSOLUTE angle: `childSpread` fanned them over a fixed arc no matter
        // how small the ring or how many of them there were, so five children,
        // or a tight spread, or a small derived ring quietly overlapped them.
        // Same constraint as the top level, expressed as a minimum ANGLE — which
        // is fit-invariant, since radius and icon shrink together.
        let childRadius = max(ring + childGapPt, 1)
        let childWant = childIcon * (1 + max(gutterRatio, 0))
        let childMinStep = 2 * asin(min(Double(childWant / (2 * childRadius)), 1))
        m.childMinStepDegrees = responsive ? childMinStep * 180 / .pi : 0

        // ── how much room this actually wants ─────────────────────────────────
        // Half-extents, measured from the center out — the menu is centered on the
        // pinch, so the box it needs is symmetric even when the content is not.
        let childRun = childGapPt + CGFloat(max(maxChildren - 1, 0)) * childPitch
        var needW: CGFloat
        var needH: CGFloat
        switch layout {
        case .radial:
            // Children fan along an arc at ring + childGap; the spread widens
            // the arc but does not reach further out than that.
            let reach = ring + childGapPt + max(iconPt, childIcon) / 2
            needW = reach * 2
            needH = reach * 2
        case .vertical:
            // The column's own half-length already covers `iconPt / 2`; the
            // child row reaches childRun plus HALF a child icon, not a whole one.
            needH = CGFloat(seats - 1) * pitch + iconPt * 2
            needW = (childRun + childIcon / 2) * 2
        case .horizontal:
            needW = CGFloat(seats - 1) * pitch + iconPt * 2
            needH = (childRun + childIcon / 2) * 2
        }

        // ── fit ───────────────────────────────────────────────────────────────
        // One factor applied to every LENGTH. Scaling the metrics instead of the
        // view keeps the pointer and the pixels in the same coordinate space.
        //
        // Floored at a quarter: past that the icons are dots and the labels are
        // unreadable, so overflowing is the better failure. `> 0` rather than
        // `> 1` on the guard — a 1 pt container used to skip fit entirely and
        // draw at full size, which is the opposite of what it asked for.
        var fit: CGFloat = 1
        if fitToContainer, let a = available, a.width > 0, a.height > 0 {
            fit = max(min(1, min(a.width / max(needW, 1), a.height / max(needH, 1))), 0.25)
        }
        if fit < 1 {
            iconPt *= fit; ring *= fit; pitch *= fit; nudgePt *= fit
            childGapPt *= fit; labelGapPt *= fit; deadZonePt *= fit
            thresholdPt *= fit; childPitch *= fit; childIcon *= fit
            runway *= fit; fontSize *= fit
            needW *= fit; needH *= fit
        }

        m.iconSize = iconPt
        m.childIconSize = childIcon
        m.ringRadius = ring
        m.pitch = pitch
        m.childSpacing = childPitch
        m.nudge = nudgePt
        // Against the CHILD icon, which has already been through `fit`.
        m.childNudge = max(childIcon * max(childNudgeRatio, 0), 0)
        m.childGap = childGapPt
        // THE COMMIT FLOOR. A child must never be pickable while the hand is
        // still among the top-level icons.
        //
        // This is not a taste knob, it is a correctness property, so it is
        // enforced rather than left to a slider. `submenuReachRatio` used to
        // mean "how far before children APPEAR", and 0.81 × ring put that
        // comfortably INSIDE the ring — sensible for a reveal, because you want
        // them out before you arrive. As the COMMIT boundary the same number is
        // a bug: sitting on an icon is already past it, so every tangential
        // wobble along the ring re-picked among the children of whatever the
        // hand was nearest. Deciding which category you want lit up children you
        // had not asked for.
        //
        // radial: the outer rim of the ring of icons. linear: the side rim of
        // the column or row, which is why it essentially never binds there —
        // moving ACROSS a column is already unambiguous.
        let commitFloor: CGFloat = layout == .radial ? ring + iconPt / 2 : iconPt / 2
        m.submenuThresholdFloored = thresholdPt < commitFloor
        m.submenuThreshold = max(thresholdPt, commitFloor)
        m.deadZone = deadZonePt
        m.labelGap = labelGapPt
        m.labelRunway = runway
        m.labelFontSize = fontSize
        m.canvas = max(needW, needH)
        m.fit = fit
        m.reach = CGSize(width: needW / 2, height: needH / 2)

        // The pointer's own bound, somewhere between the icons and everything.
        //
        // The floor is where the ICONS are, not zero: pinning the dot to the
        // menu's origin would be a different thing entirely, and a useless one.
        // In the linear layouts the ACROSS floor is half an icon rather than the
        // seat line itself, because across is the direction sub-menus open and a
        // dot welded to the column could never show you leaving it.
        let seatExtent: CGSize
        switch layout {
        case .radial:
            seatExtent = CGSize(width: ring, height: ring)
        case .vertical:
            seatExtent = CGSize(width: iconPt / 2,
                                height: CGFloat(seats - 1) * pitch / 2)
        case .horizontal:
            seatExtent = CGSize(width: CGFloat(seats - 1) * pitch / 2,
                                height: iconPt / 2)
        }
        let t = min(max(pointerReachRatio, 0), 1)
        m.pointerReach = CGSize(
            width: seatExtent.width + (m.reach.width - seatExtent.width) * t,
            height: seatExtent.height + (m.reach.height - seatExtent.height) * t)
        m.blindAcross = m.gutter
        m.blindAlong = max(m.submenuThreshold - m.deadZone, 0)

        // Last, because it reads the ring/pitch/seats that were just written.
        m.contentCenter = m.drawnBoundsCenter(
            iconRadius: m.iconSize / 2,
            originRadius: showOrigin ? max(m.iconSize * max(originScale, 0.02), 3) / 2 : 0)

        // Report the real edge-to-edge clearance, which is what the eye judges.
        //
        // On a ring the worst pair is not always the ADJACENT pair: an arc that
        // stops just short of a full turn (sweep 359.5) wraps the last seat back
        // onto the first with half a degree between them, while every adjacent
        // pair still looks healthy. Measure the smaller of the two.
        if layout == .radial {
            let wrapDeg = 360 - step * Double(max(seats - 1, 1))
            let worst = closedRing ? step : min(step, max(wrapDeg, 0))
            let halfWorst = min(max(worst * .pi / 360, 0), .pi / 2)
            m.gutter = 2 * ring * CGFloat(sin(halfWorst)) - iconPt

            let usedStep = maxChildren > 1
                ? max(childSpread / Double(maxChildren - 1), m.childMinStepDegrees)
                : 0
            m.childGutter = maxChildren > 1
                ? 2 * (ring + childGapPt) * CGFloat(sin(min(max(usedStep * .pi / 360, 0), .pi / 2))) - childIcon
                : childIcon
        } else {
            m.gutter = pitch - iconPt
            m.childGutter = maxChildren > 1 ? childPitch - childIcon : childIcon
        }

        return m
    }
}

// MARK: - Highlight

// MARK: - Preview

/// A STATIC pose, for looking at the menu instead of using it.
///
/// Tuning was a chicken-and-egg problem: the menu only existed while a gesture
/// was held, so the moment you reached for a slider it vanished, and you judged
/// each change from memory of the last one. This lets the host pin it open.
///
/// It works by synthesising a pointer at a seat's own position — reusing the
/// SAME `position(_:_:)` the drawing uses, never a second copy of the maths — so
/// a previewed menu is not an approximation of the real thing. It goes through
/// the identical pick, nudge, threshold and label path, and anything you can see
/// here is what a real gesture would produce.
struct RadialMenuPreview: Equatable {
    /// How much of the structure to show at once.
    enum Depth: String, CaseIterable, Identifiable, Codable {
        /// Top level only.
        case menu
        /// …plus the highlighted item's children.
        ///
        /// ONE branch, deliberately. An earlier `.all` opened every parent at
        /// once, which looked thorough and was actively misleading: two fans
        /// overlapping is a state the menu can never actually be in, so it
        /// showed a collision that does not exist and hid the one that might.
        case submenu
        var id: String { rawValue }
    }

    /// Which SEAT the pointer sits on — CONTINUOUS, not an integer.
    ///
    /// Fractional values are the point: 3.5 puts the pointer exactly between
    /// seats 3 and 4, which is the only way to see the two things that live in
    /// that gap — the proximity falloff leaning both neighbours, and the pointer
    /// dot itself, which on a whole number is hidden underneath an icon.
    ///
    /// Seat and item index are the same number — there is no window for them to
    /// differ across — so this names the item as directly as it names the seat.
    var slot: Double = 0
    var depth: Depth = .menu

    /// Draw the measurement guides — the ring the solve produced, and the gutter
    /// it was solving FOR. The fastest way to see that `gutter` and `ring fit`
    /// are not the same knob.
    var showGuides: Bool = false

    /// Keep the parent triangles lit even once their children are out.
    ///
    /// Normally an arrow retires the moment its sub-menu appears — it has said
    /// what it had to say. That is right in use and useless for TUNING: the only
    /// state in which you can see an arrow is the one state in which you cannot
    /// see the children it points at, so `arrow size` and `arrow gap` had to be
    /// judged against nothing. Pinned, you can set them against the thing they
    /// aim for. Preview only; a live gesture always retires them as designed.
    var pinArrows: Bool = false

    var opensSubmenu: Bool { depth != .menu }
}

/// What the pointer is currently over. `child` nil = the parent itself.
struct RadialMenuHighlight: Equatable {
    var parent: RadialMenuItem?
    var child: RadialMenuItem?
    /// The action that would fire on release.
    var action: RadialMenuItem? { child ?? parent }
    /// Just the name of what's selected — the parent's name is redundant once a
    /// child is highlighted.
    var labelText: String { action?.label ?? "" }
}

// MARK: - View

struct RadialMenu: View {
    let items: [RadialMenuItem]
    var style = RadialMenuStyle()
    /// Pointer offset from the menu center, in points. nil = pinch not held.
    let pointer: CGPoint?
    var isPresented: Bool
    /// Published upward so the host can confirm on release.
    @Binding var highlight: RadialMenuHighlight

    /// The room the host has. nil = unconstrained (the menu takes what it wants).
    var available: CGSize? = nil
    /// Hold the menu in a static pose so it can be looked at while it is tuned.
    /// A live `pointer` always wins, so previewing never blocks testing.
    var preview: RadialMenuPreview? = nil
    /// Resolved metrics, published back so a host can show them (the tuner's knob
    /// panel prints the derived ring radius / pitch / gutter live).
    var onResolve: ((RadialMenuMetrics) -> Void)? = nil

    /// Everything about `items` that identity alone does not cover.
    ///
    /// Built by hand rather than by interpolation so it stays cheap: it is
    /// evaluated once per body pass, and `items` is a menu, not a database.
    private var contentSignature: String {
        var out = ""
        for item in items {
            out += item.id + "\u{1}" + item.label + "\u{1}"
            for kid in item.children { out += kid.id + "\u{3}" + kid.label + "\u{4}" }
            out += "\u{2}"
        }
        return out
    }

    /// Single source of geometric truth for this frame.
    private var m: RadialMenuMetrics {
        style.resolved(itemCount: items.count, maxChildren: maxChildCount, available: available)
    }

    /// The pointer everything downstream reasons about. A real gesture always
    /// wins over a preview pose, so pinning the menu open to tune it never gets
    /// in the way of then testing it for real.
    private func activePointer(_ m: RadialMenuMetrics) -> CGPoint? {
        if let p = pointer { return p }
        guard let pv = preview else { return nil }
        return previewPointer(pv, m)
    }

    /// Where a preview pose puts the pointer. Built from `position(_:_:)` — the
    /// same function that places the icons — so the pick can only ever agree with
    /// the drawing. Inverting the pick instead would be a second copy of the
    /// layout maths, and the two would drift.
    private func previewPointer(_ pv: RadialMenuPreview, _ m: RadialMenuMetrics) -> CGPoint {
        let t = min(max(pv.slot, 0), Double(max(m.seats - 1, 0)))
        let seat = m.seatAt(t)

        guard pv.opensSubmenu else {
            // A seat at dead center (a one-item column) would be rejected by the
            // dead-zone epsilon and light nothing up, so nudge it off zero.
            if abs(seat.x) < 0.75 && abs(seat.y) < 0.75 {
                return CGPoint(x: 0, y: -max(m.deadZone + 1, 1))
            }
            return seat
        }

        // Push along the sub-menu direction until it is past the threshold, so
        // the children open exactly as they would under a real gesture. 8% over,
        // not 0.1%, so a rounding wobble can't leave it hovering on the line.
        let past = m.submenuThreshold * 1.08
        switch style.layout {
        case .radial:
            let r = max(hypot(seat.x, seat.y), 0.001)
            return CGPoint(x: seat.x / r * past, y: seat.y / r * past)
        case .vertical:
            return CGPoint(x: childAxis.x * past, y: seat.y)
        case .horizontal:
            return CGPoint(x: seat.x, y: childAxis.y * past)
        }
    }

    var body: some View {
        let m = self.m
        ZStack {
            if style.showSubmenuGuide, highlightedHasChildren { submenuGuide(m) }
            guideLayer(m)
            originLayer(m)
            pointerLayer(m)
            if style.showLabel { label(m) }

            Group {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let isOn = highlight.parent == item
                    let p = iconCenter(i, m)

                    iconButton(item, size: m.iconSize,
                               highlighted: isOn && highlight.child == nil,
                               // The arrow points the way this item's children
                               // will come out, and retires once they're out.
                               arrow: item.children.isEmpty ? nil : outward(i, m),
                               arrowLit: arrowIsLit(item, highlighted: isOn, m))
                        .offset(x: p.x, y: p.y)

                    if showsChildren(of: item, highlighted: isOn, m) {
                        ForEach(Array(item.children.enumerated()), id: \.element.id) { ci, child in
                            let cp = childCenter(parent: i, child: ci,
                                                 of: item.children.count,
                                                 item: child, m)
                            // NO base .offset here on purpose. `.offset` doesn't move a
                            // view's LAYOUT frame, so a scale applied outside it pivots
                            // around the menu's center — which is exactly why children
                            // looked like they grew out of the middle. The transition
                            // owns both scale and position, in that order, so the pivot
                            // is the icon itself.
                            iconButton(child, size: m.childIconSize,
                                       highlighted: highlight.child == child)
                                .transition(.emerging(from: p, to: cp))
                        }
                    }
                }
            }
            // Icons ease (in place) as the highlight moves; this is also the timing
            // context the child transition rides.
            .animation(.easeOut(duration: style.easeDuration), value: highlight)

            guideLabels(m)
        }
        .frame(width: m.canvas, height: m.canvas)
        // NO animation on `m`. There used to be one here, on the theory that
        // easing geometry changes would make an icon-size drag read as one
        // continuous object. It did the opposite.
        //
        // A slider drag emits a new value every frame, so every frame started a
        // fresh 233 ms ease toward a target that had already moved — the icons
        // rubber-banded along behind the hand instead of tracking it. And since
        // the host's `.position` is not animated, on an arc the origin snapped
        // instantly while the ring lagged a third of a second behind, so the
        // whole layout lurched one way and then settled back.
        //
        // The slider IS the animation. Geometry tracks it directly. The eased
        // show/hide below and the nudge still animate — those are discrete
        // events, which is what easing is for.
        .scaleEffect(isPresented ? 1 : style.appearScale)
        .opacity(isPresented ? 1 : 0)
        .animation(.easeOut(duration: style.easeDuration), value: isPresented)
        .onChange(of: pointer) { _, _ in recomputeHighlight() }
        // Item CONTENT, not item identity. `RadialMenuItem ==` compares ids
        // only — deliberately, so a rename does not replace the item — which
        // means renaming one, or swapping its glyph, changes nothing this view
        // can see. The icons redraw regardless (they read `items` directly),
        // but `highlight` is a published COPY and would go on reporting the old
        // label until something unrelated forced a re-pick. Any host with live
        // item data hits this; the tuner's item editor hits it every keystroke.
        .onChange(of: contentSignature) { _, _ in recomputeHighlight() }
        // Moving the preview pose has to re-pick just like moving a hand does —
        // and so does releasing a gesture, which falls back to the pose.
        .onChange(of: preview) { _, _ in recomputeHighlight() }
        // Re-pick when the GEOMETRY moves under a held pinch, too: dragging a
        // size slider mid-pinch must not leave the highlight on the icon that
        // used to be there. Same place the host gets its metrics readout.
        .onChange(of: m) { _, new in
            recomputeHighlight()
            onResolve?(new)
        }
        // On the way IN as well as out. With a `hold` delay the host is already
        // feeding pointer samples while the menu is still hidden, and every one
        // of them is dropped by the `isPresented` guard in `recomputeHighlight`.
        // Without this the menu used to appear with nothing lit and no label
        // until you jiggled — and releasing without jiggling read as "cancelled".
        .onChange(of: isPresented) { _, shown in
            if shown {
                recomputeHighlight()
            } else {
                highlight = .init()
            }
        }
        // FIRST render too. Every other recompute hangs off an `onChange`, and
        // none of those fire on appearance — so a menu that starts presented
        // (a preview at launch) would sit there with nothing highlighted.
        .onAppear { onResolve?(m); recomputeHighlight() }
        .allowsHitTesting(false)   // the HOST owns input; this is a pure readout
    }

    // MARK: - The pick
    //
    // Seat index IS item index. There is no window, no scroll offset and no
    // mapping between the two — which is why this section is nine lines and used
    // to be a hundred and fifty. See the header note.

    /// True when picking should use the continuous seat coordinate rather than
    /// the wrap-around angular pick (which only makes sense on a closed ring).
    private func usesSeatCoordinate(_ m: RadialMenuMetrics) -> Bool {
        style.layout != .radial || style.arcSweepDegrees < 359.9
    }

    /// The pointer's position expressed in SEAT units: 0 = first seat, 1 = second…
    /// Fractional on purpose — the falloff between two icons reads it directly.
    private func seatCoordinate(_ p: CGPoint, _ m: RadialMenuMetrics) -> Double {
        switch style.layout {
        case .vertical:
            return Double(p.y / m.pitch) + Double(m.seats - 1) / 2
        case .horizontal:
            return Double(p.x / m.pitch) + Double(m.seats - 1) / 2
        case .radial:
            // The angular pick has to wrap somewhere, and where it wraps is where
            // the list stops being reachable. Center the ±180° band on the arc's
            // MIDDLE rather than on seat 0: seat 0 used to sit at one edge of the
            // band, so half of it was spent behind the start of the menu and a
            // longer list ran off the far end unselectably. Centered, the same
            // 360° covers roughly twice as many seats and the two ends match.
            let mid = m.stepDegrees * Double(m.seats - 1) / 2
            let first = style.arcStartDegrees - 90 + mid
            var delta = atan2(Double(p.y), Double(p.x)) * 180 / .pi - first
            delta = (delta + 180).truncatingRemainder(dividingBy: 360)
            if delta < 0 { delta += 360 }
            delta -= 180
            return (delta + mid) / max(m.stepDegrees, 0.0001)
        }
    }

    /// Which item the pointer is over.
    private func pointedIndex(_ m: RadialMenuMetrics) -> Int? {
        guard !items.isEmpty, let p = activePointer(m) else { return nil }
        if usesSeatCoordinate(m) {
            return min(max(Int(seatCoordinate(p, m).rounded()), 0), items.count - 1)
        }
        // Closed ring: nearest by ANGLE, so overshooting the ring never weakens
        // the pick and the seam behaves.
        let pa = atan2(p.y, p.x)
        return items.indices.min {
            angularDistance(pa, angle($0, m)) < angularDistance(pa, angle($1, m))
        }
    }

    // MARK: layout (everything below is keyed by SLOT, not by item index)

    private var maxChildCount: Int { items.map(\.children.count).max() ?? 0 }

    // Placement now lives on RadialMenuMetrics — these are thin forwarders so the
    // call sites below read the same as they always did. There is exactly ONE
    // implementation of where a seat goes, and the preview pose and the
    // content-centering share it rather than reimplementing it.
    private func angle(_ slot: Int, _ m: RadialMenuMetrics) -> CGFloat { m.angle(slot) }
    private func position(_ slot: Int, _ m: RadialMenuMetrics) -> CGPoint { m.seat(slot) }

    /// Where the icon actually SITS right now — nudge included, so the sub-menu
    /// animation anchors to what the eye is looking at.
    private func iconCenter(_ s: Int, _ m: RadialMenuMetrics) -> CGPoint {
        let base = position(s, m)
        let amount = nudgeAmount(s, m)
        guard amount != 0 else { return base }
        let d = outward(s, m)
        return CGPoint(x: base.x + d.x * amount, y: base.y + d.y * amount)
    }

    /// How far the pointer is from a seat, measured in SEATS.
    ///
    /// Seats are the right unit for a falloff: scale-free, identical in all three
    /// layouts, and already what `seatCoordinate` speaks.
    private func seatDistance(_ s: Int, _ p: CGPoint, _ m: RadialMenuMetrics) -> CGFloat {
        if style.layout == .radial, !usesSeatCoordinate(m) {
            // Closed ring: measure by ANGLE, so the seam between the last seat
            // and the first is one short hop rather than the whole way round.
            let a = angularDistance(atan2(p.y, p.x), m.angle(s))
            return CGFloat(Double(a) * 180 / .pi / max(m.stepDegrees, 0.0001))
        }
        return CGFloat(abs(seatCoordinate(p, m) - Double(s)))
    }

    /// The nudge for ONE seat. With `nudgeSpread` at 0 this is the original
    /// all-or-nothing pop; above 0 it is a raised cosine over seat distance, so
    /// neighbours lean in proportion to how close the hand is and the space
    /// between icons stops being silent.
    private func nudgeAmount(_ s: Int, _ m: RadialMenuMetrics) -> CGFloat {
        guard let p = activePointer(m) else { return 0 }
        // Same gate the highlight uses: nothing reacts before the hand has
        // actually moved, or the whole ring would breathe on contact.
        guard hypot(p.x, p.y) >= max(m.deadZone, 0.75) else { return 0 }

        let spread = max(style.nudgeSpread, 0)
        guard spread > 0.001 else {
            guard let g = highlight.parent.flatMap({ items.firstIndex(of: $0) }),
                  g == s else { return 0 }
            return m.nudge
        }

        let d = seatDistance(s, p, m)
        guard d < spread else { return 0 }
        // Raised cosine: 1 on the seat, 0 at the edge of the spread, and flat at
        // both ends so icons ease in and out instead of snapping.
        return m.nudge * CGFloat(0.5 * (1 + cos(.pi * Double(d / spread))))
    }

    /// The direction a sub-menu comes out along, in the linear layouts.
    ///
    /// ONE definition, and everything with a side reads it: where the children
    /// land, which way the parent leans and points, which direction of travel
    /// opens the sub-menu, where the trigger guide is drawn, and which side the
    /// label retreats to. `childrenFlipped` therefore flips all of them at once,
    /// and there is no second sign anywhere that could fall out of step.
    private var childAxis: CGPoint {
        let s: CGFloat = style.childrenFlipped ? -1 : 1
        switch style.layout {
        case .radial:     return .zero                    // radial has one "out"
        case .vertical:   return CGPoint(x: s, y: 0)      // right, or left
        case .horizontal: return CGPoint(x: 0, y: -s)     // up, or down
        }
    }

    /// Where a highlighted CHILD pops to — ACROSS the fan, never along it.
    ///
    /// This is the whole reason it is not just `childAxis`. In a linear layout
    /// the children are a straight run, so nudging one along that run shoves it
    /// at its own neighbour and the gap it opens on one side it closes on the
    /// other. Perpendicular, it steps out of the line entirely and separates
    /// from every sibling at once.
    ///
    /// Radial gets this free and always did: the fan is an arc and "outward" is
    /// already at right angles to it.
    ///
    /// Fixed, not flipped with `childrenFlipped`: up and right are the
    /// directions a reader's eye already treats as "forward", and a sub-menu
    /// that pops DOWN because it happens to hang below the row is just harder
    /// to read.
    private var childNudgeAxis: CGPoint {
        switch style.layout {
        case .radial:     return .zero
        case .vertical:   return CGPoint(x: 0, y: -1)   // the row runs across → up
        case .horizontal: return CGPoint(x: 1, y: 0)    // the column runs down → right
        }
    }

    /// Which way "outward" is — the parent nudge and the parent arrow share it,
    /// so they agree by construction.
    private func outward(_ slot: Int, _ m: RadialMenuMetrics) -> CGPoint {
        switch style.layout {
        case .radial:
            let a = angle(slot, m)
            return CGPoint(x: cos(a), y: sin(a))
        case .vertical, .horizontal:
            return childAxis
        }
    }

    /// Where a child icon actually SITS — its seat, plus the pop-out if it is the
    /// one under the hand.
    ///
    /// The nudge goes into the position the TRANSITION resolves to rather than
    /// onto an `.offset` outside it, for exactly the reason the base position
    /// does: an offset applied outside the transition's scale pivots the
    /// animation on the menu's center, and the child appears to grow out of the
    /// middle instead of out of its parent.
    private func childCenter(parent slot: Int, child: Int, of count: Int,
                             item: RadialMenuItem, _ m: RadialMenuMetrics) -> CGPoint {
        let base = childPosition(parent: slot, child: child, of: count, m)
        guard highlight.child == item, m.childNudge > 0 else { return base }
        let d = childOutward(base, slot, m)
        return CGPoint(x: base.x + d.x * m.childNudge, y: base.y + d.y * m.childNudge)
    }

    /// Outward for a CHILD is along its OWN radius, not its parent's. On a wide
    /// fan the two differ by half the spread, and nudging along the parent's
    /// direction slides the outer children sideways rather than out.
    private func childOutward(_ p: CGPoint, _ slot: Int, _ m: RadialMenuMetrics) -> CGPoint {
        switch style.layout {
        case .radial:
            let r = max(hypot(p.x, p.y), 0.001)
            return CGPoint(x: p.x / r, y: p.y / r)
        case .vertical, .horizontal:
            return childNudgeAxis
        }
    }

    private func childPosition(parent slot: Int, child: Int, of count: Int,
                               _ m: RadialMenuMetrics) -> CGPoint {
        let seat = position(slot, m)
        switch style.layout {
        case .radial:
            let pa = angle(slot, m)
            // `childSpread` is a REQUEST, not a command: it sets the fan, but never
            // tighter than the children can pack without overlapping. It was the
            // last absolute angle in the layout — five children on a 46° spread, or
            // any spread on a small derived ring, used to bury each other silently
            // while the panel still reported a healthy top-level gutter.
            let stepDeg = count > 1
                ? max(style.childSpread / Double(count - 1), m.childMinStepDegrees)
                : 0
            let step = stepDeg * .pi / 180
            let spread = step * Double(count - 1)
            let ca = count > 1
                ? pa - CGFloat(spread / 2) + CGFloat(step * Double(child))
                : pa
            let r = m.ringRadius + m.childGap
            return CGPoint(x: cos(ca) * r, y: sin(ca) * r)
        case .vertical:
            // A ROW heading off the column, on whichever side `childAxis` says.
            let run = m.childGap + CGFloat(child) * m.childSpacing
            return CGPoint(x: childAxis.x * run, y: seat.y)
        case .horizontal:
            // A COLUMN heading off the row, same rule.
            let run = m.childGap + CGFloat(child) * m.childSpacing
            return CGPoint(x: seat.x, y: childAxis.y * run)
        }
    }

    /// How far the pointer has travelled in the direction that opens a sub-menu.
    private func submenuReach(_ p: CGPoint) -> CGFloat {
        switch style.layout {
        case .radial: return hypot(p.x, p.y)
        case .vertical, .horizontal:
            // Travel PROJECTED onto the axis the children come out along, so
            // flipping the side flips the trigger with it — no second sign.
            return p.x * childAxis.x + p.y * childAxis.y
        }
    }

    private func submenuOpen(_ m: RadialMenuMetrics) -> Bool {
        guard let p = activePointer(m) else { return false }
        return submenuReach(p) >= m.submenuThreshold
    }

    /// An arrow normally retires once its children are out. `pinArrows` holds it
    /// so the triangle can be tuned against the sub-menu it points at.
    private func arrowIsLit(_ item: RadialMenuItem, highlighted: Bool,
                            _ m: RadialMenuMetrics) -> Bool {
        if pointer == nil, preview?.pinArrows == true { return true }
        return !showsChildren(of: item, highlighted: highlighted, m)
    }

    /// Children belong to the highlighted item alone — one branch at a time,
    /// which is the only state the menu can actually be in. Two fans at once
    /// would show a collision that cannot happen and hide the one that can.
    private func showsChildren(of item: RadialMenuItem, highlighted: Bool,
                               _ m: RadialMenuMetrics) -> Bool {
        guard !item.children.isEmpty, highlighted else { return false }
        return style.submenuOnHighlight || submenuOpen(m)
    }

    private var highlightedHasChildren: Bool {
        guard let parent = highlight.parent else { return false }
        return !parent.children.isEmpty
    }

    // MARK: highlighting

    private func recomputeHighlight() {
        let m = self.m
        guard isPresented, let p = activePointer(m) else { return clearHighlight() }
        // A hair of epsilon so a dead zone of 0 doesn't light something up before
        // the hand has actually moved at all.
        let travel = hypot(p.x, p.y)
        guard travel >= max(m.deadZone, 0.75) else { return clearHighlight() }

        guard let g = pointedIndex(m), items.indices.contains(g) else { return }
        var next = RadialMenuHighlight(parent: items[g], child: nil)
        if !items[g].children.isEmpty, submenuReach(p) >= m.submenuThreshold {
            next.child = nearestChild(to: p, of: g, at: g, m)
        }
        if next != highlight { highlight = next }
    }

    private func clearHighlight() {
        if highlight != .init() { highlight = .init() }
    }

    private func nearestChild(to p: CGPoint, of global: Int, at slot: Int,
                              _ m: RadialMenuMetrics) -> RadialMenuItem? {
        let kids = items[global].children
        guard !kids.isEmpty else { return nil }
        func pos(_ i: Int) -> CGPoint {
            childPosition(parent: slot, child: i, of: kids.count, m)
        }
        let idx: Int? = switch style.layout {
        case .radial:
            kids.indices.min {
                let pa = atan2(p.y, p.x)
                return angularDistance(pa, atan2(pos($0).y, pos($0).x))
                    < angularDistance(pa, atan2(pos($1).y, pos($1).x))
            }
        // Children run along the OTHER axis, so pick along that axis.
        case .vertical:
            kids.indices.min { abs(p.x - pos($0).x) < abs(p.x - pos($1).x) }
        case .horizontal:
            kids.indices.min { abs(p.y - pos($0).y) < abs(p.y - pos($1).y) }
        }
        return idx.map { kids[$0] }
    }

    private func angularDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d = 2 * .pi - d }
        return d
    }

    // MARK: measurement guides

    /// Draws the two things `gutter` and `ring fit` actually do, so they stop
    /// looking like the same knob.
    ///
    ///   • the dashed circle is the RING the packing solve produced;
    ///   • the bright segment is the GUTTER — the clear space between two icon
    ///     rims, which is the quantity the solve was solving FOR.
    ///
    /// Raise `gutter` and both grow: you asked for more clearance, so the ring
    /// had to move out to provide it. Raise `ring fit` and only the circle grows
    /// — the ring moves out past what the gutter required, and the segment gets
    /// longer as a CONSEQUENCE rather than as the instruction.
    @ViewBuilder
    private func guideLayer(_ m: RadialMenuMetrics) -> some View {
        if preview?.showGuides == true, pointer == nil, m.seats >= 2 {
            let tint = Color.cyan
            let a = m.seatAt(0)
            let b = m.seatAt(1)
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.001)
            let ux = dx / len, uy = dy / len
            // From one rim to the next — this span IS the gutter.
            let from = CGPoint(x: a.x + ux * m.iconSize / 2, y: a.y + uy * m.iconSize / 2)
            let to = CGPoint(x: b.x - ux * m.iconSize / 2, y: b.y - uy * m.iconSize / 2)

            if style.layout == .radial {
                Circle()
                    .strokeBorder(tint.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                    .frame(width: m.ringRadius * 2, height: m.ringRadius * 2)
            }

            // The measured span itself lives in the gap between two icons, so
            // nothing covers it. The NUMBERS are a different matter — see
            // `guideLabels`.
            Segment(from: from, to: to)
                .stroke(tint, lineWidth: 2.5)
        }
    }

    /// The guide READOUTS, drawn last and pushed clear of the icons.
    ///
    /// They used to live in `guideLayer`, which sits under the icons so the
    /// dashed ring can pass behind them. That is right for the ring and wrong
    /// for the text: "ring 105 pt" was offset by `0.42 × icon` from the ring,
    /// which is exactly an icon's radius — so it landed dead center on the top
    /// seat, under the icon, unreadable. Both numbers now clear the rim, and
    /// they draw ON TOP, because a measurement you cannot read is not a
    /// measurement.
    @ViewBuilder
    private func guideLabels(_ m: RadialMenuMetrics) -> some View {
        if preview?.showGuides == true, pointer == nil, m.seats >= 2 {
            let tint = Color.cyan
            let a = m.seatAt(0)
            let b = m.seatAt(1)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            // Half an icon to reach the rim, then half a line of type, then air.
            let clear = m.iconSize * 0.92
            let size = max(m.iconSize * 0.2, 8)

            if style.layout == .radial {
                readout("ring \(Int(m.ringRadius.rounded())) pt", size, tint)
                    .offset(x: 0, y: -m.ringRadius - clear)
            }

            // Straight out from the origin in radial — the direction that gets
            // furthest from both neighbours in the fewest points. In a column or
            // a row the seats are on an axis and "out" is simply sideways.
            let out: CGPoint = {
                switch style.layout {
                case .radial:
                    let r = max(hypot(mid.x, mid.y), 0.001)
                    return CGPoint(x: mid.x / r, y: mid.y / r)
                case .vertical:   return CGPoint(x: 1, y: 0)
                case .horizontal: return CGPoint(x: 0, y: -1)
                }
            }()

            readout("gutter \(Int(m.gutter.rounded())) pt", size, tint)
                .offset(x: mid.x + out.x * clear, y: mid.y + out.y * clear)
        }
    }

    /// A guide number, legible over whatever it lands on.
    private func readout(_ text: String, _ size: CGFloat, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(tint)
            .fixedSize()
            .padding(.horizontal, size * 0.35)
            .padding(.vertical, size * 0.15)
            .background(Capsule().fill(.black.opacity(0.45)))
    }

    /// The root, drawn. Hollow on purpose — it marks a point rather than
    /// occupying it, so the label that lives at the center in radial layouts
    /// still reads through it.
    @ViewBuilder
    private func originLayer(_ m: RadialMenuMetrics) -> some View {
        if style.showOrigin {
            let d = max(m.iconSize * max(style.originScale, 0.02), 3)
            let w = max(m.iconSize * max(style.originLineWidth, 0.002), 0.5)
            Circle()
                .strokeBorder(Color.white.opacity(0.55), lineWidth: w)
                .frame(width: d, height: d)
        }
    }

    // MARK: the visible pointer

    /// Bounded to the widget, as the reviewer put it: an overshooting pointer
    /// slides along the menu's own boundary rather than leaving it.
    /// Where "further buys you nothing" actually starts.
    ///
    /// ⚠️ The guard on the FIRST line is the whole thing, and it took two wrong
    /// fixes to find. `submenuOpen` is a pure DISTANCE test — "has the hand
    /// travelled past the trigger" — and it answers yes on a childless category
    /// exactly as readily as on a parent. So a bound that opened on
    /// `submenuOpen` alone held the dot from the ring out to the trigger and
    /// then released it into open space for no reason at all, on every plain
    /// category in the menu. Which is what "pointer reach does nothing" looked
    /// like from the outside.
    ///
    /// Nothing else in this file has that bug, because every other caller of
    /// `submenuOpen` already sits behind a children check — `showsChildren`
    /// tests the item first, and the sub-menu guide is only drawn for a parent.
    /// This was the one place that asked the distance question on its own.
    ///
    /// With the guard, the rule reads the way it should:
    ///
    ///   • no children under you → the dial, hard, however far you push
    ///   • a parent, not yet open → at least the trigger, so you can GET to them
    ///   • children out → everything, they are what you are reaching for
    private func pointerBound(_ m: RadialMenuMetrics) -> CGSize {
        guard highlightedHasChildren else { return m.pointerReach }
        if submenuOpen(m) { return m.reach }
        let t = m.submenuThreshold
        switch style.layout {
        case .radial:
            return CGSize(width: max(m.pointerReach.width, t),
                          height: max(m.pointerReach.height, t))
        case .vertical:
            // Across is where children open; along the column nothing changes.
            return CGSize(width: max(m.pointerReach.width, t), height: m.pointerReach.height)
        case .horizontal:
            return CGSize(width: m.pointerReach.width, height: max(m.pointerReach.height, t))
        }
    }

    private func clampedPointer(_ p: CGPoint, _ m: RadialMenuMetrics) -> CGPoint {
        let bound = pointerBound(m)
        switch style.layout {
        case .radial:
            let r = hypot(p.x, p.y)
            let maxR = max(bound.width, 1)
            guard r > maxR else { return p }
            return CGPoint(x: p.x / r * maxR, y: p.y / r * maxR)
        case .vertical, .horizontal:
            return CGPoint(x: min(max(p.x, -bound.width), bound.width),
                           y: min(max(p.y, -bound.height), bound.height))
        }
    }

    @ViewBuilder
    private func pointerLayer(_ m: RadialMenuMetrics) -> some View {
        if style.showPointer, let raw = activePointer(m) {
            let p = clampedPointer(raw, m)
            let atLimit = abs(p.x - raw.x) > 0.5 || abs(p.y - raw.y) > 0.5
            let d = max(m.iconSize * max(style.pointerScale, 0.02), 3)
            let tint = Color.white.opacity(style.pointerOpacity)

            if style.showPointerTrail {
                // The spoke. In radial its ANGLE is literally the pick — drawing
                // it turns the one unguessable quantity into something you read.
                Segment(from: .zero, to: p)
                    .stroke(tint.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

            }

            if style.showPointerLeader {
                // The leader: pointer → whatever it currently has. This is the
                // mapping the user was being asked to infer.
                if let lit = highlight.parent.flatMap({ items.firstIndex(of: $0) }) {
                    Segment(from: p, to: iconCenter(lit, m))
                        .stroke(tint.opacity(0.45), lineWidth: 1.5)
                }
            }

            Circle()
                .fill(tint)
                .frame(width: d, height: d)
                // A ring appears once you are against the boundary — "you have
                // gone far enough" was previously invisible.
                .overlay {
                    Circle()
                        .strokeBorder(tint, lineWidth: 1.5)
                        .frame(width: d * 2.1, height: d * 2.1)
                        .opacity(atLimit ? 1 : 0)
                }
                .shadow(radius: 3)
                .offset(x: p.x, y: p.y)
        }
    }

    // MARK: pieces

    /// Radial: the center. Linear: BESIDE the highlighted icon — level with its
    /// row in a column, under its column in a row — but always on the OUTSIDE of
    /// the menu, so it clears both the icons and any open sub-menu.
    ///
    /// It relocates INSTANTLY and only the name changes: the offset is applied
    /// outside the animation scope, and `.animation(nil, value: highlight)` below
    /// guarantees no ambient animation can reach the geometry either.
    @ViewBuilder
    private func label(_ m: RadialMenuMetrics) -> some View {
        let anchor = labelAnchor(m)
        Text(highlight.labelText)
            .font(.system(size: m.labelFontSize, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .shadow(radius: 6)
            .fixedSize()
            .opacity(highlight.action == nil ? 0 : 1)
            // Right-justified in a column so every name ends on the same line;
            // centered under the icon in a row.
            .frame(width: m.labelRunway,
                   alignment: style.layout == .vertical ? .trailing : .center)
            .offset(x: anchor.x, y: anchor.y)
            // ZERO animation on the label. It was the animated
            // TEXT WIDTH — not the offset — that made names bounce inward as they
            // grew and shrank against the right margin. No cross-fade, no content
            // transition, no eased resize: the name is simply swapped. It still
            // fades with the menu itself, since that rides `isPresented`.
            .animation(nil, value: highlight)
    }

    private func labelAnchor(_ m: RadialMenuMetrics) -> CGPoint {
        // The SEAT of the highlighted top-level item, never the child's and never
        // the nudged position: children sit on their parent's row/column anyway,
        // and the nudge must not drag the label with it.
        let seat = highlight.parent
            .flatMap { items.firstIndex(of: $0) }
            .map { position($0, m) } ?? .zero
        switch style.layout {
        case .radial:
            return .zero
        case .vertical:
            // Level with the icon's row, on the side the children are NOT — so
            // it clears the column and the sub-menu row together, whichever way
            // that row is pointing.
            return CGPoint(x: -childAxis.x * (m.iconSize / 2 + m.labelGap + m.labelRunway / 2),
                           y: seat.y)
        case .horizontal:
            // Under the icon's column, opposite the children, same reason.
            return CGPoint(x: seat.x,
                           y: -childAxis.y * (m.iconSize / 2 + m.labelGap + m.iconSize * 0.2))
        }
    }

    /// The dashed "past here you are picking a CHILD" line — what `submenu at`
    /// is. With `submenuOnHighlight` off it is also where they appear at all.
    @ViewBuilder
    private func submenuGuide(_ m: RadialMenuMetrics) -> some View {
        // TWO lines, because they are two different distances and confusing them
        // is easy: the dashed one is the TRIGGER (`submenu at` — how far you
        // travel before children appear), the dotted one is where those children
        // actually LAND (`child gap`). They are independent by design — you
        // usually want the trigger to fire before you reach the children — but
        // drawing only the trigger left the second number to be guessed at.
        let dash = StrokeStyle(lineWidth: 1.5, dash: [5, 6])
        let dot = StrokeStyle(lineWidth: 1, dash: [1.5, 4])
        let tint = Color.white.opacity(submenuOpen(m) ? 0.12 : 0.4)
        let landing = Color.cyan.opacity(submenuOpen(m) ? 0.15 : 0.45)
        let span = m.canvas * 0.55

        switch style.layout {
        case .radial:
            Circle()
                .strokeBorder(tint, style: dash)
                .frame(width: m.submenuThreshold * 2, height: m.submenuThreshold * 2)
            Circle()
                .strokeBorder(landing, style: dot)
                .frame(width: (m.ringRadius + m.childGap) * 2,
                       height: (m.ringRadius + m.childGap) * 2)
        case .vertical:
            Rectangle().fill(tint).frame(width: 1.5, height: span)
                .offset(x: childAxis.x * m.submenuThreshold)
            Rectangle().fill(landing).frame(width: 1, height: span)
                .offset(x: childAxis.x * m.childGap)
        case .horizontal:
            Rectangle().fill(tint).frame(width: span, height: 1.5)
                .offset(y: childAxis.y * m.submenuThreshold)
            Rectangle().fill(landing).frame(width: span, height: 1)
                .offset(y: childAxis.y * m.childGap)
        }
    }

    @ViewBuilder
    private func iconButton(_ item: RadialMenuItem, size: CGFloat, highlighted: Bool,
                            arrow: CGPoint? = nil, arrowLit: Bool = true) -> some View {
        glyph(item.icon, size: size)
            .foregroundStyle(highlighted ? .black : .white)
            .frame(width: size, height: size)
            .background {
                Circle().fill(highlighted ? AnyShapeStyle(.white)
                                          : AnyShapeStyle(.regularMaterial))
            }
            .overlay { Circle().strokeBorder(.white.opacity(highlighted ? 0 : 0.25)) }
            .overlay { submenuArrow(arrow, size: size, lit: arrowLit, highlighted: highlighted) }
            .shadow(radius: highlighted ? 8 : 2)
    }

    /// An SF Symbol scales by font size; a bitmap has to be scaled by frame.
    /// Both end up occupying the same optical area inside the button.
    @ViewBuilder
    private func glyph(_ icon: RadialMenuIcon, size: CGFloat) -> some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.42, weight: .medium))
        case .asset(let name):
            Image(name)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size * 0.5, height: size * 0.5)
        }
    }

    /// Sits just off the icon's rim, rotated to face the way the children grow:
    /// along the spoke in radial, right off a column, up off a row.
    @ViewBuilder
    private func submenuArrow(_ direction: CGPoint?, size: CGFloat,
                              lit: Bool, highlighted: Bool) -> some View {
        if style.showSubmenuArrow, let d = direction {
            let w = size * style.arrowScale
            Triangle()
                .fill(.white.opacity(highlighted ? 1 : 0.6))
                .frame(width: w, height: w * 0.8)
                // The Triangle points UP by default (-y), i.e. -π/2, so rotate by
                // the direction's angle plus a quarter turn.
                .rotationEffect(.radians(atan2(d.y, d.x) + .pi / 2))
                // Stand-off from the icon's rim. Was a hard-coded 0.62 of the
                // arrow's own width; now a knob, and measured against the icon so
                // it does not move when `arrow size` changes.
                .offset(x: d.x * (size / 2 + size * max(style.arrowGapRatio, 0)),
                        y: d.y * (size / 2 + size * max(style.arrowGapRatio, 0)))
                .opacity(lit ? 1 : 0)
                .shadow(radius: 2)
        }
    }
}

/// A line between two points expressed relative to the view's CENTRE, which is
/// the same origin every offset in this file uses.
private struct Segment: Shape {
    var from: CGPoint
    var to: CGPoint
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX + from.x, y: r.midY + from.y))
        p.addLine(to: CGPoint(x: r.midX + to.x, y: r.midY + to.y))
        return p
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Scale FIRST (so the pivot is the icon's own center), then position. Doing it
/// the other way — the built-in `.scale` transition composed onto an already
/// `.offset` view — pivots around the menu's center, because `.offset` never
/// moves the layout frame.
private struct Emerge: ViewModifier {
    var scale: CGFloat
    var position: CGPoint
    var opacity: Double
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(x: position.x, y: position.y)
            .opacity(opacity)
    }
}

/// A child EMERGES from the SELECTED icon's center: it starts on that icon at
/// 70% — no need to start tiny — and eases out to its seat at full size.
/// Absolute positions, because a child carries no base offset of its own.
private extension AnyTransition {
    static func emerging(from parent: CGPoint, to child: CGPoint) -> AnyTransition {
        .modifier(active: Emerge(scale: 0.7, position: parent, opacity: 0),
                  identity: Emerge(scale: 1, position: child, opacity: 1))
    }
}
