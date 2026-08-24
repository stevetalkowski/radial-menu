//
//  MenuModel.swift — what the menu IS, apart from any one window
//
//  Pulled out of TunerView for one reason: on visionOS the menu can be shown in
//  a pane AND in the room, and two scenes cannot share `@State`. Everything a
//  scene needs to draw the menu, and everything a hand writes back into it,
//  lives here; everything about how the knob PANEL is being operated — which
//  section is open, what is mid-drag, which chip is selected — stays local to
//  the view, because a second scene has no business knowing about it.
//
//  That line is worth holding. It is the same split the component/host boundary
//  makes one level down, and it is why adding a whole new scene needed no
//  changes to RadialMenu.swift at all.
//

import Observation
import SwiftUI

@Observable
final class MenuModel {

    /// The starting set. Written out to the items file on first launch so there
    /// is always something on disk to edit rather than a blank page.
    ///
    /// AUTHORED ORDER, and it stays that way. An earlier round shuffled a parent
    /// up to index 1 so that dropping `icons` to two still left a sub-menu on
    /// screen to tune against — which fixed the tuner by editing the example,
    /// exactly backwards. ARRANGE mode fixed it the right way round: drag any
    /// item onto any seat and the order is yours, so the list a developer ships
    /// is the list they wrote.
    static let defaultItems: [RadialMenuItem] = [
        .init(id: "move", systemImage: "move.3d", label: "Move"),
        .init(id: "rotate", systemImage: "rotate.3d", label: "Rotate"),
        .init(id: "scale", systemImage: "arrow.up.left.and.arrow.down.right", label: "Scale"),
        .init(id: "material", systemImage: "paintpalette", label: "Material", children: [
            .init(id: "mat.clay", systemImage: "circle.fill", label: "Clay"),
            .init(id: "mat.metal", systemImage: "circle.lefthalf.filled", label: "Metal"),
            .init(id: "mat.glass", systemImage: "circle.dotted", label: "Glass"),
        ]),
        .init(id: "subdiv", systemImage: "square.grid.3x3", label: "SubD", children: [
            .init(id: "subd.0", systemImage: "0.circle", label: "Level 0"),
            .init(id: "subd.1", systemImage: "1.circle", label: "Level 1"),
            .init(id: "subd.2", systemImage: "2.circle", label: "Level 2"),
        ]),
        .init(id: "duplicate", systemImage: "plus.square.on.square", label: "Duplicate"),
        .init(id: "lock", systemImage: "lock", label: "Lock"),
        .init(id: "delete", systemImage: "trash", label: "Delete"),
        // Four placeholders that correspond to real modes in Quads, so the
        // example is a plausible menu rather than a bag of verbs. Twelve total —
        // a full clock face, which is also the ceiling.
        .init(id: "gizmo", systemImage: "arrow.up.and.down.and.arrow.left.and.right",
              label: "Gizmo"),
        .init(id: "edit", systemImage: "point.3.connected.trianglepath.dotted",
              label: "Edit"),
        .init(id: "sculpt", systemImage: "hand.draw", label: "Sculpt"),
        .init(id: "wireframe", systemImage: "squareshape.split.3x3", label: "SubD wire"),
    ]

    /// Twelve. A clock face, and about as many directions as a hand can aim at
    /// without looking. The item LIST can be longer — the tray holds all of it —
    /// but only this many ever take seats.
    static let maxIcons = 12

    // MARK: what the menu is

    var layout: RadialMenuLayout = .radial
    var configs: [String: MenuPreset] = MenuModel.factoryConfigs()
    var slots: [String: MenuPreset] = [:]
    var allItems: [RadialMenuItem] = MenuModel.defaultItems

    // MARK: how it is being looked at

    /// Sound on or off.
    ///
    /// Kept in UserDefaults rather than in the presets file, because it is a
    /// property of this MACHINE and not of a menu design. Nobody exporting a
    /// tuned menu means "and it should be silent on your laptop too" — and a
    /// colleague importing that JSON would have no idea why their speakers went
    /// quiet.
    static let sfxKey = "radialmenu.sfx"
    var sfxOn: Bool = (UserDefaults.standard.object(forKey: MenuModel.sfxKey) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(sfxOn, forKey: MenuModel.sfxKey) }
    }

    /// Which cue, and how loud. Same reasoning as `sfxOn`: a property of this
    /// machine and this pair of ears, not of a menu design.
    ///
    /// `thock` is the default, chosen by ear against the alternatives, and that
    /// reverses the first version. The bubbles are the better SOUND and the
    /// worse CUE — full of character, which is exactly what you do not want from
    /// something that fires every time your hand crosses an icon. They are still
    /// option one in the picker.
    ///
    /// Low and short wins for the same reason: it reads as weight rather than as
    /// brightness, and brightness is what fatigues over a long session.
    static let cueKey = "radialmenu.cue"
    static let sfxVolumeKey = "radialmenu.sfx.volume"
    var cue: MenuCue = MenuCue(rawValue: UserDefaults.standard.string(forKey: MenuModel.cueKey) ?? "") ?? .thock {
        didSet { UserDefaults.standard.set(cue.rawValue, forKey: MenuModel.cueKey) }
    }
    var sfxVolume: Double = (UserDefaults.standard.object(forKey: MenuModel.sfxVolumeKey) as? Double) ?? 0.6 {
        didSet { UserDefaults.standard.set(sfxVolume, forKey: MenuModel.sfxVolumeKey) }
    }

    var previewOn = true
    var previewPose = RadialMenuPreview()

    /// What the stage holds still while you turn a knob.
    ///
    /// false = the ORIGIN. Nothing moves, ever — you are adjusting where the
    /// icons sit relative to a fixed point, which is also exactly what a live
    /// gesture does, since there the origin IS your pinch. On an arc that means
    /// the icons sit off to one side, because on an arc they DO.
    ///
    /// true = the ICONS, via `contentCenter`. Uses the stage better: an arc is
    /// pulled back into the middle instead of hanging off a corner. The cost is
    /// that the box being pinned changes SHAPE as you drag `arc sweep` — the
    /// ring radius moves with the step angle — so its center holds while the
    /// icons themselves visibly travel. Which reads as the layout wobbling.
    ///
    /// There is no rule that pins both; they are different points and the
    /// distance between them is what `arc sweep` changes. Hence a switch.
    var centerOnIcons = false


    // MARK: live — written by whichever scene currently has the hand

    var menuShown = false
    var menuCenter: CGPoint = .zero
    var pointer: CGPoint?
    var highlight = RadialMenuHighlight()
    var lastConfirmed = "—"
    /// What the component actually resolved this frame — the panel reads it back
    /// so the ratios never have to be taken on faith. Written by ONE scene at a
    /// time: the pane stops drawing a menu while the spatial view is open,
    /// precisely so two solves cannot fight over this.
    var metrics = RadialMenuMetrics()

    // MARK: notes

    var savedNote = ""
    var itemsNote = ""
    var symbolReport = ""

    // MARK: where it hangs in the room (visionOS)
    //
    // METRES, unlike every other length in this project, because they become a
    // RealityKit transform directly and converting at the slider would only move
    // the confusion somewhere harder to see.
    //
    // Tunable rather than guessed: nobody picks the right arm's length for a
    // headset from a text editor, which is this app's premise applied to itself.

    var spatialOn = false
    /// Draw the edge of the area that catches a pinch, while LIVE.
    ///
    /// On by default, which reverses an earlier call. The original reasoning was
    /// that chrome is the one thing the immersive view exists to remove — true
    /// of decoration, and this is not decoration. Outside that square your gaze
    /// passes straight through to the windows behind, and a boundary you can
    /// only find by noticing where things stop working is a boundary doing its
    /// job badly.
    var spatialShowReach = true
    /// In front of where you were standing when the space opened.
    var spatialDistance: Double = 0.7
    /// Up from the floor. Negative is allowed, because which way is up in an
    /// immersive space is a thing to confirm by dragging, not by assuming.
    var spatialHeight: Double = 1.2
    var spatialScale: Double = 1

    // MARK: derived — the two things any scene needs to draw

    var config: MenuPreset { configs[layout.rawValue] ?? MenuPreset() }

    var style: RadialMenuStyle {
        var s = config.style
        s.layout = layout          // the picker is the single source of truth
        return s
    }

    /// What actually goes on the ring: the first N of the list, capped at a
    /// clock face.
    var visibleItems: [RadialMenuItem] {
        Array(allItems.prefix(max(2, min(config.icons, allItems.count, MenuModel.maxIcons))))
    }

    // MARK: factory tuning

    /// Factory tuning for one layout. The ONLY place that knows it — `reset`
    /// and the initial `configs` both come through here.
    static func factory(for l: RadialMenuLayout) -> MenuPreset {
        var p = MenuPreset()
        switch l {
        case .radial:
            // Nothing to do: `RadialMenuStyle()` IS the radial tuning now. The
            // knobs a colleague gets with no style at all are the ones that came
            // off the headset.
            p.style.layout = .radial
        case .vertical, .horizontal:
            p.style = linearStyle(l)
            p.icons = 6
        }
        return p
    }

    static func factoryConfigs() -> [String: MenuPreset] {
        Dictionary(uniqueKeysWithValues:
            RadialMenuLayout.allCases.map { ($0.rawValue, factory(for: $0)) })
    }

    /// The linear layouts' tuning, written out in full.
    ///
    /// It used to be "the struct defaults, plus three overrides", which worked
    /// only while the struct defaults happened to BE the linear tuning. Once the
    /// component's defaults moved onto the radial tuning from the headset, an
    /// inherited default became exactly the wrong thing to inherit — a column
    /// would have quietly picked up a 0.55 nudge and a 1.66 origin ring that
    /// nobody asked for and nothing on screen explained.
    ///
    /// So it is spelled out. Long, and impossible to change by accident.
    static func linearStyle(_ l: RadialMenuLayout) -> RadialMenuStyle {
        var s = RadialMenuStyle()
        s.layout = l
        // packing — a 0.258 gutter is exactly 78 pt pitch at 62 pt icons
        s.iconSize = 62
        s.gutterRatio = 0.258
        s.ringSlack = 1
        s.ringRadius = 105
        // feedback
        s.nudgeRatio = 0.137
        s.childNudgeRatio = 0.137
        s.pointerGain = 1
        s.pointerScale = 0.18
        s.pointerOpacity = 0.55
        s.showPointer = false
        s.showOrigin = false
        s.originScale = 0.22
        s.originLineWidth = 0.02
        // sub-menus — 1.371 × icon is exactly an 85 pt trigger
        s.submenuReachRatio = 1.371
        s.childGapRatio = 1.032
        s.childIconScale = 0.82
        s.childSpread = 46
        s.arrowGapRatio = 0.124
        // text
        s.labelFontScale = 0.34
        return s
    }
}
