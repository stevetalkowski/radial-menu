//
//  MenuAudio.swift — the sound a highlight makes
//
//  DELIBERATELY NOT IN RadialMenu.swift. That file's promise is "one Swift file,
//  no dependencies", and this one imports AVFoundation. A colleague who wants a
//  silent menu should not have to delete an audio engine to get one.
//
//  So the component stays deaf and the HOST listens: the menu publishes a
//  highlight, and whoever owns the menu decides whether that deserves a noise.
//  The same boundary that let the immersive space be added without touching the
//  component at all.
//
//  ── why the cues are SYNTHESISED ─────────────────────────────────────────────
//
//  Everything except `bubbles` is generated at launch from a handful of numbers.
//  Not cleverness for its own sake — three reasons, in order of how much they
//  matter:
//
//  1. LICENCE. The bubbles are subscription audio, so they are gitignored and a
//     clone of this repo has none. A synthesised cue ships in the source, works
//     the moment you build, and nobody has to go asset-hunting to hear the menu.
//  2. There is no portable system tick. macOS has /System/Library/Sounds, iOS
//     has AudioServices ids for /System/Library/Audio/UISounds, visionOS has its
//     own — different names, different ids, none of them redistributable, and
//     nothing that resolves on all four. A menu that clicks on a Mac and is
//     silent in a headset is worse than one that never clicks.
//  3. It is the same argument this whole project makes about layout. A tick has
//     a frequency, a decay and an envelope, and those are dials. Sampling one
//     freezes an answer that ought to stay adjustable.
//
//  Clips are OPTIONAL throughout. No files, no engine, no audio route — the app
//  is silent and keeps working. A missing asset must never be a broken build.
//

import AVFoundation
import Foundation

// MARK: - what it sounds like

enum MenuCue: String, CaseIterable, Identifiable, Codable {
    // Ordered as they are heard: the samples, then the percussive ones, then
    // the soft ones. The break between thock and push is the real line — above
    // it a cue is an IMPACT, below it a MOVEMENT, and which of those a menu
    // should make is a taste question nobody can answer from a text editor.
    case bubbles, tick, click, wood, glass, thock, push, nudge, felt
    var id: String { rawValue }

    var label: String { self == .bubbles ? "bubble" : rawValue }

    /// Soft cues carry no attack transient, so they need a touch more level to
    /// sit at the same apparent distance.
    var targetDB: Double { isSoft ? -22 : -20 }

    var isSoft: Bool {
        switch self {
        case .push, .nudge, .felt: true
        default: false
        }
    }

    var blurb: String {
        switch self {
        case .bubbles: "the sampled pops. Most character, and the most of itself you hear on a fast sweep — which is the one place character turns into noise."
        case .tick:    "14 ms of filtered noise. The least sound that still registers as an event; disappears completely when you are not listening for it."
        case .click:   "a rounder tick, low-passed. Softer edge, slightly more body."
        case .wood:    "a damped 880 Hz tap with a noise attack — a physical detent rather than an electronic one."
        case .glass:   "a quiet 2.6 kHz tine. Pitched, so a run of them sounds almost like a scale."
        case .thock:   "low and short. Reads as weight rather than as brightness; the least fatiguing over a long session."
        case .push:    "no attack at all — it eases in. A displacement rather than an impact, which is what makes it read as soft even though it is louder than the tick."
        case .nudge:   "150 Hz and 75 ms. Nearly under the threshold of noticing; more felt than heard, which on a fast sweep is the whole point."
        case .felt:    "a fingertip on cloth: a little body at 190 Hz under a very dull noise. The most physical of the soft set."
        }
    }
}

// MARK: - the player

@Observable
final class MenuAudio {

    var enabled = true
    var volume: Float = 0.7
    var cue: MenuCue = .thock { didSet { if cue != oldValue { rebuild() } } }

    private var engine: AVAudioEngine?
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [AVAudioPCMBuffer] = []
    private var next = 0
    private var lastClip = -1

    /// How many notes can overlap. A hand sweeping a twelve-item ring crosses
    /// several icons inside one cue's length, and a player node holds one voice
    /// — the next would cut the previous off mid-tick, which is audible as a
    /// stutter rather than as speed. Six is plenty and costs nothing idle.
    private static let voices = 6
    private static let rate = 48000.0

    var isReady: Bool { !buffers.isEmpty }
    var clipCount: Int { buffers.count }
    /// True when `bubbles` was asked for and no .wav files were found.
    var missingClips: Bool { cue == .bubbles && buffers.isEmpty }

    init() { startEngine(); rebuild() }

    // MARK: engine

    private func startEngine() {
        // Built ONCE and left running. Starting an engine costs tens of
        // milliseconds; paying that per tick would put the delay between the
        // highlight and its sound — and late feedback does not read as slow, it
        // reads as a different event.
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)
        else { return }
        let e = AVAudioEngine()
        for _ in 0..<Self.voices {
            let p = AVAudioPlayerNode()
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: fmt)
            players.append(p)
        }
        engine = e
        ensureRunning()
    }

    /// START IT IF IT IS NOT RUNNING, every time we are about to make a noise.
    ///
    /// ⚠️ An `AVAudioEngine` is not something you start once. The system stops
    /// it out from under you — a window closing, the app losing the foreground,
    /// a route change, media services resetting — and none of that arrives
    /// anywhere this class was looking. Starting it in `load()` and trusting it
    /// forever was the bug: on visionOS, closing the window keeps the process
    /// alive and preserves this object, so the app came back with a dead engine
    /// and stayed silent until a force quit built a new one.
    ///
    /// Checking `isRunning` at the point of use costs one boolean per pop and
    /// removes the whole class of "it stopped and nobody noticed". There is no
    /// single notification that covers every case, so this does not try to
    /// enumerate them — it just never assumes.
    private func ensureRunning() {
        guard let e = engine, !e.isRunning else { return }

        #if !os(macOS)
        // `.ambient` and mixing, deliberately: UI feedback should never duck
        // somebody's music or claim the route — and a session that does not
        // claim the route is one the system has far less reason to tear down.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif

        do {
            try e.start()
            // Player nodes stop with the engine and have to be told to play
            // again — a buffer scheduled on a stopped node is dropped in
            // silence, which is the same symptom with a different cause.
            players.forEach { if !$0.isPlaying { $0.play() } }
        } catch {
            // Silent on purpose. No audio route — a simulator being odd about
            // one, a headset mid-handoff — is not a reason for a menu to stop.
        }
    }

    private func rebuild() {
        buffers = cue == .bubbles ? Self.loadClips() : Self.synthesise(cue)
        lastClip = -1
    }

    // MARK: playing

    /// One cue, chosen at random but never the same variant twice running.
    ///
    /// Pure random repeats about one time in N, and a repeat is the one outcome
    /// that gets NOTICED — it stops sounding like a texture and starts sounding
    /// like a sample. Excluding the last one is the cheapest fix, and the reason
    /// this class keeps any state at all.
    func pop() {
        guard enabled, !buffers.isEmpty, engine != nil, !players.isEmpty else { return }
        ensureRunning()
        guard engine?.isRunning == true else { return }
        var i = Int.random(in: 0..<buffers.count)
        if buffers.count > 1 && i == lastClip { i = (i + 1) % buffers.count }
        lastClip = i

        let player = players[next]
        next = (next + 1) % players.count
        // A little level jitter per hit. Identical repeats are what make a cue
        // read as a machine; ±8% is inaudible as a change and audible as life.
        player.volume = max(0, min(volume, 1)) * Float.random(in: 0.92...1.0)
        player.scheduleBuffer(buffers[i], at: nil, options: .interrupts)
    }

    /// For the picker: hear it the moment you choose it.
    func audition() { pop() }

    // MARK: the sampled option

    /// Every `.wav` in `Sounds/`, then any loose `pop-NN.wav` — Xcode's
    /// synchronized groups flatten some layouts and preserve others, and which
    /// one you get is not worth depending on.
    private static func loadClips() -> [AVAudioPCMBuffer] {
        let b = Bundle.main
        var urls = b.urls(forResourcesWithExtension: "wav", subdirectory: "Sounds") ?? []
        if urls.isEmpty {
            urls = (b.urls(forResourcesWithExtension: "wav", subdirectory: nil) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("pop-") }
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let f = try? AVAudioFile(forReading: url),
                  let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                             frameCapacity: AVAudioFrameCount(f.length)),
                  (try? f.read(into: buf)) != nil else { return nil }
            return buf
        }
    }

    // MARK: the synthesised options

    /// Five variants per cue, each with its centre frequency nudged a few
    /// percent. Same reason the bubbles were thirteen files: sameness is what
    /// makes repeated feedback grating, and a couple of percent of pitch is
    /// below the threshold of "that changed" and above the threshold of "that is
    /// a recording".
    private static func synthesise(_ cue: MenuCue) -> [AVAudioPCMBuffer] {
        (0..<5).compactMap { i in
            let detune = 1 + (Double(i) - 2) * 0.03      // -6% … +6%
            return buffer(from: render(cue, detune: detune))
        }
    }

    private static func render(_ cue: MenuCue, detune: Double) -> [Float] {
        switch cue {
        case .bubbles, .tick:
            return level(mix(bandpassNoise(dur: 0.014, f: 3200 * detune, q: 2.2),
                             decay: 0.005, attack: 0.0005), targetDB: cue.targetDB)
        case .click:
            return level(mix(lowpassNoise(dur: 0.035, f: 1300 * detune, q: 0.8),
                             decay: 0.014, attack: 0.0012), targetDB: cue.targetDB)
        case .wood:
            let n = frames(0.060)
            var body = tone(n: n, f: 880 * detune, partial: 2.76, mix: 0.35)
            let attack = envelope(bandpassNoise(dur: 0.060, f: 2400 * detune, q: 1.5),
                                  decay: 0.003, attack: 0.0003)
            body = envelope(body, decay: 0.026, attack: 0.0008)
            for i in 0..<n { body[i] += 0.5 * attack[i] }
            return level(body, targetDB: cue.targetDB)
        case .glass:
            let n = frames(0.140)
            return level(envelope(tone(n: n, f: 2640 * detune, partial: 1.51, mix: 0.3),
                                  decay: 0.055, attack: 0.001), targetDB: cue.targetDB)
        case .thock:
            let n = frames(0.045)
            var body = envelope(tone(n: n, f: 520 * detune, partial: 0, mix: 0),
                                decay: 0.016, attack: 0.0006)
            let thud = envelope(lowpassNoise(dur: 0.045, f: 900 * detune, q: 0.7),
                                decay: 0.005, attack: 0.0003)
            for i in 0..<n { body[i] += 0.35 * thud[i] }
            return level(body, targetDB: cue.targetDB)

        // ── the soft set ────────────────────────────────────────────────────
        //
        // Every one of these is the SAME primitives as above with one thing
        // changed: `softEnvelope` instead of `envelope`. An instant attack IS
        // the click — the ear hears the edge before it hears the tone — so
        // easing in over 10–25 ms turns the identical frequency from an impact
        // into a movement. Nothing else about them is different.
        case .push:
            let n = frames(0.110)
            return level(softEnvelope(tone(n: n, f: 220 * detune, partial: 1.5, mix: 0.25),
                                      attack: 0.014, decay: 0.055), targetDB: cue.targetDB)
        case .nudge:
            let n = frames(0.075)
            return level(softEnvelope(tone(n: n, f: 150 * detune, partial: 0, mix: 0),
                                      attack: 0.010, decay: 0.032), targetDB: cue.targetDB)
        case .felt:
            let n = frames(0.090)
            var body = softEnvelope(tone(n: n, f: 190 * detune, partial: 0, mix: 0),
                                    attack: 0.009, decay: 0.040)
            let cloth = softEnvelope(lowpassNoise(dur: 0.090, f: 300 * detune, q: 0.5),
                                     attack: 0.012, decay: 0.028)
            for i in 0..<n { body[i] += 0.55 * cloth[i] }
            return level(body, targetDB: cue.targetDB)
        }
    }

    // MARK: DSP, such as it is

    private static func frames(_ seconds: Double) -> Int { Int(seconds * rate) }

    private static func tone(n: Int, f: Double, partial: Double, mix: Double) -> [Float] {
        (0..<n).map { i in
            let t = Double(i) / rate
            var v = sin(2 * .pi * f * t)
            if partial > 0 { v += mix * sin(2 * .pi * f * partial * t) }
            return Float(v)
        }
    }

    private static func noise(_ n: Int) -> [Float] {
        // Deterministic per launch is fine and makes the five variants stable.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        return (0..<n).map { _ in
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Float(Double(seed % 20001) / 10000.0 - 1.0)
        }
    }

    /// A textbook biquad. Written out rather than pulled in, because the whole
    /// synth is forty lines and a dependency would be larger than the thing.
    private static func biquad(_ x: [Float], b: (Double, Double, Double),
                               a: (Double, Double, Double)) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let v = Double(x[i])
            let o = b.0 * v + b.1 * x1 + b.2 * x2 - a.1 * y1 - a.2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = o
            y[i] = Float(o)
        }
        return y
    }

    private static func bandpassNoise(dur: Double, f: Double, q: Double) -> [Float] {
        let w = 2 * Double.pi * f / rate, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        return biquad(noise(frames(dur)),
                      b: (al / a0, 0, -al / a0), a: (1, -2 * c / a0, (1 - al) / a0))
    }

    private static func lowpassNoise(dur: Double, f: Double, q: Double) -> [Float] {
        let w = 2 * Double.pi * f / rate, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        let k = (1 - c) / 2
        return biquad(noise(frames(dur)),
                      b: (k / a0, (1 - c) / a0, k / a0), a: (1, -2 * c / a0, (1 - al) / a0))
    }

    private static func envelope(_ x: [Float], decay: Double, attack: Double) -> [Float] {
        var y = x
        let at = max(Int(attack * rate), 1)
        for i in 0..<y.count {
            let t = Double(i) / rate
            var e = exp(-t / decay)
            if i < at { e *= Double(i) / Double(at) }
            y[i] *= Float(e)
        }
        return y
    }

    private static func mix(_ x: [Float], decay: Double, attack: Double) -> [Float] {
        envelope(x, decay: decay, attack: attack)
    }

    /// A RAISED-COSINE attack, and the decay does not begin until it is over.
    ///
    /// This one function is the entire difference between the percussive cues
    /// and the soft ones. A linear ramp still has a corner at each end, and a
    /// corner is broadband — you hear it as an edge even at 10 ms. A half-cosine
    /// has no corner anywhere, so the sound simply arrives.
    private static func softEnvelope(_ x: [Float], attack: Double, decay: Double) -> [Float] {
        var y = x
        let at = max(Int(attack * rate), 1)
        for i in 0..<y.count {
            var e: Double
            if i < at {
                e = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(at))
            } else {
                e = exp(-(Double(i - at) / rate) / decay)
            }
            y[i] *= Float(e)
        }
        return y
    }

    /// Level on a 30 ms sliding RMS, not on peak.
    ///
    /// Learned the hard way cutting the bubbles: a sharp click and a round tap
    /// can share a peak and be 10 dB apart to an ear, because peak is one sample
    /// and hearing is a window. Then a short fade so nothing ends on a non-zero
    /// sample — that click would be the loudest thing in the file.
    private static func level(_ x: [Float], targetDB: Double = -20) -> [Float] {
        var y = x
        let win = min(frames(0.030), y.count)
        var best = 0.0, run = 0.0
        for i in 0..<y.count {
            run += Double(y[i] * y[i])
            if i >= win { run -= Double(y[i - win] * y[i - win]) }
            best = max(best, run / Double(win))
        }
        let g = pow(10, targetDB / 20) / max(sqrt(best), 1e-9)
        let fade = min(frames(0.004), y.count)
        for i in 0..<y.count {
            var v = Double(y[i]) * g
            if i >= y.count - fade {
                v *= Double(y.count - i) / Double(fade)
            }
            y[i] = Float(max(-0.95, min(0.95, v)))
        }
        return y
    }

    private static func buffer(from mono: [Float]) -> AVAudioPCMBuffer? {
        guard !mono.isEmpty,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(mono.count)),
              let ch = buf.floatChannelData
        else { return nil }
        buf.frameLength = AVAudioFrameCount(mono.count)
        for i in 0..<mono.count { ch[0][i] = mono[i]; ch[1][i] = mono[i] }
        return buf
    }
}
