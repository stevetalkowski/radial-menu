//
//  RadialMenuApp.swift
//
//  A window containing the tuner, and — on visionOS — an immersive space that
//  draws the same menu in the room. Both read one `MenuModel`, because two
//  scenes cannot share `@State` and a menu that differs between them would be
//  worse than useless for judging it.
//
//  The menu itself is 2D and driven by a single pointer offset, which is what
//  lets one target build for visionOS, macOS, iPadOS and iOS with no
//  per-platform layout code — see Platform.swift for the three things that
//  genuinely do differ.
//

import SwiftUI

@main
struct RadialMenuApp: App {
    /// One source of truth for what the menu IS. Panel state stays in the panel.
    @State private var model = MenuModel()

    #if os(visionOS)
    /// Declared as the existential and bound properly, rather than
    /// `.constant(.mixed)` inline. The inline form may or may not infer
    /// `Binding<any ImmersionStyle>` depending on the toolchain, and this is the
    /// documented spelling — not worth a coin-flip on the one file that only
    /// gets compiled when you build for the headset.
    @State private var immersion: ImmersionStyle = .mixed
    #endif

    /// Named once, used by the scene and by the button that opens it.
    static let spatialSpaceID = "radialmenu.spatial"
    static let volumeID = "radialmenu.volume"

    var body: some Scene {
        WindowGroup {
            TunerView(model: model)
                // Dark, everywhere, regardless of what the machine is set to.
                //
                // Not a taste call. The menu draws white icons, white labels and
                // white guide lines on the assumption of something dark behind
                // them — that is what makes a thin ring legible at arm's length
                // in a headset. Inherit a light system appearance and the stage
                // stays dark while every control around it flips, so the panel
                // ends up dark text on dark chrome. The Mac looked right only
                // because this Mac happens to be set to dark.
                //
                // Scoped to the tuner APP, deliberately. `RadialMenu.swift` sets
                // no colour scheme of its own, so a colleague dropping the
                // component into a light-mode app keeps their own appearance —
                // they just need to put something dark behind it.
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 800)

        #if os(visionOS)
        // A VOLUME: the same menu, in a box you can pick up.
        //
        // The immersive space below has no system chrome by design — no bar, no
        // handle, nothing to take hold of — so repositioning it means going back
        // to the very panel it is floating in front of. A volume is bounded and
        // the system gives it a grab bar for free, which fixes reachability
        // structurally rather than by making the plane smaller and hoping.
        //
        // Both exist because they answer different questions. A volume is the
        // one to demo; the immersive space is the one that can sit at an exact
        // arm's length with nothing around it at all.
        WindowGroup(id: RadialMenuApp.volumeID) {
            SpatialMenuView(model: model, inVolume: true)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.9, height: 0.9, depth: 0.25, in: .meters)

        ImmersiveSpace(id: RadialMenuApp.spatialSpaceID) {
            SpatialMenuView(model: model)
        }
        // Mixed: the point is to see the menu against your actual room, at your
        // actual arm's length. Full immersion would answer a question nobody
        // asked.
        .immersionStyle(selection: $immersion, in: .mixed)
        #endif
    }
}
