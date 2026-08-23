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

    /// Named once, used by the scene and by the button that opens it.
    static let spatialSpaceID = "radialmenu.spatial"

    var body: some Scene {
        WindowGroup {
            TunerView(model: model)
        }
        .defaultSize(width: 1100, height: 800)

        #if os(visionOS)
        ImmersiveSpace(id: RadialMenuApp.spatialSpaceID) {
            SpatialMenuView(model: model)
        }
        // Mixed: the point is to see the menu against your actual room, at your
        // actual arm's length. Full immersion would answer a question nobody
        // asked.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        #endif
    }
}
