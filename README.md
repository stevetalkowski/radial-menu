# Radial Menu

A tunable radial / vertical / horizontal menu for visionOS, macOS, iPadOS and iOS —
and the app you tune it in.

The component is one Swift file with no dependencies. The app around it lets you
load your **own** menu, adjust how it feels with live sliders, and export the
result as code you can paste into your project.

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
the icons then grow on their own centres, the ring stays put, and eventually they
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

You need a Mac, **Xcode 26 or later** (Xcode 27 beta for the visionOS 27 SDK),
and any Apple developer account — a free one works, the build just expires after
seven days.

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
./Tools/build.sh ios      # iPhone simulator
./Tools/build.sh ipad     # iPad simulator
./Tools/build.sh sim      # visionOS simulator
```

Targets compose, and run in the order you name them:

```bash
./Tools/build.sh mac vision   # Mac first — a compile error shows up in seconds
                              # instead of after a device build
./Tools/build.sh all          # every platform you have a UDID for
```

`xcrun devicectl list devices` prints the UDIDs. A device with no UDID in
`local.env` is skipped with a line saying so, rather than failing the run.

`Config/local.env` is gitignored, like `Config/Local.xcconfig`. Between them,
nothing about your machine — team, bundle id, hardware UDIDs — reaches the repo.

The Mac build is the fastest way to get a feel for it. Resizing the window is
the most direct test of the responsive layout there is.

---

## Using the component in your app

Copy `Sources/RadialMenu.swift` into your target. That's the whole install.

The component is a pure **readout**: it never takes input itself. You feed it a
pointer offset from the menu's centre for as long as your gesture is held, and
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

## The knobs that matter most

Everything is live, and the panel prints what each ratio resolves to in points.

| knob | what it does |
|---|---|
| **icon size** | the base unit — the ring is solved from it, so this scales the whole dial |
| **gutter** | required clear space between icon rims. The rule the ring radius is solved from. |
| **hand gain** | control–display gain. How far the pointer moves per unit of hand movement. The one that matters most in a headset. |
| **nudge spread** | how far the highlight's pop-out spreads to neighbours. Above 0 you get continuous feedback *between* icons instead of all-or-nothing. |
| **submenu at** | how far you travel past an item before its children appear |
| **fit to window** | shrink to fit rather than overflow |

`DESIGN.md` explains the reasoning behind each, and the failures that produced
them.

---

## See it in the room (visionOS)

Turn on **spatial view** and the same menu is drawn in an immersive space with
no window behind it, at a distance, height and scale you dial from the panel. A
pane gives the menu a frame, a background and a scale that a room will not, so
every judgement you make inside one is partly a judgement about the pane.

The component does not change to do this — it takes a pointer offset and
publishes a highlight, and has no opinion about what is holding it. Only the
host differs.

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
| iPadOS | touch and drag | side column |
| iOS | touch and drag | pull-up section |

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

---

## Contributing

Issues and PRs welcome. If you change the layout maths, read `DESIGN.md` first —
several of the formulas look redundant and are not, and the file records which
ones have already been got wrong once.

## Licence

MIT. Use it in anything, including commercial work. See [LICENSE](LICENSE).
