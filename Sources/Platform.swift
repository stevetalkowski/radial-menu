//
//  Platform.swift — everything that differs between visionOS, macOS, iPadOS and iOS
//
//  The component (`RadialMenu.swift`) is already platform-agnostic: it has no
//  ARKit, no RealityKit, no hand tracking, and its entire input contract is one
//  `CGPoint` offset per frame. So porting is not a rewrite — it is answering
//  three questions, and all three answers live in this file:
//
//    1. HOW IS IT SUMMONED?  A pinch has no equivalent on a desktop. Each
//       platform gets its own invocation, published through callbacks shaped
//       exactly like `DragGesture`'s, so the host's handler is byte-identical
//       everywhere. On the Mac that means either mouse button — the stage is a
//       sibling of the knob panel now, so a catcher over it cannot reach the
//       sliders, and there is nothing on the stage to select.
//    2. WHERE DO THE KNOBS GO?  340 pt is a comfortable inspector on a Mac and
//       most of an iPhone.
//    3. WHAT DO WE CALL IT?  "Pinch" is wrong on every platform but one.
//
//  Nothing here knows anything about menus. Keep it that way: if a rule needs
//  the menu's geometry, it belongs in the component, not in a platform switch.
//

import SwiftUI

#if canImport(UIKit)
import UIKit          // visionOS and iOS both — UIImage is the symbol lookup
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Which machine are we on

/// Platform as a VALUE, so the rest of the code can branch with `switch` instead
/// of scattering `#if` through view bodies — where the compiler only ever checks
/// the branch it is building and the others rot unnoticed.
enum MenuPlatform {
    case vision, mac, pad, phone

    static var current: MenuPlatform {
        #if os(visionOS)
        return .vision
        #elseif os(macOS)
        return .mac
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? .phone : .pad
        #else
        return .pad
        #endif
    }

    /// How much of the window the knob panel starts with, and how far the divider
    /// can be dragged. Whether that figure is a WIDTH or a HEIGHT depends on
    /// which edge the panel ended up on — see `SplitStage.stacked`.
    /// The headset gets more, and it is the controls that ask for it rather than
    /// the screen offering it: every hit target in a knob row is sized for a
    /// gaze there, and a row of gaze-sized controls leaves a 340 pt panel with
    /// about 80 pt of actual slider. The slider is the instrument. Give it room.
    static var panelSpan: CGFloat {
        switch current {
        case .phone: 300
        case .vision: 430
        case .mac, .pad: 340
        }
    }
    static var panelSpanRange: ClosedRange<CGFloat> {
        current == .phone ? 140...560 : 260...600
    }

    /// Who is ALLOWED to stack the panel under the stage instead of beside it.
    ///
    /// Not "who does" — `SplitStage` decides that per window, from the window's
    /// own shape. A phone is not a vertical split; a phone in PORTRAIT is, and
    /// the same is true of an iPad turned upright.
    ///
    /// The Mac and the headset are excluded on purpose rather than by oversight.
    /// Both are windows you resize by hand, continuously, and a panel that
    /// jumped from the right edge to the bottom as you dragged a corner past
    /// square would be the layout rearranging itself mid-gesture. A tablet has
    /// two orientations and you commit to one; a window has a thousand and you
    /// pass through them on the way somewhere.
    static var panelCanStack: Bool {
        switch current {
        case .phone, .pad: true
        case .mac, .vision: false
        }
    }

    /// How much clear space the knob panel leaves at its trailing edge for the
    /// scroll indicator to live in.
    ///
    /// A fixed 12 pt was fine on a Mac and wrong in a headset, where the bar is
    /// drawn fatter and floats further in — it sat directly on top of the
    /// right-hand VALUES, which are the entire point of those rows. A scroll
    /// indicator overlapping the number you are trying to read is worse than
    /// one you cannot see at all.
    static var scrollGutter: CGFloat {
        switch current {
        case .vision: 30
        case .mac: 14
        case .pad, .phone: 20
        }
    }

    /// The smallest a tappable control may be. Not a style figure — a hit-rate
    /// one.
    ///
    /// A mouse lands on a 20 pt target every time. A gaze does not: it settles
    /// within a couple of degrees and the eye keeps moving, so a control the
    /// size of its own text is something you AIM at rather than simply look at.
    /// The knob-row values were exactly that — a line of type with a tap gesture
    /// on it — and "still hard to pick the number" is what that feels like from
    /// inside a headset.
    static var controlMinHeight: CGFloat {
        switch current {
        case .vision: 40
        case .mac: 22
        case .pad, .phone: 32
        }
    }

    /// The same argument, sideways: how wide an icon-only button has to be.
    static var controlMinWidth: CGFloat {
        switch current {
        case .vision: 30
        case .mac: 18
        case .pad, .phone: 26
        }
    }

    /// Half-width of the divider's invisible grab target. A mouse can hit a
    /// hairline; gaze-and-pinch cannot, and a finger is worse. The divider still
    /// LOOKS 1 pt wide everywhere — only the target grows.
    static var dividerGrab: CGFloat {
        switch current {
        case .mac: 6
        case .vision: 16
        case .pad, .phone: 12
        }
    }

    static var invocationGlyph: String {
        switch current {
        case .vision: "hand.pinch"
        case .mac: "cursorarrow.motionlines"
        case .pad, .phone: "hand.tap"
        }
    }

    /// The line under the glyph on the empty stage. Names the real gesture —
    /// "pinch" on a Mac would just be wrong.
    static func hint(for layout: RadialMenuLayout) -> String {
        let verb: String
        switch current {
        case .vision: verb = "Pinch anywhere, then slide"
        case .mac: verb = "Drag with either mouse button"
        case .pad, .phone: verb = "Touch and drag"
        }
        switch layout {
        case .radial: return "\(verb) toward an icon"
        case .vertical: return "\(verb) up or down the column"
        case .horizontal: return "\(verb) along the row"
        }
    }

    /// The gesture in two words, for sentences rather than headings.
    static var gestureNoun: String {
        switch current {
        case .vision: "pinch"
        case .mac: "drag"
        case .pad, .phone: "touch and drag"
        }
    }

    /// Does this SF Symbol actually exist on this OS?
    ///
    /// Worth checking because a colleague hand-writing a menu WILL get some
    /// names wrong, and a missing symbol renders as nothing at all — a silent
    /// blank circle they will spend twenty minutes blaming on the layout code.
    /// Naming the bad ones costs one lookup each.
    static func symbolExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return true
        #endif
    }

    /// visionOS is the only platform where a hold delay is natural — a pinch has
    /// to be distinguished from a tap. Elsewhere the button IS the intent.
    static var supportsHoldDelay: Bool { current == .vision }
}

// MARK: - Invocation

/// Summon-and-drag, however this platform does it.
///
/// The callbacks deliberately mirror `DragGesture.Value`: a start location and a
/// current location, both in the modified view's coordinate space. A host that
/// already speaks DragGesture swaps one modifier and is done — which is the
/// whole reason the port is cheap.
extension View {
    /// - Parameter enabled: false hands the stage back to whatever is inside it.
    ///   The catcher claims EVERY mouse event over its bounds, which is right
    ///   when the stage is one big button and fatal the moment there is
    ///   something in there to drag. Off, and the modifier stays attached but
    ///   transparent — no `if` around it, so the view keeps its identity and
    ///   toggling modes cannot restart the stage.
    func menuInvocation(
        enabled: Bool = true,
        onChanged: @escaping (_ start: CGPoint, _ current: CGPoint) -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        modifier(MenuInvocation(enabled: enabled, onChanged: onChanged, onEnded: onEnded))
    }
}

struct MenuInvocation: ViewModifier {
    var enabled = true
    let onChanged: (CGPoint, CGPoint) -> Void
    let onEnded: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        // EITHER mouse button drives the finger. Right-drag was chosen first
        // because a left-drag normally means "select" — but the split-view
        // rebuild made the stage a real sibling of the knob panel, so a catcher
        // over the stage can no longer reach the sliders, and there is nothing
        // else on the stage to select. Left is simply the button your hand is
        // already on. Right still works, and matches where Maya and Blender put
        // their marking menus.
        content.overlay(DragCatcher(enabled: enabled, onChanged: onChanged, onEnded: onEnded))
        #else
        // visionOS: the pinch itself. iOS/iPadOS: a finger. Same gesture object,
        // and `minimumDistance: 0` means contact starts it rather than travel.
        // `.subviews` rather than `.none`: disabling this gesture must not also
        // disable the ones BELOW it. That distinction is the whole reason
        // arrange mode's chips are reachable through a stage that is otherwise
        // one enormous drag target.
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in onChanged(v.startLocation, v.location) }
                .onEnded { _ in onEnded() },
            including: enabled ? .all : .subviews
        )
        #endif
    }
}

#if os(macOS)
/// Hide the arrow while the menu draws its own pointer.
///
/// On a Mac the system cursor is VISIBLE, and `pointerGain` means the drawn dot
/// sits at `gain ×` the cursor's offset from the menu's center — so at the
/// shipped 1.35 the two visibly separate, further apart the further you drag.
/// That is control–display gain working exactly as designed, and it looks like a
/// bug, because two pointers that disagree is what a bug looks like. In a
/// headset nobody notices: there is no system cursor to disagree with.
///
/// So: exactly ONE pointer on screen. Hide the arrow while the menu is up and
/// drawing its own; leave it alone when `showPointer` is off, because then the
/// arrow is the only pointer there is.
///
/// `NSCursor.hide()` and `unhide()` are a COUNTER, not a toggle, and this
/// project has already been bitten once by an unbalanced `NSCursor` stack. The
/// flag makes both calls idempotent, so no amount of re-entry can leave the
/// cursor hidden with nothing left to unhide it.
enum SystemCursor {
    private static var hidden = false

    static func hide() {
        guard !hidden else { return }
        hidden = true
        NSCursor.hide()
    }

    static func show() {
        guard hidden else { return }
        hidden = false
        NSCursor.unhide()
    }
}

/// The only AppKit in the project, and it exists for one reason: SwiftUI has no
/// right-button drag gesture, and no way to take one mouse button while leaving
/// another alone. This reports mouse down / dragged / up in `DragGesture`'s
/// shape, for EITHER button.
///
/// ⚠️ The `hitTest` override is the load-bearing part. It claims only the events
/// it actually handles; anything else returns nil and falls straight through to
/// SwiftUI. Option-drag is deliberately excluded and reserved for panning the
/// view — Maya's Alt-drag navigation convention, and the one modifier a 3D
/// artist's hand reaches for without thinking.
struct DragCatcher: NSViewRepresentable {
    var enabled = true
    let onChanged: (CGPoint, CGPoint) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> Catcher {
        let v = Catcher()
        v.enabled = enabled
        v.onChanged = onChanged
        v.onEnded = onEnded
        return v
    }

    func updateNSView(_ v: Catcher, context: Context) {
        v.enabled = enabled
        v.onChanged = onChanged
        v.onEnded = onEnded
    }

    final class Catcher: NSView {
        var enabled = true
        var onChanged: ((CGPoint, CGPoint) -> Void)?
        var onEnded: (() -> Void)?
        private var start: CGPoint?

        /// Match SwiftUI: origin top-left, y increasing downward. Without this
        /// every offset the menu receives is mirrored vertically.
        override var isFlipped: Bool { true }

        /// Summon the menu on the FIRST click into an unfocused window, rather
        /// than spending that click on activating the app.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Nothing at all when disabled, so every event falls through to the
            // SwiftUI views underneath — which is what makes the arrange tray
            // clickable through a catcher that covers the whole stage.
            guard enabled, let e = NSApp.currentEvent else { return nil }
            switch e.type {
            case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
                return self
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
                // Option-left belongs to the view, not the menu.
                return e.modifierFlags.contains(.option) ? nil : self
            default:
                return nil
            }
        }

        /// Suppress the system context menu, or it pops over the radial menu on
        /// the very gesture that summons it.
        override func menu(for event: NSEvent) -> NSMenu? { nil }

        private func local(_ e: NSEvent) -> CGPoint {
            convert(e.locationInWindow, from: nil)
        }

        // Both buttons, one path — the menu has no reason to care which finger
        // you used.
        private func begin(_ e: NSEvent) {
            let p = local(e)
            start = p
            onChanged?(p, p)
        }

        private func move(_ e: NSEvent) {
            guard let s = start else { return }
            onChanged?(s, local(e))
        }

        private func finish() {
            guard start != nil else { return }
            start = nil
            onEnded?()
        }

        override func mouseDown(with e: NSEvent) { begin(e) }
        override func mouseDragged(with e: NSEvent) { move(e) }
        override func mouseUp(with e: NSEvent) { finish() }

        override func rightMouseDown(with e: NSEvent) { begin(e) }
        override func rightMouseDragged(with e: NSEvent) { move(e) }
        override func rightMouseUp(with e: NSEvent) { finish() }
    }
}
#endif

// MARK: - Where the knobs live

/// Stage and knob panel as SIBLINGS, with a divider you can drag.
///
/// This used to be an overlay, and that was a real bug rather than a style
/// choice. An overlay is painted on top of its base, so the stage's
/// `GeometryReader` went on reporting the full window — including the 340 pt the
/// panel was covering. Everything downstream inherited that: the preview centered
/// itself on a rectangle extending under the panel, and `fit` reported 100% for
/// room that was not there. Subtracting the panel width afterwards worked, but
/// it wrote the panel's geometry down in a second place, and second places drift.
///
/// Siblings cannot lie to each other about size. The stage measures exactly what
/// it owns, `fit` is true by construction, and the compensating arithmetic is
/// gone along with the bug.
///
/// The divider is also the fastest responsiveness test in the project: drag it
/// and watch the menu re-fit continuously.
/// A coordinate space that does NOT move when the divider does. File-scope
/// because a generic type cannot hold a static stored property.
private let splitStageSpace = "SplitStage.container"

struct SplitStage<Stage: View, Panel: View>: View {
    private let stage: Stage
    private let panel: Panel

    init(@ViewBuilder stage: () -> Stage, @ViewBuilder panel: () -> Panel) {
        self.stage = stage()
        self.panel = panel()
    }

    /// One span per DIRECTION, because they do not measure the same thing: a
    /// HEIGHT when the panel is underneath, a WIDTH when it is alongside. With a
    /// single number, dragging the panel tall in portrait and then rotating gave
    /// you a panel that wide in landscape — the stage vanished on a gesture the
    /// user never made.
    @State private var alongsideSpan: CGFloat = MenuPlatform.panelSpan
    @State private var underneathSpan: CGFloat = MenuPlatform.panelSpan

    /// Which edge the panel sits on — decided by the shape of the WINDOW, not by
    /// the device the window happens to be on.
    ///
    /// A phone in portrait is 393 x 852, and stacking a 300 pt panel under the
    /// stage still leaves 550 for the menu. Turn it sideways and the same rule
    /// leaves a 90 pt strip: the preview is simply not on screen. Landscape
    /// wants what the Mac has — knobs beside the stage, not beneath it.
    ///
    /// The iPad reads the same way from the other end. It is worked in landscape
    /// most of the time, where a side column is obviously right; stand it up and
    /// the sensible layout is the phone's, for the same reason it is sensible on
    /// the phone. One rule covers both, and it is a rule about the window.
    private func stacked(_ size: CGSize) -> Bool {
        MenuPlatform.panelCanStack && size.height > size.width
    }

    var body: some View {
        GeometryReader { geo in
            let vertical = stacked(geo.size)
            let limit = vertical ? geo.size.height : geo.size.width
            let range = MenuPlatform.panelSpanRange
            // Never let the panel take so much that the stage disappears.
            let ceiling = max(min(range.upperBound, limit - 220), range.lowerBound)
            let span = vertical ? underneathSpan : alongsideSpan
            let resolved = min(max(span, range.lowerBound), ceiling)

            Group {
                if vertical {
                    VStack(spacing: 0) {
                        stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                        divider(limit: limit, vertical: true)
                        panel.frame(height: resolved)
                    }
                } else {
                    HStack(spacing: 0) {
                        stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                        divider(limit: limit, vertical: false)
                        panel.frame(width: resolved)
                    }
                }
            }
            .coordinateSpace(.named(splitStageSpace))
        }
    }

    private func divider(limit: CGFloat, vertical: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
            // A 1 pt line is impossible to grab — least of all through a headset.
            // Pad it out to a ~13 pt target without making it look any thicker.
            .padding(vertical ? Edge.Set.vertical : Edge.Set.horizontal,
                     MenuPlatform.dividerGrab)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(splitStageSpace))
                    .onChanged { v in
                        // ABSOLUTE position in the CONTAINER's space — never
                        // `.translation`.
                        //
                        // The divider is both the view being dragged and the view
                        // the drag moves. A translation is measured against the
                        // gesture's own view, so every frame it was measured from
                        // an origin the previous frame had already shifted: the
                        // divider and the pointer chased each other and the whole
                        // split shivered. Reading the pointer's absolute position
                        // in a container that never moves has no such loop —
                        // the divider simply goes where the cursor is.
                        let s = limit - (vertical ? v.location.y : v.location.x)
                        if vertical { underneathSpan = s } else { alongsideSpan = s }
                    }
                    .onEnded { _ in }
            )
            #if os(macOS)
            // `set()`, NOT `push()`/`pop()`.
            //
            // NSCursor.push maintains a STACK, and SwiftUI re-evaluates this view
            // on every metrics change — so a hover that survives a few redraws
            // pushed repeatedly without matching pops. The stack grew unbounded
            // and the cursor flickered between arrow and resize as frames fought
            // over it, which reads as the pointer twitching on its own. `set()`
            // keeps no stack, so there is nothing to leak and nothing to fight.
            .onHover { inside in
                if inside {
                    (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            #endif
    }
}
