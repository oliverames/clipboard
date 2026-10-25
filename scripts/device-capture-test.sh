#!/bin/bash
#
# device-capture-test.sh — measure Clipboard's background capture on a real iPhone.
#
# The simulator disables the private pasteboard-change hook, so capture reliability can
# only be proven on device. This script does not test anything by itself: it resets the
# capture ledger, walks you through copying N items across apps in each of the ways the
# app can be "closed", then pulls the ledger back off the phone and prints the miss rate
# for each phase.
#
# It never installs or launches anything without you running it. Installing the Debug
# build on the phone is a separate step you do in Xcode first.
#
# Requirements:
#   - A Debug build of Clipboard installed on the iPhone (Settings > Diagnostics on).
#   - The phone connected and trusted; `xcrun devicectl list devices` shows it.
#   - Paste permission Allowed and Location set to Always (the app's onboarding).
#
# Usage:
#   scripts/device-capture-test.sh                 # auto-pick the one connected device
#   scripts/device-capture-test.sh <device-udid>   # or name the device
#   N=10 INTERVAL=30 scripts/device-capture-test.sh # override copies-per-phase / seconds
#
set -u

BUNDLE_ID="com.oliverames.clipboard"
N="${N:-10}"
INTERVAL="${INTERVAL:-30}"
OUT_DIR="${OUT_DIR:-$HOME/Desktop/clipboard-capture-test-$(date +%Y%m%d-%H%M%S)}"

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  # Pick the single connected device, if there is exactly one.
  DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/connected/{print $(NF-2)}' | head -1)
fi
if [ -z "$DEVICE" ]; then
  echo "No connected device found. Pass a UDID: scripts/device-capture-test.sh <udid>"
  echo "List devices with: xcrun devicectl list devices"
  exit 1
fi

mkdir -p "$OUT_DIR"
echo "Device:    $DEVICE"
echo "Bundle:    $BUNDLE_ID"
echo "Per phase: $N copies, $INTERVAL s apart"
echo "Output:    $OUT_DIR"
echo

pause() { read -r -p "$1" _; }

launch_env() { # launch_env KEY=VALUE  — launch the app once with an env var, then background it
  xcrun devicectl device process launch --terminate-existing \
    --device "$DEVICE" --environment "$1=1" "$BUNDLE_ID" >/dev/null 2>&1
}

pull_ledger() { # pull_ledger <label>
  local label="$1"
  echo "  Staging the ledger from the app (launching with CLIPBOARD_EXPORT_LEDGER=1)…"
  launch_env CLIPBOARD_EXPORT_LEDGER
  sleep 3
  local dest="$OUT_DIR/ledger-$label.jsonl"
  if xcrun devicectl device copy from \
        --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source Documents/capture-ledger.jsonl --destination "$dest" >/dev/null 2>&1; then
    echo "  Pulled -> $dest"
    summarize "$dest"
  else
    echo "  Could not pull the ledger with devicectl."
    echo "  Open the app on the phone: Settings > Diagnostics and read the miss rate there."
  fi
}

summarize() { # summarize <ledger.jsonl>
  local f="$1"
  python3 - "$f" <<'PY'
import json, sys
seen=set(); saved=set(); c={}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line=line.strip()
    if not line: continue
    try: e=json.loads(line)
    except Exception: continue
    ev=e.get("event"); cc=e.get("changeCount")
    c[ev]=c.get(ev,0)+1
    if ev in ("changeHeard","reloadRequested","widgetRan","saved") and cc: seen.add(cc)
    if ev=="saved" and cc: saved.add(cc)
n=len(seen); s=len(saved & seen)
rate = (1 - s/n) if n else None
print(f"    events: {dict(sorted(c.items()))}")
print(f"    change counts seen={n} saved={s}  miss rate={'n/a' if rate is None else f'{rate:.0%}'}")
PY
}

cat <<EOF
Before you start:
  1. Install the Debug build on the phone from Xcode (this script won't install it).
  2. Open Clipboard, finish onboarding: Allow Paste, Location = Always, widget on a Home Screen.
  3. In Settings > Diagnostics, tap Clear so this run starts from an empty ledger.
EOF
pause "Press Enter when that's done… "

run_phase() { # run_phase <label> <instruction>
  local label="$1"; shift
  echo
  echo "=== Phase: $label ==="
  echo "$1"
  pause "Press Enter to start the $N-copy sequence for '$label'… "
  for i in $(seq 1 "$N"); do
    echo "  [$label $i/$N] COPY something now (switch apps between copies: Safari URL, a Note, a Message)."
    sleep "$INTERVAL"
  done
  echo "  Sequence done."
  pull_ledger "$label"
}

run_phase "foreground" "Keep Clipboard in the FOREGROUND the whole time (split-screen or glance back)."
run_phase "backgrounded" "Press Home so Clipboard is BACKGROUNDED (do NOT swipe it away). Copy from other apps."
run_phase "forcequit" "Swipe Clipboard AWAY in the App Switcher (force-quit). Then copy from other apps. Expected: nothing saves until you reopen Clipboard."
echo
echo "=== Phase: reboot ==="
echo "Reboot the phone. Do the copies AFTER you unlock it the first time."
pause "Press Enter once you've rebooted, unlocked, and are ready… "
run_phase "reboot" "Copy from other apps now (app still force-quit from the previous phase, unless you reopened it)."

echo
echo "All phases done. Per-phase ledgers and miss rates are in: $OUT_DIR"
echo "Reminder: 'foreground' and 'backgrounded' should capture ~everything. 'forcequit' is"
echo "expected to miss every copy until the app is opened again (an accepted limit). 'reboot'"
echo "recovers only once significant-change relaunches the app or you open it."
