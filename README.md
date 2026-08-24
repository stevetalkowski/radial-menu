# Radial Menu

A tunable radial / vertical / horizontal menu for visionOS, macOS, iPadOS and iOS —
and the app you tune it in.

The component is one Swift file with no dependencies. The app around it lets you
load your **own** menu, adjust how it feels with live sliders, and export the
result as code you can paste into your project.

One target, four platforms, and all four have been run on real hardware rather
than only in a simulator — which is where two of the more interesting bugs in
`DESIGN.md` came from.

> Built as a spike for [Quads](https://sketchbot.studio), shared because the
> hard part — making a radial menu that doesn't feel arbitrary — is the same
> problem for everyone.

---

## Why this exists

Radial menus are easy to draw and hard to get right. Spacing, hit targets, how
far your hand travels before a sub-menu opens — every one of those is a number,
and every number is wrong until you have felt it on a device.

So the geometry here is **parametric**. There is one base unit, `iconSize`, and
one packing rule: neighbouring icons must clear each other by `gutter × iconSize`.
On a ring that is a chord, so the radius falls out of it:

```
R = pitch / (2·sin(step/2))        pitch = iconSize × (1 + gutter)
```

Change the icon size, the item count, or the arc, and the spacing re-solves.
Nothing overlaps because nothing *can* — the constraint is the layout.

That is also what makes the export portable: it ships **ratios**, not points.
A set of absolute values is only correct at the size it was tuned at.

### Icon size is the base unit, so it scales the whole dial

This surprises everyone exactly once. In responsive mode, raising `icon size`
does not grow the icons in place — it grows the **ring** with them, and the
layout scales as a unit. That is not a side effect, it is the constraint being
satisfied: the ring radius is *defined* as the one that keeps `gutter` clear
between icon rims, so bigger icons need a bigger ring or they collide.

If what you want is bigger icons on the **same** ring, that is a different
intent, and it has a different knob — lower the `gutter` and the icons eat the
gap:

| | icon | gutter | ring |
|---|---|---|---|
| start | 75.7 | 0.449 | **116.6** |
| icon +19%, gutter unchanged | 90.0 | 0.449 | 138.7 — the dial grew |
| icon +19%, gutter 0.218 | 90.0 | 0.218 | **116.6** — the ring held |

"Make the menu bigger" and "make the icons fill more of it" are two different
things. Responsive mode is what separates them.

Turn `responsive` **off** and `ringRadius` becomes its own absolute knob again:
the icons then grow on their own centers, the ring stays put, and eventually they
touch. That collision is the bug responsive mode exists to make impossible. The
absolute mode is kept so a hand-placed layout can be pinned exactly, not because
it is the better way to work.

Switch on **measure guides** and drag each knob — the dashed circle is the ring,
the bright segment is the gutter it was solved for.

### It does not scroll, on purpose

Every item a menu has is on screen. Eight is the comfortable number; twelve is
the ceiling, a clock face — about as many directions as a hand can aim at
without looking.

There used to be a window over a longer list, reached by pushing past an end. It
worked, and it was the wrong feature: a radial menu's whole value is **spatial
constancy** — Delete is at 7 o'clock, it is always at 7 o'clock, and your hand
learns that in a week and keeps it for years. A list that slides destroys exactly
that, and turns "flick at the thing" into fishing for the thing to arrive
somewhere you can reach it.

More than twelve actions? That is what sub-menus are for. Depth is free; breadth
is not.

---

## What's in here

| file | what it is |
|---|---|
| `Sources/RadialMenu.swift` | **the component.** Self-contained, no app types, no dependencies. This is the file you take. |
| `Sources/TunerView.swift` | the tuner: gesture host, the knob panel, import/export. |
| `Sources/Platform.swift` | the only per-platform code — how the menu is summoned, where the panel sits. |
| `Sources/RadialMenuExport.swift` | turns a tuning into Swift you can paste. |
| `DESIGN.md` | why everything is the way it is, including the mistakes. Worth reading before changing the layout maths. |

---

## Run it

You need a Mac, **Xcode 26 or later**, and any Apple developer account — a free
one works, the build just expires after seven days.

Minimums are **visionOS 26, iOS 18, macOS 15**. Nothing here needs a newer SDK
than that, and the deployment targets are set low on purpose so you are not
required to be on a beta to build it.

```bash
git clone https://github.com/stevetalkowski/radial-menu.git
cd radial-menu
open RadialMenu.xcodeproj
```

**Set your signing before you build** — this is the one step people miss.
Create `Config/Local.xcconfig`:

```
DEVELOPMENT_TEAM = ABCDE12345
PRODUCT_BUNDLE_IDENTIFIER = com.yourcompany.RadialMenu
```

That file is gitignored, so your Team ID never ends up in a commit — yours or
anyone else's. Find it in Xcode → **Settings → Accounts → Manage Certificates**,
or at [developer.apple.com](https://developer.apple.com) → Membership.

Picking a team in Xcode's **Signing & Capabilities** editor works too, but it
writes the value straight into `project.pbxproj`, where it will turn up in your
next commit.

Pick a destination and run. It builds for **macOS, iPadOS, iOS and visionOS** off
the same target.

There is also a script, if you prefer the terminal:

```bash
cp Config/local.env.example Config/local.env   # once — put your device UDIDs in it

./Tools/build.sh          # macOS, builds and launches
./Tools/build.sh vision   # visionOS  — builds AND installs to the headset
./Tools/build.sh phone    # iOS       — builds AND installs to your iPhone
./Tools/build.sh pad      # iPadOS    — builds AND installs to your iPad
./Tools/build.sh ios      # iPhone simulator   — boots it and launches
./Tools/build.sh ipad     # iPad simulator     — boots it and launches
./Tools/build.sh sim      # visionOS simulator — boots it and launches
```

The simulator targets need no UDID, no cable and no device, so they are the
quickest way to prove the thing compiles and runs for a platform you have not
tried yet. If the runtime for one is not installed, the script says so by name
rather than failing somewhere further down; the simulator it picks can be
overridden per-platform in `local.env`:

```
RADIALMENU_IOS_SIM=iPhone 17 Pro
RADIALMENU_IPAD_SIM=iPad Pro 13-inch (M4)
```

`xcrun simctl list devices available` prints the names that actually exist on
your machine.

Targets compose, and run in the order you name them:

```bash
./Tools/build.sh mac vision   # Mac first — a compile error shows up in seconds
                              # instead of after a device build
./Tools/build.sh all          # every platform you have a UDID for
```

`xcrun devicectl list devices` prints the UDIDs. A device with no UDID in
`local.env` is skipped with a line saying so, rather than failing the run.

### Onto real hardware

Three things have to be true before a phone or an iPad will show up at all, and
the failure mode for each is the same — the device is simply absent from
`devicectl list devices`, with nothing saying why:

1. **Developer Mode is on.** Settings → **Privacy & Security → Developer Mode**,
   then restart the device and unlock it. The toggle does not appear until the
   device has been plugged into a Mac running Xcode at least once.
2. **The Mac is trusted.** Plug in, unlock, tap **Trust** on the prompt.
3. **The device is unlocked** when you build. A locked device pairs but refuses
   the install.

Then, once per device:

```bash
xcrun devicectl list devices        # copy the Identifier column
```

into `Config/local.env`:

```
RADIALMENU_IPHONE=<identifier>
RADIALMENU_IPAD=<identifier>
```

and `./Tools/build.sh phone` or `pad` builds, installs and leaves it on the home
screen. On a free account the app stops launching after seven days — rebuild and
it works again.

**The first build to a device Apple has never seen will fail**, with either
`0xe8008012` at install time or *"isn't registered in your developer account"* at
build time. Neither is a code or config problem: Apple has to be told the device
exists before any profile can include it. Open `RadialMenu.xcodeproj`, pick the
device in the toolbar, hit Run once — Xcode offers a **Register Device** button.
After that, `./Tools/build.sh` works from the terminal forever for that device.

Note the two identifiers are different things and it is genuinely confusing:
`devicectl` reports a UUID, which is what goes in `local.env`; Apple's portal
wants the hardware UDID, which is the one printed in the error.

Once a device has been paired over USB once, installs work **over Wi-Fi** —
same network, device awake and unlocked.

`Config/local.env` is gitignored, like `Config/Local.xcconfig`. Between them,
nothing about your machine — team, bundle id, hardware UDIDs — reaches the repo.

The Mac build is the fastest way to get a feel for it. Resizing the window is
the most direct test of the responsive layout there is.

---

## Using the component in your app

Copy `Sources/RadialMenu.swift` into your target. That's the whole install.

The component is a pure **readout**: it never takes input itself. You feed it a
pointer offset from the menu's center for as long as your gesture is held, and
read `highlight` back when it ends. That one-value contract is why the same view
works off a mouse, a finger and a pinch.

```swift
struct MyView: View {
    @State private var shown = false
    @State private var center: CGPoint = .zero
    @State private var pointer: CGPoint?
    @State private var highlight = RadialMenuHighlight()

    let items: [RadialMenuItem] = [
        .init(id: "move",   systemImage: "move.3d",         label: "Move"),
        .init(id: "subdiv", systemImage: "square.grid.3x3", label: "Subdivide", children: [
            .init(id: "s0", systemImage: "0.circle", label: "Level 0"),
            .init(id: "s1", systemImage: "1.circle", label: "Level 1"),
        ]),
    ]

    var body: some View {
        GeometryReader { geo in
            let c = center == .zero
                ? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                : center

            ZStack {
                Color.clear.contentShape(Rectangle())
                RadialMenu(items: items,
                           style: myTuning,          // exported from the app
                           pointer: pointer,
                           isPresented: shown,
                           highlight: $highlight,
                           // Largest box CENTRED on c — not geo.size, or a menu
                           // near an edge draws half of itself off-screen.
                           available: CGSize(
                               width:  max(2 * min(c.x, geo.size.width  - c.x), 1),
                               height: max(2 * min(c.y, geo.size.height - c.y), 1)))
                    .position(c)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !shown { center = v.startLocation; shown = true }
                        pointer = CGPoint(x: v.location.x - center.x,
                                          y: v.location.y - center.y)
                    }
                    .onEnded { _ in
                        if let picked = highlight.action { perform(picked) }
                        shown = false
                        pointer = nil
                    }
            )
        }
    }
}
```

**To resize it, set `style.iconSize` and stop there.** Every other length is a
ratio of it, so spacing, radius, nudge, sub-menu trigger and label all re-derive
together.

---

## Bring your own menu

Tuning against someone else's placeholder verbs only gets you so far. Write your
real menu as JSON, import it, and tune against your own content:

```json
{
  "version": 1,
  "items": [
    { "id": "subdiv", "icon": "square.grid.3x3", "label": "Subdivide",
      "children": [
        { "id": "s0", "icon": "0.circle", "label": "Level 0" }
      ]
    }
  ]
}
```

`icon` is a bare **SF Symbol** name, or `"asset:MyGlyph"` for art in your own
asset catalog. Array order is menu order, and the first 2–12 go on the ring. See
`Examples/example-menu.json`.

In the app: **export → import…** and pick your file. Tune. Then **export JSON**
to get it back with the tuning inside, or **export Swift** for a drop-in file.
One file in, one file out — no Xcode in the middle.

The app checks every SF Symbol name on import and tells you which ones don't
exist, because a missing symbol draws as *nothing* and looks like a layout bug
rather than a typo.

### …or arrange it by hand

**Arrange categories** is on by default in preview mode, because the list is the
first thing you want to change. Every category appears as a chip across the top
of the stage, and every seat on the ring gets a dashed outline. Drag a chip onto
a seat to put it there; drag a seat back into the strip to take it off the ring.
Categories past `icons` stay in the strip, dimmed — still in your file, just not
in view.

Tap any chip or icon to edit it in the panel: label, SF Symbol (checked as you
type), sub-menu items, add, delete. Everything writes straight back to the items
file, so the JSON you export is what you arranged.

The tray and the ring are two views of **one array**. There is no editor-only
order to get out of step with the one you ship.

---

### …or drag the guides themselves

Turn on **adjust guides** in preview and every adjustable guide is drawn in
orange, including the ones normally switched off. Drag one and the knob behind it
follows:

| grab | writes |
|---|---|
| the ring | `ring fit` |
| the centre circle | `center size` |
| the outer circle | `child gap` |
| an icon's rim | `icon size` |
| the outermost child's rim | `child gap` out, `child spread` sideways — one grab, two knobs |

The inverse problem is smaller than it looks, and for a reason worth stealing:
**a ratio of two things measured the same way carries no units and no scale
factors.** `wanted ÷ current` has `fit` in both terms, so it cancels — and since
each drawn radius is proportional to its field in both responsive and absolute
mode, the same multiplier is correct for a ratio and for a point value alike.
Where the forward formula is one multiply, though, the inverse is one divide and
that is better still: `submenuThreshold` is clamped by a floor, and proportional
maths against a clamped value divides by a number that has stopped telling the
truth.

`submenu at` is drawn in cyan rather than orange and is deliberately **not**
draggable here, which is not an omission. The preview places its pointer at
`1.08 ×` that very distance, so moving the circle moves the pointer with it and
nothing on screen can change. It is a live-mode control; a handle that cannot
demonstrate itself teaches you the app is broken.

Arrange and adjust are mutually exclusive — both want every drag on the stage,
and a mode that guessed which you meant would be wrong often enough to be worse
than a switch.

---

## The knobs that matter most

Everything is live, and the panel prints what each ratio resolves to in points.

| knob | what it does |
|---|---|
| **icon size** | the base unit — the ring is solved from it, so this scales the whole dial |
| **gutter** | required clear space between icon rims. The rule the ring radius is solved from. |
| **hand gain** | control–display gain. How far the pointer moves per unit of hand movement. The one that matters most in a headset. |
| **nudge spread** | how far the highlight's pop-out spreads to neighbours. Above 0 you get continuous feedback *between* icons instead of all-or-nothing. |
| **pick at** | how far out you travel before ANYTHING highlights, as a fraction of the trip to the icons. At 0 the first pixel of movement picks whatever lies along that heading. Start here if the menu feels twitchy. |
| **submenu at** | how far you travel past an item before its children appear |
| **fit to window** | shrink to fit rather than overflow |

Every value can be **typed**, not just dragged: tap the number and a keypad
opens with a real return key. The arrow beside it puts that knob back to what it
shipped as, and is dim when it already is. Both matter more than they sound —
a slider gets you to 0.449 when the value you want is 0.45.

`DESIGN.md` explains the reasoning behind each, and the failures that produced
them.

---

## Sound

A cue fires each time the pick LANDS somewhere new — a category or a child.
Never on the way back out: leaving an icon is not arriving anywhere. There is a
**sound** toggle, a **level** slider and six cues in the panel, and picking one
plays it, because a cue you have to go and trigger to audition is a cue you
compare from memory.

| cue | |
|---|---|
| **bubble** | sampled pops. Most character — and the most of itself you hear on a fast sweep, which is where character turns into noise. |
| **tick** | 14 ms of filtered noise. The least sound that still registers as an event. |
| **click** | a rounder tick, low-passed. Softer edge, more body. |
| **wood** | a damped 880 Hz tap with a noise attack — a physical detent rather than an electronic one. |
| **glass** | a quiet 2.6 kHz tine. Pitched, so a run of them almost plays a scale. |
| **thock** | low and short, and the default. Reads as weight rather than brightness, and brightness is what fatigues. |
| **push** | no attack at all — it eases in. A displacement rather than an impact. |
| **nudge** | 150 Hz, 75 ms. Nearly under the threshold of noticing; more felt than heard. |
| **felt** | a fingertip on cloth. The most physical of the soft set. |

The line between **thock** and **push** is the real one: above it a cue is an
*impact*, below it a *movement*. Every soft cue is the same primitives as the
percussive ones with a single thing changed — a raised-cosine attack over
10–25 ms instead of an instant one. An instant attack IS the click; the ear
hears the edge long before it hears the tone. Ease into it and the identical
frequency stops being a hit and becomes a gesture. That is the whole trick, and
it is one function.

Every cue except **bubble** is **synthesised at launch** from a handful of
numbers — a filter, an envelope and a decay — in about forty lines of
`MenuAudio.swift`. Three reasons, in order of weight:

1. **Licence.** The bubbles are subscription audio, so they are gitignored and a
   clone of this repo has none. A synthesised cue ships in the source and works
   the moment you build.
2. **There is no portable system tick.** macOS has `/System/Library/Sounds`, iOS
   has `AudioServices` ids into `/System/Library/Audio/UISounds`, visionOS has
   its own — different names, different ids, none redistributable, and nothing
   that resolves on all four. A menu that clicks on a Mac and is silent in a
   headset is worse than one that never clicks.
3. It is the argument this whole project makes about layout, applied to sound. A
   tick has a frequency, a decay and an envelope, and those are dials. Sampling
   one freezes an answer that ought to stay adjustable.

Audio lives in `MenuAudio.swift`, never in the component. `RadialMenu.swift`
imports nothing and stays that way: the menu publishes a highlight and the HOST
decides whether that deserves a noise — the same boundary that let the immersive
space be added without touching the component.

**To use your own samples**, drop 16-bit WAVs into `Sources/Sounds/` and pick
**bubble**; every `.wav` found joins the pool. With none there the app runs
silent rather than failing to build, and the panel says so. What was worth
knowing from cutting the originals:

- **Short.** 250 ms including the tail. Crossing several icons layers these, and
  a one-second clip turns that into mud.
- **Matched in loudness, not in peak.** A sharp click and a round tap can share a
  peak and be 10 dB apart to an ear. Level on a short-window (~30 ms) RMS, and
  soft-limit rather than hard-clip what will not fit.
- **Faded at both ends.** 2 ms in, ~60 ms out. A clip that starts or stops on a
  non-zero sample clicks, and that click is the loudest thing in it.

If the cue fires more often than you would like, the knob to reach for is
**pick at** rather than the volume: it is what decides how easily the highlight
moves at all.

---

## See it in the room (visionOS)

Turn on **spatial view** and the same menu is drawn in an immersive space with
no window behind it, at a distance, height and scale you dial from the panel. A
pane gives the menu a frame, a background and a scale that a room will not, so
every judgement you make inside one is partly a judgement about the pane.

The component does not change to do this — it takes a pointer offset and
publishes a highlight, and has no opinion about what is holding it. Only the
host differs.

Only the menu's own footprint catches a pinch, not the whole plane — outside it
your gaze passes through to the windows behind, which is what makes the panel
still reachable while the space is open. **show reach** dashes that edge so you
can see where it is instead of finding it by bumping into it. It tracks the
menu, so it grows and shrinks as you tune.

Input is the ordinary system pinch. Detecting a *different* pinch — middle
finger to thumb, say — is not a gesture the system delivers to apps at all; it
needs ARKit hand tracking, which means an immersive space, an entitlement and an
authorization prompt.

---

## Platforms

| | gesture | panel |
|---|---|---|
| visionOS | pinch and drag | side column |
| macOS | drag with either mouse button | side column, resizable divider |
| iPadOS | touch and drag | side column in landscape, pull-up section in portrait |
| iOS | touch and drag | pull-up section in portrait, side column in landscape |

The panel's edge is chosen from the **window's shape**, not the device. A tablet
or phone held upright puts the knobs underneath; turned sideways it puts them
beside the stage, which is the Mac layout. The Mac and the headset never flip —
their windows are resized by hand and continuously, and a panel that jumped from
the right edge to the bottom as you dragged past square would be the layout
rearranging itself mid-gesture.

---

## Working on it

`.gitignore` keeps every machine-specific thing out of the repo: your Team ID
and bundle id (`Config/Local.xcconfig`), your device UDIDs (`Config/local.env`),
build products, and any menu or presets JSON you pull off a device.

```bash
./Tools/save.sh "what changed"     # stage + commit
./Tools/save.sh "what changed" push
```

`save.sh` refuses to commit if either secret file has become tracked. That is
the one failure this repo cannot take back, and `.gitignore` is a single
`git add -f` away from not covering it.

The bottom of the knob panel prints **when this build was made and which
platform it is running on** — `built 24 Aug 23:41 · iPhone`. With four devices
in the room, a fix that did not install looks exactly like a fix that did not
work, and those are the worst two things to be unable to tell apart.

`Config/local.env` is **sourced by the shell**, so any value containing a space
or a bracket must be quoted:

```
RADIALMENU_IPAD_SIM="iPad Pro 13-inch (M5)"
```

Unquoted, it silently assigns the first word or fails outright, the variable
ends up unset, and `build.sh` falls back to a default — which looks like your
config being ignored rather than broken. `build.sh` now checks and says so.

---

## Contributing

Issues and PRs welcome. If you change the layout maths, read `DESIGN.md` first —
several of the formulas look redundant and are not, and the file records which
ones have already been got wrong once.

## Licence

MIT. Use it in anything, including commercial work. See [LICENSE](LICENSE).
