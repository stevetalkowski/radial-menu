//
//  RadialMenuExport.swift — turn a tuned menu into a file someone else can use
//
//  The real output of this app is not the app, it's the NUMBERS: the ratios
//  you arrive at by sliding knobs on device. This turns those into a single
//  drop-in Swift file — the component verbatim, plus the tuning baked in as the
//  default — so a Step Into Vision colleague adds ONE file to their target and
//  has a working, correctly-proportioned menu with no package, no dependency,
//  and nothing to wire up but their own item list.
//
//  Why ratios make this work at all: an exported set of ABSOLUTE points is only
//  correct at the icon size it was tuned at. Ratios travel — the colleague sets
//  `iconSize` to whatever suits their app and every proportion you tuned
//  survives the move.
//
//  Three ways out of the headset, because each one fails differently:
//    • Share…      AirDrop / Messages / Files. Best when the Mac is nearby.
//    • Copy        straight to the pasteboard; lands on the Mac via Universal
//                  Clipboard when Handoff is on.
//    • Documents/  always written, pullable with `devicectl device copy from`
//                  exactly like presets.json. The one that never fails.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum RadialMenuExport {

    // MARK: - Number formatting
    //
    // Generated source a human will read: no `62.000000000000001`, no `0.2960000`.

    static func n(_ v: CGFloat) -> String { n(Double(v)) }

    static func n(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "0" }
        if abs(v.rounded() - v) < 0.0005 { return String(Int(v.rounded())) }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: - The tuned style, as Swift

    /// Emitted as assignments rather than a memberwise initialiser on purpose:
    /// it stays valid if the struct ever gains or loses a field, and it reads
    /// like the knob panel it came from.
    static func styleSource(_ s: RadialMenuStyle, varName: String = "style") -> String {
        var out = "var \(varName) = RadialMenuStyle()\n"
        func put(_ k: String, _ v: String) { out += "\(varName).\(k) = \(v)\n" }

        out += "\n// what it is\n"
        put("layout", ".\(s.layout.rawValue)")
        put("iconSize", n(s.iconSize))

        out += "\n// responsive model\n"
        put("responsive", s.responsive ? "true" : "false")
        put("fitToContainer", s.fitToContainer ? "true" : "false")
        put("gutterRatio", n(s.gutterRatio))
        put("ringSlack", n(s.ringSlack))
        put("nudgeRatio", n(s.nudgeRatio))
        put("nudgeSpread", n(s.nudgeSpread))
        put("childNudgeRatio", n(s.childNudgeRatio))
        put("childrenFlipped", s.childrenFlipped ? "true" : "false")
        put("childGapRatio", n(s.childGapRatio))
        put("labelGapRatio", n(s.labelGapRatio))
        put("deadZoneRatio", n(s.deadZoneRatio))
        put("deadZoneOfRing", n(s.deadZoneOfRing))
        put("submenuReachRatio", n(s.submenuReachRatio))
        put("childIconScale", n(s.childIconScale))
        put("labelFontScale", n(s.labelFontScale))
        put("labelRunwayScale", n(s.labelRunwayScale))

        out += "\n// absolutes — only consulted when responsive == false\n"
        put("ringRadius", n(s.ringRadius))
        put("linearSpacing", n(s.linearSpacing))
        put("nudge", n(s.nudge))
        put("deadZone", n(s.deadZone))
        put("submenuThreshold", n(s.submenuThreshold))
        put("childRingGap", n(s.childRingGap))
        put("labelGap", n(s.labelGap))

        out += "\n// shared\n"
        put("childSpread", n(s.childSpread))
        put("childSpacingScale", n(s.childSpacingScale))
        put("easeFrames", n(s.easeFrames))
        put("arcStartDegrees", n(s.arcStartDegrees))
        put("arcSweepDegrees", n(s.arcSweepDegrees))
        put("appearScale", n(s.appearScale))
        put("showLabel", s.showLabel ? "true" : "false")
        put("showSubmenuGuide", s.showSubmenuGuide ? "true" : "false")
        put("showSubmenuArrow", s.showSubmenuArrow ? "true" : "false")
        put("submenuOnHighlight", s.submenuOnHighlight ? "true" : "false")
        put("arrowScale", n(s.arrowScale))
        put("arrowGapRatio", n(s.arrowGapRatio))
        put("showPointer", s.showPointer ? "true" : "false")
        put("pointerScale", n(s.pointerScale))
        put("showPointerTrail", s.showPointerTrail ? "true" : "false")
        put("showPointerLeader", s.showPointerLeader ? "true" : "false")
        put("pointerOpacity", n(s.pointerOpacity))
        // The component never reads this — the HOST multiplies the offset by it
        // before calling. Exported because a colleague on visionOS needs the
        // number and has no way to derive it.
        put("pointerGain", n(s.pointerGain))
        put("pointerReachRatio", n(s.pointerReachRatio))
        put("showOrigin", s.showOrigin ? "true" : "false")
        put("originScale", n(s.originScale))
        put("originLineWidth", n(s.originLineWidth))
        put("pointerLineWidth", n(s.pointerLineWidth))
        put("depthStep", n(s.depthStep))
        return out
    }

    // MARK: - The item list, as Swift

    static func itemsSource(_ items: [RadialMenuItem], indent: String = "    ") -> String {
        var out = "[\n"
        for item in items {
            out += "\(indent).init(id: \(q(item.id)), icon: \(iconSource(item.icon)), label: \(q(item.label))"
            if item.children.isEmpty {
                out += "),\n"
            } else {
                out += ", children: [\n"
                for kid in item.children {
                    out += "\(indent)\(indent).init(id: \(q(kid.id)), icon: \(iconSource(kid.icon)), label: \(q(kid.label))),\n"
                }
                out += "\(indent)]),\n"
            }
        }
        out += "]"
        return out
    }

    /// `.asset(...)` names art in the RECEIVING app's catalog, so an exported
    /// menu that uses one will draw a placeholder until that colleague adds it.
    /// Emitting the case honestly is better than quietly rewriting it to a
    /// symbol that happens to resolve.
    private static func iconSource(_ icon: RadialMenuIcon) -> String {
        switch icon {
        case .system(let n): ".system(\(q(n)))"
        case .asset(let n):  ".asset(\(q(n)))"
        }
    }

    private static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Whole-file exports

    /// Just the tuning: for someone who already has `RadialMenu.swift`.
    static func configOnly(style: RadialMenuStyle, items: [RadialMenuItem],
                           metrics: RadialMenuMetrics, name: String) -> String {
        header(style: style, metrics: metrics, name: name, standalone: false)
            + "\nimport SwiftUI\n\n"
            + presetExtension(style: style, items: items, name: name)
            + "\n" + usageBlock(name: name)
    }

    /// Everything: the component verbatim plus the tuning. ONE file, no
    /// dependencies, compiles on its own.
    static func standalone(style: RadialMenuStyle, items: [RadialMenuItem],
                           metrics: RadialMenuMetrics, name: String) -> String {
        header(style: style, metrics: metrics, name: name, standalone: true)
            + "\n"
            + RadialMenuSource.component
            + "\n\n// MARK: - Tuned preset (generated)\n\n"
            + presetExtension(style: style, items: items, name: name)
            + "\n" + usageBlock(name: name)
    }

    private static func presetExtension(style: RadialMenuStyle, items: [RadialMenuItem],
                                        name: String) -> String {
        let id = identifier(name)
        var out = "extension RadialMenuStyle {\n"
        out += "    /// Tuned on Apple Vision Pro in RadialMenu.\n"
        out += "    static var \(id): RadialMenuStyle {\n"
        for line in styleSource(style, varName: "s").split(separator: "\n", omittingEmptySubsequences: false) {
            out += line.isEmpty ? "\n" : "        \(line)\n"
        }
        out += "        return s\n    }\n}\n\n"
        out += "extension RadialMenuItem {\n"
        out += "    /// The item list this preset was tuned against — replace with your own.\n"
        out += "    static let \(id)Items: [RadialMenuItem] = "
        out += itemsSource(items, indent: "        ").replacingOccurrences(of: "\n]", with: "\n    ]")
        out += "\n}\n"
        return out
    }

    private static func usageBlock(name: String) -> String {
        let id = identifier(name)
        return """

        // MARK: - Usage
        //
        // The component is a pure READOUT: it never takes input itself. You feed it a
        // pointer offset from the menu's center for as long as the gesture is held,
        // and read `highlight` back when the gesture ends. That one-value contract is
        // what lets the same view sit in a flat window here and in an ImmersiveSpace
        // later — swap the source of the offset, leave the menu alone.
        //
        //  struct MyView: View {
        //      @State private var shown = false
        //      @State private var center: CGPoint = .zero
        //      @State private var pointer: CGPoint?
        //      @State private var highlight = RadialMenuHighlight()
        //
        //      var body: some View {
        //          GeometryReader { geo in
        //              let c = center == .zero
        //                  ? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
        //                  : center
        //              ZStack {
        //                  Color.clear.contentShape(Rectangle())
        //                  RadialMenu(items: RadialMenuItem.\(id)Items,
        //                             style: .\(id),
        //                             pointer: pointer,
        //                             isPresented: shown,
        //                             highlight: $highlight,
        //                             // The menu is CENTRED on `c`, so the room it
        //                             // has is the largest box centered there — twice
        //                             // the distance to the nearest edge. Passing
        //                             // geo.size instead lets a corner gesture draw
        //                             // half the menu off-screen at "fit 100%".
        //                             available: CGSize(
        //                                 width:  max(2 * min(c.x, geo.size.width  - c.x), 1),
        //                                 height: max(2 * min(c.y, geo.size.height - c.y), 1)))
        //                      .position(c)
        //              }
        //              .gesture(
        //                  DragGesture(minimumDistance: 0)
        //                      .onChanged { v in
        //                          if !shown { center = v.startLocation; shown = true }
        //                          pointer = CGPoint(x: v.location.x - center.x,
        //                                            y: v.location.y - center.y)
        //                      }
        //                      .onEnded { _ in
        //                          if let picked = highlight.action { perform(picked) }
        //                          shown = false
        //                          pointer = nil
        //                      }
        //              )
        //          }
        //      }
        //  }
        //
        // RESIZING IT: set `style.iconSize` and stop there. Every other length is a
        // ratio of it, so spacing, the ring radius, the nudge, the sub-menu trigger
        // distance and the label all re-derive together. Passing `available:` adds the
        // second half — the menu shrinks uniformly rather than overflowing a small
        // window. Set `responsive = false` if you need to pin exact point values.

        """
    }

    private static func header(style: RadialMenuStyle, metrics m: RadialMenuMetrics,
                               name: String, standalone: Bool) -> String {
        let title = standalone ? "\(name).swift — drop-in radial / vertical / horizontal menu"
                               : "\(name).swift — tuning for RadialMenu.swift"
        var out = "//\n//  \(title)\n//\n"
        out += "//  Generated by RadialMenu. Tuned on device; every proportion below is a\n"
        out += "//  ratio of `iconSize`, so it survives being resized.\n//\n"
        if standalone {
            out += "//  SELF-CONTAINED: add this one file to your target. No package, no\n"
            out += "//  dependencies, nothing else to import.\n//\n"
            out += "//  ⚠️ It already CONTAINS the component. Do not also add RadialMenu.swift\n"
            out += "//     to the same target — you would get duplicate declarations.\n//\n"
        } else {
            out += "//  Needs `RadialMenu.swift` alongside it.\n//\n"
        }
        out += "//  Layout      \(style.layout.rawValue)\n"
        out += "//  Items       \(m.seats) (all visible — this menu does not scroll)\n"
        if style.layout == .radial {
            out += "//  Arc         \(n(style.arcStartDegrees))° start, \(n(style.arcSweepDegrees))° sweep"
            out += "  →  \(n(m.stepDegrees))° between icons\n"
        }
        out += "//\n//  Resolved at iconSize \(n(style.iconSize)):\n"
        if style.layout == .radial {
            out += "//    ring radius       \(n(m.ringRadius)) pt\n"
        } else {
            out += "//    pitch             \(n(m.pitch)) pt\n"
        }
        out += "//    gutter            \(n(m.gutter)) pt clear between neighbours\n"
        out += "//    nudge             \(n(m.nudge)) pt\n"
        out += "//    sub-menu at       \(n(m.submenuThreshold)) pt of travel\n"
        out += "//    child gap         \(n(m.childGap)) pt\n"
        out += "//    canvas            \(n(m.canvas)) × \(n(m.canvas)) pt\n"
        out += "//\n"
        return out
    }

    /// A leading digit or a space would not survive as a Swift identifier.
    static func identifier(_ name: String) -> String {
        let cleaned = name.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        let parts = String(cleaned).split(separator: " ").map(String.init)
        guard let first = parts.first, !first.isEmpty else { return "tuned" }
        let head = first.prefix(1).lowercased() + String(first.dropFirst())
        let tail = parts.dropFirst().map { word -> String in
            word.prefix(1).uppercased() + String(word.dropFirst())
        }
        let id = head + tail.joined()
        if id.isEmpty { return "tuned" }
        return id.first?.isNumber == true ? "menu" + id : id
    }

    // MARK: - Getting it out of the headset

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Always written, so `devicectl device copy from` can always fetch it.
    @discardableResult
    static func write(_ text: String, filename: String) -> URL? {
        let url = documentsDirectory.appendingPathComponent(filename)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// The one platform-specific line in the whole app — hence the branch, so a
    /// Mac or iPad build of this same target needs no edit.
    static func copyToPasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
