# Design notes

How this menu got the way it is, round by round — including the parts that were
wrong first. Kept because the layout maths has a few formulas that look
redundant and are not, and because most of them were arrived at by getting them
wrong on a device.

If you only want to USE the component, [README.md](README.md) is the front door.
This is the reasoning underneath it.

Written as a working log, so it still refers to the author in the third person
and to numbered rounds of on-device testing. That is the honest shape of it.

---

# RadialMenu — the radial pie menu refinement spike

A **THROWAWAY** prototype, not a product and **not wired into Quads**. Same pattern as
`QuadsVolume` / `MouseProbe`: an isolated place to get an interaction *feeling* right before it
becomes a shared suite module.

From Steve's IDEA (IDEAS.md, 2026-08-09):

> Long pinch pops a radial menu; while held, sliding toward an icon highlights and nudges it;
> a label names the highlighted action; sub-menus slide OUTWARD from their parent icon; release
> confirms; 3–5 frame ease in/out.

## What it is

- Its own app: `RadialMenu.xcodeproj`, bundle `com.sketchbot.RadialMenu`, display name
  **"Radial Menu"**, **violet** icon showing a ring with one dot nudged out — deliberately not
  QuadsVolume's orange, so the two spikes are never confused on the Home View.
- One plain SwiftUI window. No ARKit, no ImmersiveSpace, no entitlements, no persistence.

## The split that matters

| file | role |
|---|---|
| `Sources/RadialMenu.swift` | **the reusable component** — the future `SuiteRadialMenu`. No app types, no gesture code, no Quads imports. |
| `Sources/TunerView.swift` | the throwaway **host**: invocation, pointer source, label, live knobs. |
| `Sources/RadialMenuApp.swift` | the shell. |

The contract is one value: the **host** feeds the component a `pointer` offset (points, relative
to the menu's center) for as long as the pinch is held; the component publishes `highlight`; the
host confirms it on release. That is the whole interface, and it is why the component can move.

## Why a gesture instead of hand tracking

The menu never needs to know *where your hand is in the room* — only **how far it has moved
since the pinch closed**, which a visionOS `DragGesture` reports directly (gaze picks the spot,
the pinch drags). So: no ARKit session, no usage strings, and it runs in the **Simulator**, which
means the feel can be iterated without a device round-trip every time.

When this moves into Quads' mixed `ImmersiveSpace` (where the #115 hold menu lives), the host
swaps the drag translation for a hand-position delta and **the component is untouched**. If the
flat framing turns out to lose something important, re-hosting is the change — not a rewrite.

## Three layouts, one grammar

Picked in the knobs panel. Highlighting, sub-menus, nudge and easing are shared; each layout has
its own placement grammar (Steve's calls, on device):

| layout | shape | label | children |
|---|---|---|---|
| `radial` | ring | at the **center** | fan **outward** past the ring |
| `vertical` | column | **beside the highlighted icon**, right-justified left of the column | **right**, in a row |
| `horizontal` | row | **under the highlighted icon**, below the row | **up**, in a column |

In the linear layouts the label sits level with the icon you're on but stays on the OUTSIDE of
the menu, clearing both the icons and any open sub-menu. In a column every name is
**right-justified** to the same line; in a row it's centered under the icon.

**The label is not animated at all** — no cross-fade, no content transition, no eased resize. It
is simply swapped. (The bounce Steve kept seeing was the animated TEXT WIDTH growing and
shrinking against the right margin, not the offset.) It still fades with the menu itself, which
rides `isPresented`. It shows only the selected item's own name; the parent's is redundant once
you're in a sub-menu.

**Parents announce themselves:** an item with children wears a tiny triangle just off its rim,
pointing the way those children will appear — along the spoke in radial, right off a column, up
off a row. It retires once the sub-menu is out. The nudge leans the same way, so the two agree. A child
**emerges from the selected icon's center**: it starts on that icon at 70% and eases out to its
seat at full size.

**Labels never travel.** The text cross-fades in place at its new spot; position changes are
applied outside the animation on purpose. (Icons still ease — but in place, via the nudge.)

⚠️ Implementation note worth keeping: `.offset` does not move a view's LAYOUT frame, so a scale
applied *outside* an offset pivots around the container's center — which made the children look
like they grew out of the middle of the menu. The `Emerge` transition scales FIRST, then
positions, so the pivot is the icon itself.

**Each layout keeps its OWN tuning.** Switching the picker swaps the whole knob set, so the three
can be compared honestly rather than sharing one compromise.

## Windowing — show 3 or 4 at a time, scroll for the rest

Set `visible` below the item count and the menu becomes a **window over a longer list**. Push the
pinch past either end and the list scrolls under your hand, one item per seat of travel; run back
the way you came and it scrolls back. A **caret** appears at whichever end still has items behind
it — so mid-list you see both and know you can go either way.

For radial, pair it with the **region** picker (`full` / `12–3` / `3–6` / `6–9` / `9–12`), which
just writes `arcStart` / `arcSweep` — both stay hand-tunable for anything off-quadrant. Four icons
in the 9–12 quadrant then scroll *within that quadrant*.

Icons **travel** to their new seats as the list scrolls — an item that survives a scroll keeps its
identity, so its offset animates — and only the one arriving at the far end transitions in, sliding
from the phantom seat just beyond that end.

⚠️ Design notes worth keeping:
- `scroll` is a **pure function of the pointer**, never stored. That's what gives it no feedback
  loop, no rate-limiting, and symmetric reversal.
- Everything inside the component is keyed by **slot**, not item index. Those are different numbers
  the moment a window is in play; mixing them drew the label where the icon wasn't.

## Responsive — one base unit, one packing rule (round 7, 2026-08-22)

Every measurement used to be an independent absolute. Dragging `icon size` from 62 to
100 grew the icons and left the ring at 105, so they overlapped; adding icons to a
quadrant crowded them into each other. Now there is **one base unit — `iconSize` — and
one constraint**, and everything else is a ratio resolved fresh each frame by
`RadialMenuStyle.resolved(...)` into a `RadialMenuMetrics`.

The constraint that does the work: neighbouring icons must sit `iconSize × (1 + gutter)`
apart, center to center. In a row that IS the pitch. On a ring it is a chord, so the
radius falls out of it:

```
chord = 2·R·sin(step/2) ≥ pitch     →     R = pitch / (2·sin(step/2))
```

…and `step` is itself a function of how many icons are on screen and how wide the arc
is. **So icon size, icon count and arc sweep all feed the radius.** Change any one and
the spacing follows — which is the whole ask.

Steve's round-1 numbers are the defaults, exactly: a gutter of **0.296×** gives a
**104.99 pt** ring at 62 pt icons for both 8-on-a-full-ring and 3-visible-on-90°, and
**0.258×** gives the **78 pt** linear pitch. Nothing was re-tuned to make the maths
tidy; the maths was fitted to the tuning.

**Second half — `fit to window`.** The host passes the room it has and the menu shrinks
uniformly rather than overflowing. The room is the largest box *centered on the pinch
point* — twice the distance to the nearest edge — so a corner pinch shrinks the menu
instead of drawing half of it off-screen. Note this scales the **metrics**, not the
view: a `.scaleEffect` would put the drawn geometry and the incoming pointer in
different coordinate spaces and hit-testing would drift off what you can see.

**The panel tells you when it's wrong.** Deriving the geometry is what makes the bad
cases *detectable*, so they are printed rather than left to be discovered: icons
overlapping and by how much, sub-menu icons overlapping, the menu shrunk to fit, a dead
zone larger than the menu, a full ring that can't be windowed, and a list longer than
the pointer can reach.

`responsive` off restores every original absolute slider, untouched.

### What round 7 fixed while it was in there

| | was | now |
|---|---|---|
| full ring + `visible` < icons | 360/(n−1) put the last seat **on top of** the first; only 2 items ever selectable, no scrolling | a closed ring can't scroll, so the window is ignored and the panel says so — window a **region** instead |
| long list on a narrow arc | items past the ±180° wrap were drawn but **unselectable**, silently | wrap band centered on the arc's middle (≈2× the reach), and the panel names the limit |
| `arc sweep` 359.5 | last icon 0.5° from the first — 61 pt of overlap, reported as a healthy 18 pt gutter | slider snaps ≥355 → 360; the gutter now measures the **wrap** pair too |
| 5 children, or a tight `child spread` | children overlapped silently; `childSpread` was the last absolute angle | spread is a *request* — floored at the angle that clears the gutter |
| `hold` > 0 | menu appeared with **nothing highlighted**; releasing read "cancelled" unless you jiggled | pointer samples during the hold are picked up when it appears |
| empty / 1-item list | `items[0]` trapped; a 1-item window drew duplicate `ForEach` ids | draws nothing, cleanly |
| `fit` | a 1 pt container skipped fit entirely and drew full size; no floor at the bottom | guard corrected, floored at 0.25 |

## Feel knobs (all live sliders, bottom-right, `hide`/`knobs` to collapse)

Defaults are **Steve's on-device settings from round 1** (2026-08-09), expressed as
ratios that reproduce them to 0.01 pt.

With `responsive` ON the geometry sliders are **multiples of icon size**, and each row
prints what it currently resolves to in points. With it OFF they are the original
absolute point sliders.

| knob | what it does | responsive default | = at icon 62 |
|---|---|---|---|
| layout | radial / vertical / horizontal | radial | |
| hold | pinch time before the menu appears; 0 = already there | **0 s** | |
| icons | how many items (2–8) | 8 | |
| visible | how many on screen at once; 0 or ≥ `icons` = all | 0 | |
| **responsive** | derive spacing from icon size, count and arc | **on** | |
| **icon size** | the BASE UNIT — everything else follows it | 62 pt | |
| gutter | clear space between icon rims → sets ring radius / pitch | **0.296×** radial, **0.258×** linear | ring **105 pt** / pitch **78 pt** |
| ring fit | multiplier on the tightest packing ring *(radial)* | 1.00× | 105 pt |
| nudge | how far the highlighted icon pops outward | 0.137× | 8.5 pt |
| dead zone | travel below this highlights nothing | 0× | 0 pt |
| submenu at | travel past this opens the children | **0.81×** ring *(radial)*, **1.371×** icon *(linear)* | 85 pt |
| child gap | parent ring/column/row → child group | 1.032× | 64 pt |
| child pitch | child spacing, × top-level pitch *(linear)* | 0.85× | 66 pt |
| child icon | child diameter, × parent diameter | 0.82× | 51 pt |
| label gap | icon → label distance *(linear)* | 0.258× | 16 pt |
| label size | label point size, × icon | 0.34× | 21 pt |
| child spread | angular spread of a sub-menu — a **request**, floored so children never overlap *(radial)* | 46° | ≥22.5° per gap |
| ease frames | show/hide duration in frames @60 Hz | **14** | |
| arc start / sweep | rotate the ring, or narrow it into an arc *(radial)*; snaps ≥355 → 360 | 0° / 360° | |
| region | radial quadrant preset — writes arc start/sweep | full | |
| arrow size | the sub-menu triangle, as a fraction of the icon | 0.20× | |
| **fit to window** | shrink uniformly rather than overflow the space | **on** | |
| label / submenu guide / submenu arrow | show the name / the dashed threshold / the parent triangle | on | |

Under the sliders, a **resolved** readout prints the live ring radius (or pitch), the
step angle, the real edge-to-edge gutter, the icon size, the canvas and the fit
percentage — read back from the component itself, not recomputed in the panel, so the
two can never quietly disagree.

**`submenu at` is drawn, not just numbered.** Whenever a parent icon is highlighted, a dashed
guide shows exactly that distance — a circle in radial, a vertical line right of a column, a
horizontal line above a row. Cross it and the children appear. Turn it off with `submenu guide`
once the number feels right.

`reset <layout>` restores that layout's defaults.

## Four platforms, one target (round 8, 2026-08-22)

The component was already platform-agnostic — no ARKit, no RealityKit, no hand
tracking, and its whole input contract is one `CGPoint` offset per frame. So the port
is not a rewrite; it is answering three questions, and all three answers live in
`Sources/Platform.swift`.

**1. How is it summoned?**

| platform | gesture | why |
|---|---|---|
| visionOS | pinch and drag | unchanged |
| macOS | **right-click and drag** | a left-drag already means "select"; this is also where Maya and Blender put their marking menus |
| iPadOS / iOS | touch and drag | nothing else claims a plain drag on the stage |

SwiftUI has no right-button drag gesture, so `RightDragCatcher` is the one piece of
AppKit in the project. It reports `rightMouseDown/Dragged/Up` in **`DragGesture`'s
exact shape** — a start location and a current location — so the host's handler is
byte-identical on every platform. Its `hitTest` claims *only* right-button events;
returning `self` unconditionally would swallow every left click and the sliders would
go dead.

**2. Where do the knobs go?** Pinned bottom-trailing at 340 pt on visionOS, Mac and
iPad. On iPhone that is most of the screen, so they move into a pull-up sheet with
`presentationBackgroundInteraction(.enabled)` — the stage behind stays live, so a knob
can be dragged and the result tried without dismissing anything.

**3. What do we call it?** "Pinch" is wrong on three of the four. `MenuPlatform.hint(for:)`
names the real gesture and `invocationGlyph` matches it.

`MenuPlatform` is an enum **value**, not a thicket of `#if`, so the compiler checks
every branch on every build instead of letting the ones it isn't compiling rot.

### The build settings that made it multiplatform

`SDKROOT = auto`, `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx xros
xrsimulator"`, `TARGETED_DEVICE_FAMILY = "1,2,7"`, deployment targets iOS 18 / macOS 15
/ visionOS 27, `SUPPORTS_MACCATALYST = NO` (native SwiftUI on the Mac, not Catalyst).
The entitlements file is empty and stays empty — the spike needs no capabilities on any
platform, so dev signing stays trivial.

The visionOS app icon is a layered `.solidimagestack`, which iOS and macOS cannot use.
`AppIconFlat.appiconset` is the two layers composited (violet plate + white ring), with
the macOS ladder inset ~10% and rounded — macOS does not mask icons, so the shape is
the icon's own job. Selected per SDK, so visionOS keeps its parallax icon:

```
ASSETCATALOG_COMPILER_APPICON_NAME = AppIconFlat;
"ASSETCATALOG_COMPILER_APPICON_NAME[sdk=xros*]" = AppIcon;
```

### Building each one

```
RadialMenu/Tools/embed-source.sh
env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project RadialMenu/RadialMenu.xcodeproj -scheme RadialMenu \
  -derivedDataPath RadialMenu/build \
  -destination 'platform=macOS' build            # Mac  — open the .app directly
# -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
# -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'
# -destination 'generic/platform=visionOS'
```

**Why the desktop build may become the primary tuning surface:** sliders are faster with
a mouse, the export lands straight in `~/Library/Containers/.../Documents` instead of
needing `devicectl`, and resizing the window is the fastest possible test of
`fit to window`. The headset then only has to confirm the feel.

## Preview — look at it while you tune it (round 9, 2026-08-22)

The menu used to exist only for as long as a gesture was held, which made tuning a
chicken-and-egg problem: reaching for a slider dismissed the very thing the slider was
changing, so every adjustment was judged against a memory of the last one.

`preview` (top of the panel, **on by default**) pins it open in the middle of the
stage. Every slider now shows its effect the instant you drag it.

| control | what it does |
|---|---|
| **preview** | keep the menu up with no gesture held |
| **depth · menu** | top level only |
| **depth · + submenu** | the highlighted item with its children out |
| **depth · all** | EVERY parent's children at once — the whole tree in one look |
| **on item** | which seat is highlighted, so nudge, label and sub-menu are all visible |

**It is not a mock-up.** The component builds the pose by synthesising a pointer at a
seat's own position — reusing the same `position(_:_:)` that places the icons, never a
second copy of the maths — so a previewed menu goes through the identical pick, nudge,
threshold and label path a real gesture takes. Inverting the pick instead would have
been a second implementation of the layout, and the two would have drifted.

**A live gesture always wins.** `activePointer` prefers a real pointer over the pose,
so previewing never blocks testing: leave it on, tune, and right-drag (or pinch) at any
moment to try it for real. `depth · all` also reverts to normal behaviour mid-gesture,
because a test should behave like the thing being tested.

A preview sits in the MIDDLE, not at the last pinch point — partly so it does not drift
to wherever you last tested, and partly because a menu previewed in a corner would be
shrunk by fit-to-container and misrepresent the tuning.

## Presets — three slots per layout, readable on the Mac

`save 1|2|3` stores the current tuning for the current layout; `load 1|2|3` brings it back.
Everything — the three saved slots **and** the live tuning of all three layouts — is written to
`Documents/radialmenu-presets.json` (debounced 0.4 s). Pull it:

```
xcrun devicectl device copy from --device <YOUR-DEVICE-UDID> \
  --source Documents/radialmenu-presets.json --domain-type appDataContainer \
  --domain-identifier com.sketchbot.RadialMenu \
  --destination RadialMenu/presets.json
```

`current` holds what each layout is dialled to right now; `slots` holds the saved variants keyed
`radial.1` … `horizontal.3`. The file is also read back at launch, so tuning survives relaunches.

**Note on dead zone 0:** the component still ignores the first ~0.75 pt of travel, so nothing
lights up before the hand has actually moved — otherwise `atan2(0, 0)` would arbitrarily
highlight whatever sits at 0°.

## Export — hand it to someone

`export` in the knobs panel turns the current tuning into Swift. Two kinds:

- **standalone** — ONE file: the component verbatim plus the tuning baked in as
  `RadialMenuStyle.<name>`. A colleague adds that single file to their target and has a
  working menu. No package, no dependency, nothing to import. (It already contains the
  component — do not also add `RadialMenu.swift` to the same target.)
- **config only** — just the tuned preset, for someone who already has the component.

Each export goes three ways at once, because each fails differently: **Share…**
(AirDrop / Messages / Files), the **clipboard** (lands on the Mac via Universal
Clipboard), and always a write to `Documents/<name>.swift`, pullable exactly like the
presets:

```
xcrun devicectl device copy from --device <YOUR-DEVICE-UDID> \
  --source Documents/RadialMenuKit.swift --domain-type appDataContainer \
  --domain-identifier com.sketchbot.RadialMenu \
  --destination ./RadialMenuKit.swift
```

The generated header records the layout, the item count, the arc, and the points every
ratio resolved to — so the file explains itself six months later.

**This is why the ratios matter.** An export of absolute points is only correct at the
icon size it was tuned at. Ratios travel: a colleague sets `iconSize` and every
proportion Steve tuned survives the move.

> ⚠️ The standalone export needs `Sources/RadialMenuSource.swift`, a generated verbatim
> copy of the component. `Tools/embed-source.sh` writes it, and the build command below
> runs it first so the copy cannot drift.

## Build / deploy (wired link)

```
RadialMenu/Tools/embed-source.sh
env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project RadialMenu/RadialMenu.xcodeproj -scheme RadialMenu \
  -destination 'generic/platform=visionOS' -derivedDataPath RadialMenu/build build
xcrun devicectl device install app --device <YOUR-DEVICE-UDID> \
  RadialMenu/build/Build/Products/Debug-xros/RadialMenu.app
```

Simulator (faster for feel work): swap the destination for
`'platform=visionOS Simulator,id=<YOUR-SIMULATOR-ID>'`.

Never launch with `--console` (CLAUDE.md: it ties the app's life to the Mac process).

## What to look for

1. Pinch anywhere on the panel → the menu eases in **exactly where you pinched**, and stays
   there. It must never slide in from the middle of the window.
2. **Slide** toward an icon → it highlights *and nudges outward*; slide across → the highlight
   follows, no re-pinch needed.
3. The **label** names the item under the pointer — just its own name, in one fixed spot that
   never moves. The upper-left corner is only the "last confirmed" receipt.
4. Slide **further out** on Material or SubD → its children slide out from it and become
   selectable.
5. **Release** → confirms (shown as "last confirmed"), menu eases away.
6. With `dead zone` above 0, releasing inside it cancels.

### Round 7 — responsive. Exact expected values, so nothing is a judgement call.

Start on **radial**, `responsive` on, `icons 8`, `region full`, `icon size 62`.

7. The **resolved** readout under the sliders reads `ring 105 pt · step 45.0° ·
   gutter 18 pt`. That is the round-1 tuning, reproduced by the ratios rather than
   stored — if it says anything else, the packing formula is wrong.
8. Drag **icon size** 62 → 124. Every icon doubles AND the ring goes 105 → **210 pt**;
   the gutter readout stays **18 → 37 pt** (it scales too) and the icons never touch.
   The old build kept the ring at 105 and the icons ran into each other — that is the
   before/after in one gesture.
9. Drag **icons** 8 → 4 → 12 on a full ring. The ring goes **105 → 57 → 155 pt**, the
   step goes **45° → 90° → 30°**, and the gap between neighbours stays visually
   constant. Nothing overlaps at any point in the drag.
10. Set **region 9–12** and drag **icons** up. The ring grows fast (4 icons in a
    quadrant needs **155 pt**, 6 needs **257 pt**) and then `fit` drops below 100% and
    the whole menu shrinks to stay in the window — the readout turns orange and says so.
11. **Pinch in a corner** of the stage. The menu still appears exactly under your pinch,
    but smaller — `fit` reads well under 100%. Nothing is clipped by the window edge.
    (Before, it read `fit 100%` and drew icons off-screen that were still selectable.)
12. Set **visible 3** on a full ring. The panel says *"a full ring can't scroll —
    showing all 8. Pick a region to window it."* and draws all 8. Now set **region
    9–12**: windowing works, 3 seats, carets at the ends, and scrolling behaves.
13. Set **icons 8, region 9–12, visible 3**. The panel warns *"only the first 6 of 8 can
    be reached"*. Raise **visible** to 4 and the warning clears — 8 of 8 reachable.
14. **Sub-menus:** slide out to Material with **child spread** dragged down to 10°. The
    three children stay **~15 pt apart** instead of collapsing into each other — the
    spread is floored at the angle that clears the gutter.
15. Set **hold** to 0.6 s, pinch, slide onto an icon and **hold still**. The menu
    appears with that icon already highlighted and named. (It used to appear blank and
    release as "cancelled" unless you jiggled.)
16. Switch to **vertical**. Readout reads `pitch 78 pt · gutter 16 pt` — round-1
    linear tuning, again reproduced from ratios.
17. **Export:** type a name, tap `export`. The green note reports the file and its size,
    a `share` button appears, and `Documents/<name>.swift` is written. The generated
    header should state `ring radius 105 pt` and `gutter 18.36 pt`.
18. **Old presets survive.** Your existing `radialmenu-presets.json` (round 6) loads and
    looks *identical* — the ratios are back-solved from its absolutes against each
    entry's own item count. A green note says `upgraded round-1 presets`.

## Arrange — edit the list where you can see it (round 10, 2026-08-23)

The tell that something was wrong: the default item list had a parent shuffled to
index 1, with a comment explaining that `icons` shows the first N items, so a
parent at index 3 vanishes the moment you drop to three icons — taking every
sub-menu knob with it.

That comment was true, and the fix was backwards. The tuner had been repaired by
editing the example. Anyone importing their own menu got the original problem
back on the first launch, and the order this repo ships stopped being an order
anyone would actually write.

The first attempt at a real fix was a second slider — "which region of the list
does preview show". It works, and it is one more knob to explain, and it still
leaves reordering as a JSON-and-relaunch job. Steve's answer was better: make the
list itself something you can pick up.

**The strip is the array.** Every item is a chip across the top of the stage, in
authored order. Every seat on the ring is a dashed outline. A drag is a `move`
within one array, wherever it starts and wherever it ends:

- chip → seat: put it there, on the ring
- seat → strip: take it off the ring
- chip → chip: reorder

`source` and `target` are both indices into the full list, never into the window.
That is the whole design. The alternative — a separate editor order reconciled
against the menu order — is two things that have to agree, which is the shape of
every layout bug in this file.

### What it took

- **The dashed seats are drawn by the HOST.** `RadialMenu.swift` is the file
  colleagues paste into their own projects; it has no business knowing an editor
  exists. It already publishes `RadialMenuMetrics`, and `seat(_:)` lives there
  rather than on the view precisely so a host can ask where things are. The
  outlines come from the same function the icons do, so an outline cannot be a
  pixel off the thing it is a target for.

- **The tray is a real strip, not an overlay.** Same lesson `SplitStage` taught:
  reserve the height in `stage`, and the menu centers in what is left. `104` is
  written once and consumed by both the layout and the drop test.

- **`menuInvocation(enabled:)`.** On macOS the invocation gesture is an AppKit
  overlay whose `hitTest` claims every mouse event over the stage. Fine when the
  stage is one big button; fatal the moment there is something inside it to drag.
  It was already a no-op in preview — the handler returned immediately — so
  turning it off there costs nothing and is what makes the chips clickable. The
  non-Mac path uses `including: .subviews` rather than `.none`, so disabling this
  gesture does not disable the ones below it.

- **No ScrollView in the tray.** A scroll view would fight every drag for
  ownership on touch, and its content offset would have to be tracked to know
  which chip a drop landed on. The chips are placed from one pitch instead, so
  they shrink to fit and `trayIndex(atX:)` is the exact inverse of `trayX(_:)`
  rather than an approximation of it.

- **`contentSignature` in the component.** `RadialMenuItem ==` compares ids only,
  deliberately — that is what lets an item survive a scroll and *travel* to its
  new seat instead of being replaced. Which means renaming one changes nothing
  the view can see. The icons redraw regardless (they read `items` directly), but
  `highlight` is a published *copy*, so it went on reporting the old label until
  something unrelated forced a re-pick. Any host with live item data hits this;
  the item editor hits it every keystroke.

Move, not swap, on a drop. Swap keeps two items in view and silently reverses a
third, which is never what the hand meant.

### And two things the first version got wrong

The strip started at the top of the stage — where the status lines already live,
so it sat on top of them. `trayTop` reserves the space above it, and the total
`trayReserve` is the ONE number the layout, the drop test and the menu's
remaining room all read.

The measure guides were drawn under the icons, which is right for the dashed ring
(it should pass behind them) and wrong for the numbers. `ring 105 pt` was offset
from the ring by `0.42 × icon` — exactly an icon's radius — so it landed dead
center on the top seat and could not be read at all. The readouts are now their
own layer, drawn last, pushed a full icon clear of the rim, and set on a dark
capsule so they stay legible over whatever they land on.

### What to look for

1. Preview → **arrange items**. Eight chips across the top, eight dashed rings on
   the ring itself, the menu still live underneath and still centered.
2. Drag **SubD** onto the top seat. It goes there; everything between shifts by
   one. `radialmenu-items.json` is rewritten 400 ms later.
3. Drop **icons** to 3. Three seats, three outlines, five chips dimmed in the
   tray — still in the file, just off the ring. Drag one of the dim ones onto a
   seat and it swaps into view.
4. Tap a chip, rename it. The label under the ring's highlight updates *live* —
   that is `contentSignature` doing its job.
5. Type a symbol name that does not exist. The tick turns into an orange warning
   as you type, before the whole-list report at the bottom of the panel agrees.
6. Switch to **live**. The tray goes away, the invocation gesture comes back, and
   the menu behaves exactly as before.
7. **macOS specifically**: with arrange on, the mouse must be able to press a
   chip. If drags land on the menu instead, `menuInvocation(enabled:)` regressed.

## The defaults are a real tuning now (round 11, 2026-08-23)

Every stored default in `RadialMenuStyle` used to be a plausible-looking round
number. They are now the radial tuning that came off the headset — 75.6715 pt
icons, a 0.4492 gutter, a 0.5467 nudge, a 1.657 origin ring. Drop the file into
a project, write `RadialMenu(items:pointer:isPresented:highlight:)` with no
style at all, and that is what you get.

Two things had to move for that to be safe.

**The linear layouts stopped inheriting.** Vertical and horizontal were "the
struct defaults, plus three overrides", which was fine only while the struct
defaults happened to be the linear tuning too. The moment radial's numbers moved
in, a column would have quietly picked up a 0.55 nudge, a 1.66 origin ring and a
3.6× scroll boost that nobody asked for and nothing on screen explained. So
`linearStyle(_:)` writes all twenty of them out. Long, and impossible to change
by accident.

**`configs` and `reset` finally share one source.** The initial `configs`
dictionary had its own literals while sitting next to a `freshPreset` documented
as "one place that knows a layout's factory tuning, so `reset` and the initial
`configs` can never drift apart". They agreed by luck. Both now come through
`factory(for:)`.

One value did NOT come across: `windowSize`. Five seats is a view setting rather
than a look — inert on the full ring the component defaults to, and a surprise
to anyone who then switches to an arc. It lives in the tuner's radial preset
instead, where it was set.

### Child nudge

The sub-menu was the one place in the menu where the only confirmation you had
picked something was the label text. The parent popped; the children never did.

`childNudgeRatio` is measured against `childIconSize`, not the parent's icon — a
nudge that reads right on a 76 pt parent is a shove on a 54 pt child. Sharing
the ratio and differing the base is what makes both look the same.

Outward, for a child, is along its OWN radius rather than its parent's. On a wide
fan those differ by half the spread, and using the parent's direction slides the
outer children sideways instead of out.

It goes into the position the transition resolves to rather than onto an
`.offset` outside it — same reason the base position does. An offset applied
outside the transition's scale pivots the animation on the menu's center, and the
child appears to grow out of the middle instead of out of its parent.

## The origin ring outgrew the centering rule (round 12, 2026-08-23)

`contentCenter` was the fix for arcs swinging across the stage: center the menu
on the middle of its SEATS rather than on its origin, because on a quadrant the
origin sits in empty space off to one side of the icons.

That was right when the origin was a dot. It is not right now. At the tuning
that came off the headset, `originScale` is 1.66 — a 125 pt ring with the menu's
label inside it, and on a quarter-arc it is the one thing that is NOT in the arc.
Pinning the seats therefore pinned the arc beautifully and swung the ring, and
the label with it, most of a ring radius off the anchor. Dragging **arc sweep**
looked like the whole hierarchy sliding away.

So the rule is now the union of the seat discs and the origin disc, and the icon
radius is finally in the arithmetic — it used to be left out on the grounds that
a symmetric radius cancels, which is true right up until you mix in a second
element with a different radius.

Two things stay out, both for the same reason: they change. Children appear and
disappear, so including them would shift the layout every time a sub-menu opened
— the original note about that still stands. The label's width changes with the
highlighted item's name, so including it would make the menu breathe as you slid
along the ring.

## Mode switching where the mode is (round 12)

The preview/live picker lived at the top of the knob panel, which meant switching
modes was a scroll to the top, a tap, and a scroll back to wherever you were. It
is now also a strip along the bottom of the stage.

A VStack sibling, not an overlay, and that is load-bearing on macOS. The
invocation gesture there is an AppKit view covering the whole field, and in LIVE
mode — the exact mode you need this button in — it claims every mouse event over
its bounds. A sibling strip is simply not inside it. The alternative was teaching
`DragCatcher` a rectangle to ignore, which is the button's geometry written down
in a second place, and second places drift.

## One child axis (round 13, 2026-08-23)

Two observations from a headset, both about the linear layouts, and both really
the same observation.

**A sub-menu should be able to hang either way.** A row's children went UP and a
column's went RIGHT, permanently, because those directions were literals in
`outward()`. `childrenFlipped` is now one flag, and everything with a side reads
one vector, `childAxis`: where the children land, which way the parent leans,
which way its arrow points, which direction of travel opens the sub-menu, where
the trigger and landing guides are drawn, and which side the label retreats to so
it stays clear of them. The trigger is the nicest of these — it used to be
`case .vertical: p.x` and is now the pointer projected onto `childAxis`, so
flipping the side flips the trigger with it and there is no second sign anywhere
that can fall out of step.

**A child pops ACROSS the run, never along it.** The child nudge shipped using
the parent's outward direction, which in a linear layout points along the run the
children are laid out in — so a highlighted child shoved itself straight at its
own neighbour, opening a gap on one side by closing it on the other. The gap it
was supposed to be making never appeared. Perpendicular, it steps out of the line
entirely and separates from every sibling at once. A column's children pop right;
a row's pop up.

Radial had this right from the start without anyone deciding it: the fan is an
arc, so "outward" is already at right angles to the run. The linear layouts were
the case where the two directions happened to coincide in the code and not in the
geometry.

`childNudgeAxis` deliberately does NOT flip with `childrenFlipped`. Up and right
are the directions a reader's eye treats as forward, and a sub-menu that pops
downward because it happens to hang below the row is simply harder to read.

## Dial — a second way to drive it (round 14, 2026-08-23)

Steve, from a headset: *"there's still a full disconnect in how you actually
select and dive into that category, because you are pinching moving away from
it."*

He was describing a structural fault, not a tuning problem. The menu is
ABSOLUTE POINTING: the pointer's position is the selection. That works while
everything is on screen. Windowing bolted a second, incompatible gesture onto
it — push past the last icon to scroll — which is a RATE control living in a
different region of space from the POSITION control. Scrolling happens out past
the rim; selecting happens on it. Two gestures, two places, one hand.
`scrollBoost`, `scrollStart` and the whole latch are patches over that seam.

His fix: fix a read head at a known seat and let hand movement turn the list
underneath it. Along the run turns the dial; across the run opens the sub-menu.
One gesture, one meaning, and the thing you are selecting is always in the same
place. That is a picker wheel, a jog dial, a Digital Crown — and, not incidental
on visionOS, it is what a pinch-drag means on every other surface of the
platform. Pointing was the odd one out, which is why it bothered a hand in the
headset more than a mouse on the Mac.

### Why it is a mode and not a replacement

Absolute pointing buys BALLISTIC selection: flick toward 7 o'clock and you are
on that item in one motion, without looking, in constant time whatever the list
length. That is the property marking menus are famous for. A dial is sequential
— item six means passing one through five — so it is a straight regression on a
short, fully visible menu.

So `RadialMenuInput.auto` picks by whether the list is windowed, which is
exactly where each one wins. `point` and `dial` force it, for judging them
against each other on the same list.

### The four things that make it work

**The read head's axes are FIXED.** It is tempting to anchor them on the seat
currently selected — but the selection is what the dial produces, so the axes
you turn it with would move as you turned it. That is the un-settleable scroll
loop wearing a different hat. `dialHead` is the middle of the window, always. A
physical dial's spindle does not move because you turned the dial.

**The trigger is DIRECTED.** In point mode a radial sub-menu opens on
`hypot(p)` — distance from the center, any direction. In dial mode sideways
travel IS the dial, so an undirected reach would open a sub-menu every time you
turned it. It projects onto the head's across axis instead, and turning the dial
contributes exactly zero to it.

**One axis at a time.** Past the trigger you are choosing a child and the list
freezes. Without that, browsing a sub-menu spins the very parent you are
browsing out from under your hand — the latch bug, again, in a third costume.

**Re-anchor on resume.** Coming back out of a sub-menu, the hand has moved. The
dial re-anchors so it continues from where it is rather than jumping by however
far you drifted while choosing a child.

### What falls out

`scroll` is now one expression that pins the selection to the head while the
list has somewhere to go and lets it slide toward the ends when it does not —
which also means `dial` stays meaningful on a list too short to scroll: the
selection simply walks its seats.

And the falloff got BETTER rather than merely surviving: `seatDistance` in dial
mode is the dial's own fractional position, so the lean between two items is
literally the fraction of a turn between them instead of something inferred from
where a hand is aimed.

No latch, no shelf, no boost. Those refereed a fight between scrolling and
selecting over one coordinate. There is no fight here to referee.

## Scrolling was the wrong feature (round 15, 2026-08-23)

One round after the dial shipped, Steve: *"the more i'm thinking about this, the
more i'm feeling like dial is the wrong way to think about this... then it's like
you are constantly fishing for the desired category to land in a spot where you
are able to traverse its hierarchy."*

He is right, and the correct response is to delete rather than to keep the dial
around in case. A radial menu's entire value is SPATIAL CONSTANCY: Delete is at
7 o'clock, it is always at 7 o'clock, and a hand learns that in a week and keeps
it for years. Anything that slides the list destroys exactly that. Windowing did
not need a better input model; it needed to not exist.

Two rounds of work went in the bin, and that is the right trade — the dial was a
good answer to a question that should not have been asked.

**What went.** `windowSize`, `scrollBoost`, `scrollStart`, `RadialMenuInput`,
`dialTravelScale`, `dialReversed`, the read head and its axes, `liveScroll`,
`latchedScroll`, the latch, `recomputeScroll`, `recomputeDial`, `visibleSlots`,
`slot(ofGlobal:)`, `pointedGlobal`, `entryDelta`, the `.sliding` transition, the
carets, `scrolls`, `windowIgnoredOnFullRing`, `total` — and `window`, which
became `seats`, because a window with nothing to look through is just a count.

About 460 lines, and with them every part of this file that had ever been
genuinely hard to reason about. The pick is now nine lines: seat index IS item
index, there is no offset between them and nothing to keep in step. Every bug
this project ever had was a graph problem — a value feeding its own input, a
position measured in a moving frame, two orders that had to agree. This deleted
the last of that class outright.

**The ceiling is twelve.** A clock face, which is not a coincidence: it is about
as many directions as a hand can aim at without looking. The item LIST can be
longer — arrange mode's tray holds all of it — but only the first 2–12 take
seats. The rest are a drag away from earning one, or belong in a sub-menu.

That reframes what the app is, and Steve said so plainly: it is not a menu
LAYOUT tool, it is a menu CONSTRUCT tool. Breadth is capped; depth is where the
work goes.

## The threshold was billing you twice (round 16, 2026-08-23)

Steve: *"why don't we just have sub-menus appear once the category is selected?
... It's like a wasted click effort to show a sub-menu, am i right?"*

Yes, and the reason is that `submenuThreshold` was quietly doing two jobs:

1. REVEAL the children.
2. Switch the pick from the parent to one of them.

Only the second earns travel. Pointing at Material has already said "Material";
charging a second reach just to SEE what is inside bills you twice for one
decision. Worse, it makes you spend that reach BLIND — you commit the travel
before you know whether the thing you want is even in the fan.

So the reveal is now free and the commit still costs. Children appear on
highlight; `submenuThreshold` means only "past here you are choosing a child
rather than the parent".

Splitting it that way rather than merging the two is what keeps a parent that is
ALSO an action selectable — `highlight.action` is still `child ?? parent`, so
releasing without reaching confirms the category itself. Merge them and that
option disappears silently.

It also changes what you SEE at the boundary, for the better. It used to be
"nothing, then a fan". It is now "a fan, then one of them pops and lights" — the
child nudge from round 13 doing exactly the job it was added for, on a boundary
you can now watch yourself cross.

`submenuOnHighlight` defaults true. Off gives the old two stages, which is a
real alternative on a dense ring where sweeping past several parents blooms
several fans in succession.

One thing this quietly depends on: `contentCenter` excludes children. It always
did — because they appear and disappear — but that exclusion used to matter once
per sub-menu opening and now matters on every highlight. Included, the whole
menu would lurch each time you passed a parent.

## The commit floor (round 16b, 2026-08-23)

Round 16 changed what `submenuThreshold` MEANS without changing its value, and
that broke it immediately. Steve, within one build: *"my pointer drifts to the
next catergory, it's actually highlight/selecting one of those children."*

The number was `0.81 × ring`. With his tuning that is **94 pt on a 117 pt ring** —
comfortably INSIDE the icons. As a REVEAL boundary that was not just fine, it was
right: you want the children out before your hand arrives. As a COMMIT boundary
the same number is a bug. Sitting on an icon is already past it, so the child
pick was permanently armed, and every tangential wobble along the ring re-picked
among the children of whatever seat the hand was nearest. Deciding which category
you wanted lit up children you had not reached for.

This is the session's recurring failure in its purest form: **a default that was
only ever correct at one value of something else.** Here the "something else" was
not another knob — it was the knob's own meaning.

Two changes, and the split between them matters.

**The default moved** to `1.45 × ring`, which lands ~15 pt outside the icon rim.
That is a taste value; it is tunable and it will be tuned.

**A floor was added**, and that is NOT a taste value: `max(threshold, ring +
icon/2)` in radial, `icon/2` in linear. A child must never be pickable while the
hand is still among the top-level icons. That is a correctness property, so it is
enforced in `resolved()` rather than left to a slider that somebody can drag
somewhere wrong. It also means the fix reaches saved presets: a stored 0.81 gets
raised on load rather than reproducing the bug.

`submenuThresholdFloored` reports when it binds, because a knob that has been
silently overruled is a knob that lies. The panel says what it used instead and
why.

Ordering, at the shipped tuning: ring 117, rim 155, commit 169, children 258. You
commit well before you reach the fan — which is the point, since the fan is
already on screen and you are travelling toward a child you can see.

## In the room (round 17, 2026-08-23)

*"for the visionOS port, is there a way to see this in action when in Live mode —
where we can actually see what it looks like spatially VS the windowed pane
view?"*

A pane gives the menu a frame, a background and a scale the room will not. Every
judgement made about ring size and icon size inside that pane is partly a
judgement about the pane. So: an `ImmersiveSpace` drawing the SAME menu, with
nothing behind it, at a distance and height you dial on device.

**RadialMenu.swift did not change. Not one line.** It takes a pointer offset and
publishes a highlight, and has no opinion about whether the thing holding it is a
window, a volume or a patch of a living room. That boundary was drawn in round 1
and this is its bill of health — a whole new class of scene arrived and the
component did not notice.

### What it cost instead

Two scenes cannot share `@State`, so the state had to move. `MenuModel` is the
split, and where the line falls is the point:

- what the menu IS — layout, tuning, items, preview pose, and the live
  pointer/highlight/metrics a hand writes back — goes in the model;
- how the PANEL is being operated — which section is open, what is mid-drag,
  which chip is selected — stays `@State` on the view, because no other scene
  has any business knowing about it.

That is the same cut the component/host boundary makes one level down.

The extraction itself is deliberately dull: every moved property has a one-line
`nonmutating` shim on `TunerView`, so all ~200 existing call sites read exactly
as they did. A change of OWNERSHIP, not of behaviour. Mixing the two would have
made a mechanical move impossible to review.

### One solve at a time

While the immersive scene is open the PANE stops drawing a menu and says so.
Both scenes would otherwise publish `metrics` and recompute `highlight` from two
different `available` boxes, and fight over the readout and the pick. Standing
down is also just honest: you asked to look at it in the room.

`available: nil` in the spatial scene, too — there are no window edges in a room,
so `fit` has nothing to shrink for and the menu draws at exactly its design size.
That is the only place in the app where you see the true numbers.

### Distances are knobs

Distance, height and scale are sliders, not constants, and the height range goes
negative. Nobody picks the right arm's length for a headset from a text editor —
which is the premise of this entire app, applied to itself.

Input is the ordinary system pinch for now, through the same `menuInvocation` the
window uses. The middle-finger-to-thumb pinch Steve wants for Quads needs ARKit
`HandTrackingProvider` and an authorization prompt; that is the next step, not
this one.

### The hour this would have cost

`openImmersiveSpace` returned an error and the toggle just flashed a note. The
cause was not in any Swift file: **`UIApplicationSupportsMultipleScenes` was
NO**, because `GENERATE_INFOPLIST_FILE = YES` writes a scene manifest and that
key defaults to NO unless a build setting says otherwise. An `ImmersiveSpace` is
a second scene. Second scenes do not open.

Now set in both configurations:

    INFOPLIST_KEY_UIApplicationSupportsMultipleScenes = YES;

The other half of the lesson is that "could not open the immersive space" is not
a diagnosis. `OpenImmersiveSpaceAction.Result` has three cases with three
different causes — `.error` is almost always an unregistered scene, and
`.userCancelled` is the system declining rather than anything the app did. The
toggle now says which.

## The jitter was a lag (round 18, 2026-08-23)

*"when arc sweep is activated, it's doing the offset jitter, and arc start
contributes when arc sweep is active. Did we not already fix this?"*

We fixed a different bug with the same symptom. Round 12 folded the origin ring
into `contentCenter` so the layout stopped SWINGING. What was left was a
shimmer — and it was a one-frame lag, not a wobble.

`metrics` is published by the component through `onResolve`, so the host's copy
is always LAST frame's answer. The icons were drawn from this frame's solve and
the origin from the previous one. Hold anything still and they agree; drag a
slider that moves `contentCenter` — arc sweep, arc start, gutter, icon size —
and they are permanently one frame apart, so the whole layout trails the hand.

The fix is to stop reading it back. `resolved()` is pure, so the stage now solves
its OWN metrics each frame and uses those for the origin and for arrange mode's
dashed seats. Twice the arithmetic, exact agreement.

What stays on the published copy: the knob panel's readouts and warnings. A
number in a text row can be one frame old and nobody can tell. GEOMETRY cannot.

The loop that does not exist, and must not: `available` still comes from
`anchor`, never from `origin`. metrics → available → metrics is the real feedback
loop, and it is the reason the published value was being used in the first place.

## Dialling twelve

`icons` stopped at the LIST length, so with eight categories the ceiling of
twelve was invisible and "dial in 12 icons" simply did not work.

The slider now runs 2–12 always, and dragging up past the end of the list MAKES
categories — placeholders, ready to be named. This is a construct tool: asking
for twelve should produce twelve seats to fill, not refuse on the grounds that
you have not filled them yet. Dragging back down never deletes, so the gesture is
reversible — which is exactly what makes it safe to be that eager.

## Two centers, and no rule that pins both (round 19, 2026-08-23)

The jitter was a lag and is gone. What is left is a WOBBLE, and it is not a bug
in `contentCenter` — it is `contentCenter` working exactly as specified against a
premise that does not hold.

`drawnBoundsCenter` pins the center of a BOX: the union of the seat discs and the
origin disc. Arc sweep changes the shape of that box violently, because the ring
radius is solved from the step angle. At the shipped tuning, eight seats:

| sweep | step | ring |
|---|---|---|
| 360° | 45° | 117 pt |
| 180° | 25.7° | 201 pt |
| 90° | 12.9° | 399 pt |

A 3.4× change in radius. And at 90° the box's center sits at **(187, −187)** from
the origin, versus (0, 0) at a full ring. So dragging sweep slides the applied
offset a quarter of a screen while the content triples in size. The box's center
is pinned perfectly; the icons travel anyway, because a box center is not a thing
the eye tracks.

There is no rule that pins both the origin and the icons. They are two different
points and `arc sweep` is precisely the knob that changes the distance between
them. Round 11 pinned the icons and the origin swung; round 12 pinned the union
and the whole thing drifts. Both complaints were correct.

So it is a switch, `center on`, and the default changed to **origin** for a
reason beyond stability: in LIVE the origin is your pinch, so no offset is
applied at all. Pinning the origin in preview is the only setting where preview
and live are the same geometry. Preview claiming to be "the real thing held
still" while quietly using a different center was a smell before it was a
complaint.

Centering on icons stays, because it genuinely uses a window better — an arc gets
pulled back into the middle instead of hanging off a corner. It is the right
choice for looking at a finished arc and the wrong one for dragging the knob that
shapes it.

## Content that only exists during a change (round 20, 2026-08-23)

The immersive space opened and drew almost nothing. In preview: empty. Switching
preview → live: the menu appeared for an instant, centered, and faded.

That symptom is the diagnosis. Position was identical in both modes, so it was
never placement. What differed was that switching modes forced a re-render — and
the menu was visible for exactly as long as that took. **Content that only exists
during a state change is content that was never given anywhere to live.**

An `ImmersiveSpace` expects RealityKit content. A bare SwiftUI hierarchy compiles
and opens and then behaves like this. SwiftUI goes in as an ATTACHMENT: a real
entity, with a real transform, that persists between renders. The sliders now
move an entity that is already in the scene rather than re-describing a view that
has nowhere to be.

Two things fell out of the rewrite. Placement is in METRES, unlike every other
length in the project, because it becomes a RealityKit transform directly and
converting at the slider would only move the confusion somewhere harder to see.
And `RadialMenu.swift` still has not changed — the component takes a pointer
offset and has no opinion about whether it is in a window, a volume, or an entity
in someone's living room.

### Diagnostics, twice burned

Two wrong turns this round, both worth remembering.

A `strings` probe reported the visionOS code missing from the binary — but the
CONTROL probes came back zero too, which meant the method was broken, not the
code. It was reading the launcher stub; the code was in `RadialMenu.debug.dylib`
all along. **Always probe for something you know is there.**

And the error message asserted "scene not registered?", which was a hypothesis
wearing a diagnosis's clothes, and it sent us into the Swift. The scene was fine.
`Info.plist` was four hours older than the binary — generated from
`INFOPLIST_KEY_*` settings that an incremental build had no idea had changed.
`./Tools/build.sh clean` exists now, and the message no longer guesses.

## Twelve, and what fills it

The `+` used to keep going past twelve on the theory that extras could sit in the
tray as alternates. They can, and it is also a way to accumulate junk — which
took about one minute of real use to demonstrate. The list is capped at the ring.

The example set is now twelve, with four placeholders that name real modes in
Quads — Gizmo, Edit, Sculpt, SubD wire — so it reads as a plausible menu instead
of a bag of verbs. `reset categories` restores them, which is also the only way
back from a list you have made a mess of.

## Measuring a collision without preventing it (round 21, 2026-08-23)

*"when i'm doing the arc sweep — when 12 icons are specified, the 11th icon
overlaps the 12/midnight top icon and then snaps correctly when 360 degrees is
hit."*

The packer solved the ring from the ADJACENT step. On an arc short of a full
turn there is a second pair: the WRAP, last seat back round onto first, `360 −
sweep` apart. Below `360·(n−1)/n` the neighbours are tighter and the wrap is
irrelevant. Above it the wrap is tighter — 330° at twelve icons — and the packer
was solving for the wrong angle entirely.

The galling part: **that measurement already existed.** The gutter readout at the
bottom of `resolved()` takes `min(step, wrapDeg)`, with a comment explaining why
the wrap can be the worst pair. It just never fed the solve. So the panel would
correctly report icons overlapping while the packer insisted everything was fine.
We were measuring the collision and not preventing it, which is worse than not
measuring it at all — the diagnostic was right there being ignored.

`packStep = min(step, wrapDeg)` now. Clearance is flat at 13.6 pt across the
whole sweep range instead of collapsing above 330°.

### And the snap had an exact answer all along

Solving for the wrap means the ring grows as the arc closes, so the slider needs
a top. Two guesses went in first: a fixed `>= 355`, then "once the wrap falls
below half a step" (344° at twelve icons). Steve rejected the second with the
right rule: *"330 degrees should be it for 12 icons. You need to do the proper
division depending on how many icons are being used."*

An open arc of `S` degrees with `n` seats has a step of `S/(n−1)` and a wrap of
`360 − S`. They are equal at

    S = 360·(n−1)/n

and at that sweep the spacing is uniform the whole way round — a full ring, drawn
as an open arc. 330° at twelve icons, 315° at eight, 270° at four. Past it you are
asking for the wrap to be tighter than the neighbours: more crowded than a full
ring, in exchange for nothing.

Both guesses were reasoning about when it gets BAD. The boundary is where it
stops meaning anything NEW, and that has a closed form.

### So was the packing fix wasted?

No, but it is now belt to the snap's braces, and the two live at different layers
on purpose. The tuner's slider will not let you ASK for a sweep past the
boundary. The component makes no such assumption — a host can set
`arcSweepDegrees` to anything at all, and `packStep = min(step, wrapDeg)` means
the icons still cannot overlap when it does.

## What counts as a guide (round 21b)

The `guidesOn` switch above lasted about twenty minutes, because it swept the
pointer, its spoke and the rubber band off along with the tuning overlays.

Those are not instrumentation. They exist BECAUSE of a usability complaint — a
reviewer pointing out that between icons nothing changes, so the hand steers
blind — and a visible cursor bounded to the widget was the answer. They are on in
the shipped defaults. They are the design.

The same error as counting the origin ring as a guide, made again four rounds
later. The line is not "does it help you tune", because everything helps you
tune. It is: **would this be in the build you hand somebody?** By that test
exactly one thing in the list is a guide — the dashed sub-menu trigger and its
dotted landing circle — and it already had its own toggle.

So the switch is gone, and with it `displayStyle`, which existed only to serve
it. What replaced it is the fix the complaint actually deserved: every draw
toggle now lives in ONE always-visible group. The pointer switches used to sit
inside the preview-only section, so in LIVE — the mode where you are using the
thing — none of them could be reached. Anyone who does not want a visible cursor
turns off one toggle, and nothing decides it for them.

## One switch for the guides

The pointer, its spoke, the rubber band and the sub-menu trigger lines each had a
toggle, and every one of those toggles lived in a section that only appears in
PREVIEW — so in LIVE, the mode where you most want to see the menu as a user
would, there was no way to turn any of them off.

`guidesOn` is one switch, in the always-visible section. What it does NOT touch:
the origin ring, the label, the sub-menu arrow. Those are the menu's design, not
instrumentation on top of it.

It also introduced a distinction worth keeping: `style` is the TUNING and is what
gets exported; `displayStyle` is what a scene draws. Hiding the guides is a way
of looking at the menu, not a property of it, and the exporter must never bake a
temporary view preference into somebody else's file.

## Pointer reach (round 22, 2026-08-23)

*"i love how the pointer can overshoot the first category radius, but there may
be those that would like to dial that back."*

`pointerReachRatio`, 0 to 1, lerping the visible pointer's clamp from where the
ICONS are out to the menu's full extent. At twelve icons that spans 172 pt to
352 pt. Default 1 — nobody's behaviour changes.

Three things about it that are worth being exact about, because each one was a
decision rather than an obvious choice.

**It is display only.** The clamp lives in `clampedPointer`, which feeds
`pointerLayer` and nothing else; the PICK reads the raw offset. So pulling this
in can never cost you a sub-menu you could otherwise reach — the dot pins to the
ring while your hand keeps going and keeps working. Any other arrangement would
have made this knob dangerous instead of cosmetic.

**The floor is the icons, not the origin.** Zero would pin the dot to the menu's
center, which is a different thing and a useless one. 0 here means "stops on the
icon centers", which is what was actually asked for.

**In the linear layouts the ACROSS floor is half an icon, not the seat line.**
Across is the direction sub-menus open, and a dot welded to the column could
never show you leaving it.

What the knob actually trades: at 1 the dot keeps moving past the ring, and that
movement is a cue — it says you have gone further than you needed to. At 0 it
stops dead and every further millimetre of hand is silent. Cleaner, and one cue
poorer. Both are defensible, which is exactly what makes it a knob rather than a
decision.

### It bounds empty space, not travel

*"as soon as you hit a category WITH sub menu choices, the pointer is able to
reach them."*

Shipped as first written, this knob was cosmetic right up until you used it. At
0 the dot pins to the ring at 172 pt — while the trigger is at 250 and the
children land at 314. Pick a child and your hand is 140 pt past a dot that
stopped moving. Blind in the one place blindness costs something, at exactly the
setting somebody chose for tidiness.

The first attempt at `pointerBound` had three cases, and the middle one raised
the bound to the sub-menu TRIGGER whenever a parent was highlighted — so you
could get to the children, and so the bound would already be at the trigger when
they opened and nothing would jump.

Steve found it immediately: *"at 0, the pointer is NOT pinning to the radius of
the first category. It's reaching out to the submenu radius."*

Both halves of that reasoning were wrong.

**The dot does not need to reach the trigger.** Your HAND does, and the pick
reads the raw offset — the clamp has only ever been a display bound. All the rule
bought was a `pointer reach` of 0 that pinned to the ring on a plain category and
to the trigger on a parent. A floor that depends on which icon you happen to be
over is not a floor, and on a twelve-item menu it made the knob look inert
wherever it mattered.

**And the jump was never avoidable.** Pin the dot at the ring, then follow the
hand out to children at 314 pt, and it has to cross the gap between at some
point. The question is only WHERE. Better at the moment of commitment, where the
jump reads as "you are in the sub-menu now", than smeared into a bound that
quietly stops meaning what the slider says.

So: two cases. Children out → everything. Otherwise → the dial, whatever is
under you. At the shipped default of 1 there is no clamp and no jump at all; the
jump exists only at settings where hard pinning is the thing being asked for.

The general shape is still worth keeping, but stated more carefully than last
round: a limit that says "further buys you nothing" has to know what is in front
of you — and "in front of you" means what you have COMMITTED to, not what you
happen to be pointing at.

## A distance test is not a commitment test (round 22b, 2026-08-24)

*"nope — still not right. I should feel a literal radial constraint, where i am
unable to push the dot past the first category radius. ONLY when i hit a category
with submenus will it let me reach out to them."*

Third try. The knob still did nothing, at any setting, on most of the menu.

`submenuOpen(m)` reads:

    guard let p = activePointer(m) else { return false }
    return submenuReach(p) >= m.submenuThreshold

That is a **distance** question — "has the hand travelled past the trigger" — and
it answers yes over a childless category exactly as readily as over a parent.
Nothing in it looks at the item. `pointerBound` opened on it as line one:

    if submenuOpen(m) { return m.reach }        // <- fires everywhere

So on every plain category the bound held the dot from the ring out to the
trigger and then let go, into open space, for nothing. Push far enough — which
is the only way anyone would ever test a reach slider — and the clamp was gone.
Hence "reach 0 does exactly what reach 1 does."

Two rounds were spent looking at the wrong line. Round 22 removed the parent
floor, arguing a floor that changes with whichever icon you are over is not a
floor. That argument was fine and the conclusion was wrong: the floor was never
the bug, and Steve's spec asks for it in as many words — *only* a category with
sub-menus lets you out. The floor came back. The guard went in front of it:

    guard highlightedHasChildren else { return m.pointerReach }
    if submenuOpen(m) { return m.reach }
    ...

  * nothing under you → the dial, hard, however far you push
  * a parent, not yet open → at least the trigger, so you can GET to them
  * children out → everything, they are what you are reaching for

**The lesson, and it is the third time this project has hit it.** A predicate
whose name states a conclusion (`submenuOpen`) but whose body tests a proxy
(distance) is safe only where the caller has already established the rest. Every
other caller had: `showsChildren` checks the item first, the sub-menu guide is
only drawn for a parent. This one asked the proxy on its own and inherited a
meaning the function never had.

Same family as the submenu threshold that was only correct at one ring radius,
and as `guidesOn` sweeping the pointer away with the measure lines. A thing that
is right in every place it is currently called is not the same as a thing that
is right.

## A check that runs after the thing it was meant to catch (round 23, 2026-08-24)

First real iPad simulator build. It failed like this:

    BUILD FAILED (ipad) — errors:
      Unable to find a device matching the provided destination specifier:
      { platform:watchOS, ... name:Steve's Apple Watch, error: ... doesn't match
        RadialMenu.app's supported platforms }
      { platform:visionOS Simulator, ... error: ... 26.5 doesn't match 27.0
        deployment target }

Neither line is about an iPad. The actual fault — this Mac has no simulator
named `iPad Pro 13-inch (M4)` — appears nowhere in the output. xcodebuild
answers a name it cannot match by listing every destination it CAN see, which on
a machine with a watch and a headset attached is a paragraph of true, irrelevant
sentences.

`build.sh` already had a clear message for exactly this: *"no available simulator
is named X — here is what you have."* It sat in the post-build block, which is to
say it could only run once the build had already succeeded. A guard placed after
the failure it describes.

Moved to a pre-flight: resolve the name to a udid first, report it by name if
there is no match (with the list of what does exist), and hand xcodebuild
`id=<udid>` rather than `name=<string>` — unambiguous, and it cannot half-match.

The same shape as `pointerBound` two rounds ago and as the `strings` probe
before it. A check is only worth what its POSITION is worth. Correct logic
downstream of the failure it guards against is not a guard, it is a comment.

**Also surfaced, and fixed:** `XROS_DEPLOYMENT_TARGET` was 27.0 against a
visionOS 26.5 simulator runtime — so `./Tools/build.sh sim` could not work here,
and nobody off the 27 beta could build this repo at all. On a project whose whole
purpose is being handed to other visionOS developers, that is not a build setting,
it is an audience.

Dropped to 26.0. Nothing in the sources justified 27: no `@available`, no
`#available`, and the spatial view is built entirely from `RealityView`,
`Attachment` and entity transforms, all of which predate it. The number was
whatever the project template happened to stamp in — which is how deployment
targets usually get set, and why they are usually wrong.

## The phone is not a vertical split (round 23b, 2026-08-24)

*"when in landscape mode on iPhone, can we have the layout like it shows on the
mac? Otherwise, i just can't see pane 1 with the preview or layout"*

`splitsVertically` was `current == .phone`. A device class standing in for a
measurement, which is fine right up until the measurement changes without the
device doing so.

Portrait, 393 x 852: a 300 pt panel underneath still leaves 550 for the stage.
Landscape, 852 x 393: the same rule leaves 90, and the menu is not on screen at
all. Nothing about "is this a phone" changed between those two, which is the
tell — the flag was reading the wrong thing the whole time and portrait was
hiding it.

Now `SplitStage` decides per window: stack the panel only if the platform allows
it AND the window is taller than it is wide. The phone is still the only one
allowed to flip — an iPad or a Mac always has the width, and rearranging them on
a resize would be motion for its own sake.

Extended to the iPad the same day, at Steve's ask, and it reads the same from
the other end: *"I typically work in landscape mode on iPad, but those who use it
in portrait should just be able to use it with panel on top like iOS portrait
default."* Which is the point — once the rule is about the window, the device it
is running on stops being part of the question. The Mac and the headset stay
excluded, and not by oversight: both are resized by hand and continuously, and a
panel that jumped edges as you dragged a corner past square would be the layout
rearranging itself mid-gesture. A tablet has two orientations and you commit to
one; a window has a thousand and you pass through them on the way somewhere.

The second bug was underneath it. `span` was ONE number used as a height when
the panel was below and a width when beside, so dragging the panel tall in
portrait and rotating produced a panel that wide in landscape — the stage
collapsing from a gesture the user never made. Two spans, one per direction.
A single variable whose meaning depends on a mode is two variables wearing a
coat.

## Where this is heading

The menu is meant to be summoned **on whatever you're gazing at** — an object, empty space, or
the grid plane. This POC fakes that by using the pinch's own start location; in Quads the host
would pass the gaze/object anchor instead. That is a host concern: the component only ever
receives "the pointer is this far from the menu's center".
