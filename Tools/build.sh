#!/bin/bash
#
# build.sh — embed, build, install. The whole loop in one command.
#
#   ./Tools/build.sh                 macOS, then open the app
#   ./Tools/build.sh vision          visionOS — builds AND installs to the headset
#   ./Tools/build.sh phone           iOS — builds AND installs to your iPhone
#   ./Tools/build.sh pad             iPadOS — builds AND installs to your iPad
#   ./Tools/build.sh ios             iPhone simulator — boots it and launches
#   ./Tools/build.sh ipad            iPad simulator — boots it and launches
#   ./Tools/build.sh sim             visionOS simulator — boots it and launches
#
# TARGETS COMPOSE. Name as many as you like and they run in order:
#
#   ./Tools/build.sh mac vision      the Mac one first, so a compile error shows
#                                    up in seconds instead of after a device build
#   ./Tools/build.sh all             mac + vision + phone + pad, skipping any
#                                    device you have not put a UDID in local.env for
#
#   ./Tools/build.sh clean vision    wipe the derived data first
#
# Reach for `clean` when a change to the PROJECT rather than to a source file
# does not seem to have taken. Info.plist is the one that bites: it is generated
# from INFOPLIST_KEY_* build settings, and an incremental build will happily keep
# serving the copy it made before you changed them — so the app runs with a plist
# hours older than its own binary and nothing says so.
#
# One target failing stops the run — there is no point installing to three
# devices when the code does not compile.
#
# Device UDIDs live in Config/local.env (gitignored). Override for one run:
#   RADIALMENU_DEVICE=<udid> ./Tools/build.sh vision
#
# Always regenerates RadialMenuSource.swift first, so the standalone export can
# never drift from the component it claims to contain.
#
# Output is quiet on success and shows only the errors on failure — the full log
# is kept at build/last-build.log either way.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Machine-specific settings — device UDIDs and the like. Gitignored, so the
# repo carries nobody's hardware ids. See Config/local.env.example.
# shellcheck disable=SC1091
[ -f "$ROOT/Config/local.env" ] && . "$ROOT/Config/local.env"
DEV="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

mkdir -p "$ROOT/build"
LOG="$ROOT/build/last-build.log"

"$ROOT/Tools/embed-source.sh" || exit 1

# ── one target ───────────────────────────────────────────────────────────────
#
# Everything a target needs is decided here and nowhere else: where to build,
# what the products directory is called, and which UDID installs it. Adding a
# platform means adding one case, not editing three places that have to agree.

build_one() {
  # Initialised, not merely declared: macOS still ships bash 3.2, and `set -u`
  # there is unforgiving about a local that was never assigned.
  local target="$1" dest="" products="" udid_var="" udid="" app=""
  local sim_name="" sim_platform="" sim_udid=""""

  # Everything a target needs, decided in one place. The UDID is read by NAME
  # here rather than through `${!var}` indirection — also a bash 3.2 courtesy.
  case "$target" in
    mac)    dest='platform=macOS' ;;
    vision) dest='generic/platform=visionOS'; products='Debug-xros'
            udid_var='RADIALMENU_DEVICE'; udid="${RADIALMENU_DEVICE:-}" ;;
    phone)  dest='generic/platform=iOS';      products='Debug-iphoneos'
            udid_var='RADIALMENU_IPHONE'; udid="${RADIALMENU_IPHONE:-}" ;;
    pad)    dest='generic/platform=iOS';      products='Debug-iphoneos'
            udid_var='RADIALMENU_IPAD';   udid="${RADIALMENU_IPAD:-}" ;;
    ios)    sim_name="${RADIALMENU_IOS_SIM:-iPhone 17 Pro}"
            sim_platform='iOS Simulator'; products='Debug-iphonesimulator' ;;
    ipad)   sim_name="${RADIALMENU_IPAD_SIM:-iPad Pro 13-inch (M4)}"
            sim_platform='iOS Simulator'; products='Debug-iphonesimulator' ;;
    sim)    sim_name="${RADIALMENU_SIM:-Apple Vision Pro}"
            sim_platform='visionOS Simulator'; products='Debug-xrsimulator' ;;
    *)      dest="$target" ;;
  esac

  # -- resolve a simulator NAME to its udid, BEFORE xcodebuild sees it --------
  #
  # Handing xcodebuild `name=<something>` and letting it fail is a bad trade. A
  # name it cannot match makes it print every destination attached to the Mac —
  # Apple Watches, headsets, the wrong runtime versions — and the one sentence
  # you needed, "there is no simulator by that name", is in none of it. The
  # first time this ran for real it answered a missing iPad with a paragraph
  # about a watch.
  #
  # Resolving here catches it in one grep, names the string that failed, and
  # answers with the simulators that DO exist. Building against the udid rather
  # than a string is less ambiguous anyway.
  if [ -n "$sim_name" ]; then
    sim_udid=$(env DEVELOPER_DIR="$DEV" xcrun simctl list devices available \
               | grep -F "$sim_name (" | head -1 \
               | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')

    if [ -z "$sim_udid" ]; then
      echo "-- $target - $sim_platform"
      echo "   no available simulator is named \"$sim_name\"."
      echo
      echo "   what this Mac actually has:"
      env DEVELOPER_DIR="$DEV" xcrun simctl list devices available \
        | sed -E 's/ \([0-9A-Fa-f-]{36}\) \(.*\)$//' | sed 's/^/     /'
      echo
      echo "   put the name you want in Config/local.env as RADIALMENU_IOS_SIM,"
      echo "   RADIALMENU_IPAD_SIM or RADIALMENU_SIM — or install the runtime in"
      echo "   Xcode -> Settings -> Components."
      return 1
    fi
    dest="platform=$sim_platform,id=$sim_udid"
  fi

  echo "── $target · $dest"
  env DEVELOPER_DIR="$DEV" xcodebuild \
    -project "$ROOT/RadialMenu.xcodeproj" \
    -scheme RadialMenu \
    -derivedDataPath "$ROOT/build" \
    -destination "$dest" \
    build > "$LOG" 2>&1

  if [ $? -ne 0 ]; then
    echo
    echo "BUILD FAILED ($target) — errors:"
    grep -E "error:" "$LOG" | sed 's/^/  /' | head -40
    echo
    echo "full log: $LOG"
    return 1
  fi
  echo "   built"

  # -- simulator: build it, boot it, run it -----------------------------------
  #
  # A simulator target that stops at "built" is the one case where success shows
  # you nothing at all: the .app lands in DerivedData and no window ever opens.
  # Same loop the device targets already run, with simctl in place of devicectl.
  if [ -n "$sim_name" ]; then
    local bundle_id=""
    app="$ROOT/build/Build/Products/$products/RadialMenu.app"

    if [ ! -d "$app" ]; then
      echo "   built, but no .app at $app" >&2
      return 1
    fi

    # `simctl boot` on an already-booted device is an ERROR, not a no-op.
    if ! env DEVELOPER_DIR="$DEV" xcrun simctl list devices \
         | grep -F "$sim_udid" | grep -q "Booted"; then
      echo "   booting $sim_name ..."
      env DEVELOPER_DIR="$DEV" xcrun simctl boot "$sim_udid" >> "$LOG" 2>&1
    fi

    # Bring the window forward, then WAIT for the boot to finish. Installing
    # into a device still coming up fails with a message that names none of this.
    open -a Simulator >> "$LOG" 2>&1
    env DEVELOPER_DIR="$DEV" xcrun simctl bootstatus "$sim_udid" -b >> "$LOG" 2>&1

    # Read the bundle id off the BUILT app rather than out of Local.xcconfig:
    # one source, and it cannot disagree with what was actually installed.
    bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
                "$app/Info.plist" 2>/dev/null)

    if env DEVELOPER_DIR="$DEV" xcrun simctl install "$sim_udid" "$app" >> "$LOG" 2>&1; then
      if [ -n "$bundle_id" ] \
         && env DEVELOPER_DIR="$DEV" xcrun simctl launch "$sim_udid" "$bundle_id" >> "$LOG" 2>&1; then
        echo "   launched on $sim_name"
      else
        echo "   installed on $sim_name — open it from the home screen"
      fi
    else
      echo
      echo "   INSTALL FAILED ($target) on $sim_name."
      tail -12 "$LOG" | sed 's/^/     /'
      return 1
    fi
  fi

  # ── install, for the targets where a build on its own is useless ───────────
  if [ -n "$udid_var" ]; then
    app="$ROOT/build/Build/Products/$products/RadialMenu.app"

    if [ -z "$udid" ]; then
      echo "   built, but no UDID in \$$udid_var — not installed."
      echo "   set it in Config/local.env (see Config/local.env.example)."
      echo "   find it with:  xcrun devicectl list devices"
      echo "   the .app is at $app"
      return 0
    fi
    if [ ! -d "$app" ]; then
      echo "   built, but no .app at $app" >&2
      return 1
    fi

    echo "   installing to $udid ..."
    if env DEVELOPER_DIR="$DEV" xcrun devicectl device install app \
         --device "$udid" "$app" >> "$LOG" 2>&1; then
      # Never --console: it ties the app's life to this shell.
      echo "   installed — launch Radial Menu on the device"
    else
      echo
      echo "   INSTALL FAILED ($target). Is the device awake, unlocked and paired?"
      echo "     xcrun devicectl list devices"
      tail -12 "$LOG" | sed 's/^/     /'
      return 1
    fi
  fi

  # Only the Mac build is something you can just double-click.
  if [ "$target" = "mac" ]; then
    app="$ROOT/build/Build/Products/Debug/RadialMenu.app"

    # Quit the running copy and WAIT for it to actually be gone. `open` returns
    # -600 (procNotFound) if it races an app that is still tearing down — the
    # build was fine, only the relaunch lost the race.
    if pgrep -x RadialMenu >/dev/null 2>&1; then
      pkill -x RadialMenu 2>/dev/null
      for _ in $(seq 1 25); do
        pgrep -x RadialMenu >/dev/null 2>&1 || break
        sleep 0.2
      done
      sleep 0.3
    fi

    if open "$app" 2>/dev/null; then
      echo "   launched"
    else
      sleep 1
      if open "$app" 2>/dev/null; then
        echo "   launched (second try)"
      else
        echo "   built fine, but could not launch it — open it yourself:"
        echo "     open $app"
      fi
    fi
  fi
}

# ── the run ──────────────────────────────────────────────────────────────────

# `$#` first, because expanding an empty `"$@"` under `set -u` is itself an
# error on bash 3.2 — the one macOS still ships.
if [ $# -eq 0 ]; then
  TARGETS=(mac)
else
  TARGETS=("$@")
fi

# `clean` is a pseudo-target: it wipes and gets out of the way, so it composes
# with the real ones rather than being a separate mode.
if [ "${TARGETS[0]:-}" = "clean" ]; then
  echo "── clean · removing $ROOT/build"
  rm -rf "$ROOT/build"
  mkdir -p "$ROOT/build"
  TARGETS=("${TARGETS[@]:1}")
  [ ${#TARGETS[@]} -eq 0 ] && TARGETS=(mac)
fi

# `all` expands to everything you can actually reach from this machine. A device
# with no UDID is skipped with a line saying so rather than failing the run —
# "build everywhere" should not depend on which cables happen to be plugged in.
if [ "${TARGETS[0]}" = "all" ]; then
  TARGETS=(mac)
  [ -n "${RADIALMENU_DEVICE:-}" ] && TARGETS+=(vision)
  [ -n "${RADIALMENU_IPHONE:-}" ] && TARGETS+=(phone)
  [ -n "${RADIALMENU_IPAD:-}" ]   && TARGETS+=(pad)
  echo "all → ${TARGETS[*]}"
fi

for t in "${TARGETS[@]}"; do
  build_one "$t" || exit 1
done

echo "done"
