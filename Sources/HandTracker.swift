//
//  HandTracker.swift — a pinch the system will not tell you about
//
//  visionOS delivers ONE pinch to apps: index finger to thumb, as a tap or a
//  drag. A middle-finger pinch is not a gesture the system recognises, reports,
//  or has any API for. If you want it you read the joints yourself.
//
//  Three things follow, and all three are constraints rather than choices:
//
//  1. HAND TRACKING NEEDS AN IMMERSIVE SPACE. `HandTrackingProvider` returns no
//     data in a window or a volume — the app has to own the space. So this
//     works in `spatial view` and cannot work in `volume window`, and that is
//     not something a better implementation would fix.
//
//  2. IT NEEDS PERMISSION, with a usage string in the Info.plist and a prompt
//     the first time. Declined, everything below stays silent.
//
//  3. THE THRESHOLD IS A GUESS UNTIL YOU MEASURE IT. Hands differ, and "how
//     close is pinched" is not a number anybody can pick from a text editor —
//     which is this project's whole premise applied one level down. So the live
//     distance is published for the panel to draw, and the threshold is a knob.
//

#if os(visionOS)
import ARKit
import Foundation
import simd

@Observable
final class HandTracker {

    struct Hand {
        var tracked = false
        var pinched = false
        /// Midpoint of thumb and middle fingertip, in world space.
        var position: SIMD3<Float> = .zero
        /// Live separation in metres — this is what makes the threshold tunable
        /// instead of guessed.
        var gap: Float = .infinity
    }

    private(set) var left = Hand()
    private(set) var right = Hand()
    private(set) var status = "off"

    /// Metres, and DELIBERATELY two numbers.
    ///
    /// One threshold chatters: fingers rest a hair either side of it and the
    /// menu flickers open and shut several times a second. Closing has to be
    /// tighter than opening — you must commit to start and relax to finish —
    /// which is the same hysteresis a Schmitt trigger uses and for exactly the
    /// same reason.
    var closeAt: Float = 0.025
    var openAt: Float = 0.045

    private var session: ARKitSession?
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    // MARK: lifecycle

    func start() async {
        guard task == nil else { return }
        guard HandTrackingProvider.isSupported else {
            status = "hand tracking is not supported on this device"
            return
        }
        let s = ARKitSession()
        let provider = HandTrackingProvider()
        session = s

        let auth = await s.requestAuthorization(for: [.handTracking])
        guard auth[.handTracking] == .allowed else {
            status = "permission denied — Settings › Privacy › Hand Tracking"
            session = nil
            return
        }
        do {
            try await s.run([provider])
        } catch {
            status = "could not start: \(error.localizedDescription)"
            session = nil
            return
        }
        status = "tracking"
        task = Task { [weak self] in
            for await update in provider.anchorUpdates {
                guard let self else { return }
                self.absorb(update.anchor)
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        session?.stop(); session = nil
        left = Hand(); right = Hand()
        status = "off"
    }

    // MARK: reading a hand

    private func absorb(_ anchor: HandAnchor) {
        var h = anchor.chirality == .left ? left : right
        defer { if anchor.chirality == .left { left = h } else { right = h } }

        guard anchor.isTracked, let sk = anchor.handSkeleton else {
            h.tracked = false
            // NOT `pinched = false`. A hand that leaves the camera's view for
            // two frames mid-gesture would otherwise cancel the menu, which
            // feels like the app dropping your input rather than like tracking.
            return
        }
        h.tracked = true

        let thumb = sk.joint(.thumbTip)
        let middle = sk.joint(.middleFingerTip)
        guard thumb.isTracked, middle.isTracked else { return }

        let a = world(anchor, thumb.anchorFromJointTransform)
        let b = world(anchor, middle.anchorFromJointTransform)
        h.gap = simd_distance(a, b)
        h.position = (a + b) / 2

        // Hysteresis, both directions.
        if h.pinched {
            if h.gap > openAt { h.pinched = false }
        } else {
            if h.gap < closeAt { h.pinched = true }
        }
    }

    private func world(_ anchor: HandAnchor, _ joint: simd_float4x4) -> SIMD3<Float> {
        let m = anchor.originFromAnchorTransform * joint
        return SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }
}
#endif
