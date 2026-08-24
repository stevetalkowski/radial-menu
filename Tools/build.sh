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
if [ -f "$ROOT/Config/local.env" ]; then
  # SAY SO when the file is broken, because its failure mode is silence.
  #
  # This file is SOURCED, so a value is shell syntax, not a string.
  # `NAME=iPhone 17 Pro Max` assigns "iPhone" and tries to RUN `17`;
  # `NAME=iPad Pro 13-inch (M5)` is an outright syntax error. Both leave the
  # variable unset, build.sh falls back to its default, and the symptom is a
  # simulator you did not ask for booting as though your config were ignored.
  # Which is exactly what happened the first time these two lines were written.
  bad=$(grep -nE '^[A-Za-z_][A-Za-z0-9_]*=[^"'"'"']*[[:space:](]' \
        "$ROOT/Config/local.env" 2>/dev/null || true)
  if [ -n "$bad" ]; then
    echo "Config/local.env — these values need quoting:"
    printf '%s\n' "$bad" | sed 's/^/  /'
    echo '  a value with a space or a bracket must be quoted:  NAME="iPad Pro 13-inch (M5)"'
    echo
  fi
  . "$ROOT/Config/local.env"
fi
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
  local sim_name="" sim_platform="" sim_udid="" want_rt=""""

  # Everything a target needs, decided in one place. The UDID is read by NAME
  # here rather than through `${!var}` indirection — also a bash 3.2 courtesy.
  case "$target" in
    mac)    dest='platform=macOS' ;;
    vision) dest='generic/platform=visionOS'; products='Debug-xros'
            udid_var='RADIALMENU_DEVICE'; udid="${RADIALMENU_DEVICE:-}" ;;
    # BUILD AGAINST THE DEVICE, not against "some iOS device".
    #
    # `generic/platform=iOS` builds a binary for the architecture and stops
    # there. `-allowProvisioningUpdates` can then refresh the profile but has no
    # idea WHICH device to add to it, because nothing in the build named one —
    # so a phone that was already in the profile installs, and an iPad that
    # never was fails at the last step with
    #
    #     0xe8008012 — This provisioning profile cannot be installed on this device
    #
    # which reads like a signing misconfiguration and is really just "you have
    # not told Apple this iPad exists". Naming the destination by id lets the
    # registration happen during the build, where it belongs. Falls back to
    # generic when there is no udid, so `all` can still compile for a device you
    # have not plugged in.
    phone)  udid="${RADIALMENU_IPHONE:-}"; udid_var='RADIALMENU_IPHONE'
            products='Debug-iphoneos'
            dest="${udid:+platform=iOS,id=$udid}"; dest="${dest:-generic/platform=iOS}" ;;
    pad)    udid="${RADIALMENU_IPAD:-}";   udid_var='RADIALMENU_IPAD'
            products='Debug-iphoneos'
            dest="${udid:+platform=iOS,id=$udid}"; dest="${dest:-generic/platform=iOS}" ;;
    ios)    sim_name="${RADIALMENU_IOS_SIM:-iPhone 17 Pro}"
            want_rt="${RADIALMENU_IOS_RUNTIME:-}"
            sim_platform='iOS Simulator'; products='Debug-iphonesimulator' ;;
    ipad)   sim_name="${RADIALMENU_IPAD_SIM:-iPad Pro 13-inch (M5)}"
            want_rt="${RADIALMENU_IOS_RUNTIME:-}"
            sim_platform='iOS Simulator'; products='Debug-iphonesimulator' ;;
    sim)    sim_name="${RADIALMENU_SIM:-Apple Vision Pro}"
            want_rt="${RADIALMENU_XR_RUNTIME:-}"
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
    # WHICH ONE, when the name exists under six runtimes.
    #
    # `head -1` was wrong and quietly so: simctl lists oldest runtime first, so
    # every simulator build was pinned to the oldest SDK still installed on the
    # machine — iOS 26.1 on a Mac that also has 27.0 — and nothing said so.
    #
    # Prefer one that is already BOOTED: reusing a running simulator is quicker
    # and avoids leaving four of them powered up. Otherwise take the LAST match,
    # which is the newest runtime. Either way the choice gets printed, because
    # "which OS did that just run on" should never be a thing you have to infer.
    #
    # NEWEST is a poor default when your actual devices are not. Set
    # RADIALMENU_IOS_RUNTIME / RADIALMENU_XR_RUNTIME to pin the family you
    # ship against, and testing stops drifting ahead of your own hardware.
    local listing="" pool="" row=""
    listing=$(env DEVELOPER_DIR="$DEV" xcrun simctl list devices available)
    pool="$listing"
    if [ -n "$want_rt" ]; then
      # Keep only the rows under the matching runtime header.
      pool=$(printf '%s\n' "$listing" | awk -v rt="$want_rt" '
        /^-- / { inside = (index($0, rt) > 0); next }
        inside { print }')
    fi
    row=$(printf '%s\n' "$pool" | grep -F "$sim_name (" | grep "(Booted)" | head -1)
    [ -z "$row" ] && row=$(printf '%s\n' "$pool" | grep -F "$sim_name (" | tail -1)
    sim_udid=$(printf '%s\n' "$row" | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')

    if [ -z "$sim_udid" ]; then
      echo "-- $target - $sim_platform"
      if [ -n "$want_rt" ]; then
        echo "   no simulator named \"$sim_name\" under a runtime matching \"$want_rt\"."
      else
        echo "   no available simulator is named \"$sim_name\"."
      fi
      echo
      echo "   what this Mac actually has:"
      env DEVELOPER_DIR="$DEV" xcrun simctl list devices available \
        | sed -E 's/ \([0-9A-Fa-f-]{36}\) \(.*\)$//' | sed 's/^/     /'
      echo
      echo "   put the name you want in Config/local.env as RADIALMENU_IOS_SIM,"
      echo "   RADIALMENU_IPAD_SIM or RADIALMENU_SIM — and the runtime, if you"
      echo "   pin one, as RADIALMENU_IOS_RUNTIME / RADIALMENU_XR_RUNTIME."
      echo "   Missing runtimes install from Xcode -> Settings -> Components."
      return 1
    fi
    # The runtime header above the row we picked, so the log names the OS.
    local sim_runtime=""
    sim_runtime=$(printf '%s\n' "$listing" \
                  | awk -v u="$sim_udid" '/^-- /{rt=$0} index($0,u){print rt; exit}' \
                  | sed 's/^-- //; s/ --$//')
    dest="platform=$sim_platform,id=$sim_udid"
    sim_name="$sim_name${sim_runtime:+ · $sim_runtime}"
  fi

  echo "-- $target - $dest"
  # `-allowProvisioningUpdates` is what makes the FIRST build to a new device
  # work. A development profile lists the devices it is valid for, and a phone
  # you have never built to is not in it yet. Without this flag xcodebuild fails
  # with a signing error that describes the profile rather than the phone; with
  # it, Xcode registers the device and refreshes the profile and you never learn
  # any of that happened. Harmless on every other target.
  env DEVELOPER_DIR="$DEV" xcodebuild \
    -project "$ROOT/RadialMenu.xcodeproj" \
    -scheme RadialMenu \
    -derivedDataPath "$ROOT/build" \
    -destination "$dest" \
    -allowProvisioningUpdates \
    build > "$LOG" 2>&1

  if [ $? -ne 0 ]; then
    echo
    echo "BUILD FAILED ($target) — errors:"
    grep -E "error:" "$LOG" | sed 's/^/  /' | head -40
    if grep -q "isn't registered in your developer account" "$LOG" 2>/dev/null; then
      echo "   ^ an ACCOUNT step, not a code one. Apple has to be told this"
      echo "     device exists before any profile can include it:"
      echo "       Xcode -> open RadialMenu.xcodeproj, pick the device, Run."
      echo "       Xcode offers a Register Device button; one click, once ever."
      echo "     or developer.apple.com -> Certificates, Identifiers & Profiles"
      echo "       -> Devices -> + -> paste the identifier from the error above."
      echo "     NOTE the two identifiers are different things: devicectl shows"
      echo "     a UUID, Apple wants the hardware UDID printed in the error."
      echo
    fi
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
      if grep -q "0xe8008012\|ApplicationVerificationFailed" "$LOG" 2>/dev/null; then
        echo
        echo "   0xe8008012 — this is NOT a cable or a lock screen. The device is"
        echo "   not listed in the development provisioning profile. Building"
        echo "   against the device by id (which this script now does) normally"
        echo "   registers it; if it persists, open RadialMenu.xcodeproj once,"
        echo "   pick this device in the toolbar and run from Xcode. Xcode will"
        echo "   register it and every later ./Tools/build.sh will work."
      fi
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
