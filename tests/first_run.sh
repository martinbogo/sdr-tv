#!/bin/bash
# Automated first-run test: launches the built app as a brand-new user would (empty data folder,
# empty preferences) and checks the welcome scan, watching, the online guide and snapshots.
# Needs the HackRF connected and an antenna; takes about two minutes. Your own settings and data
# are not touched (SDRTV_DATA_DIR and SDRTV_DEFAULTS_SUITE point the app elsewhere).
#   tests/first_run.sh            (exit status 0 when every step passes)
#   SKIP=1 tests/first_run.sh     (skips the introduction, as an experienced user would)
set -uo pipefail
cd "$(dirname "$0")/.."
APP="macos/build/SDR TV.app/Contents/MacOS/SDR TV"
[ -x "$APP" ] || { echo "Build the app first: macos/build.sh"; exit 2; }
SUITE=sdrtv-firstrun-test
ROOT=/tmp/sdrtv-firstrun-test                # removed at the end: a fixed, recognizable path only
DATA=$ROOT/data
LOG=$ROOT/app.log
fail=0
pass() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }
# wait_for SECONDS DESCRIPTION COMMAND...: poll until the command succeeds
wait_for() { local t=$1; shift; local what=$1; shift; local end=$(( $(date +%s) + t ))
    until "$@" >/dev/null 2>&1; do [ "$(date +%s)" -ge $end ] && { bad "$what (gave up after ${t}s)"; return 1; }; sleep 1; done
    pass "$what"; }
# find (and optionally press) a control in the setup window by its accessibility identifier
FINDER=$ROOT/find.applescript
write_finder() { cat > "$FINDER" <<'AS'
on run argv
    set wanted to item 1 of argv
    set act to ""
    if (count of argv) > 1 then set act to item 2 of argv
    tell application "System Events" to tell process "SDR TV"
        set els to entire contents of sheet 1 of window 1
        repeat with i from 1 to count of els
            set e to item i of els
            try
                if (value of attribute "AXIdentifier" of e) is wanted then
                    if act is "click" then click e
                    return "found"
                end if
            end try
        end repeat
    end tell
    error "not found: " & wanted
end run
AS
}
ui_find() { osascript "$FINDER" "$@"; }
press() { ui_find "$1" click >/dev/null 2>&1 || bad "could not press $1"; }
device_ok() { ui_find intro.deviceStatus >/dev/null && ! grep -aq "No HackRF" "$LOG"; }
has_channels() { python3 -c "import json,sys; sys.exit(0 if len(json.load(open('$DATA/channels.json'))) > 0 else 1)"; }
scan_done() { python3 -c "
import plistlib,subprocess,sys
d=plistlib.loads(subprocess.run(['defaults','export','$SUITE','-'],capture_output=True).stdout or b'<plist><dict/></plist>')
sys.exit(0 if d.get('initialScanDone') else 1)"; }
playing() { grep -aq "player: playing (sound)" "$LOG" && grep -aqE "^t=.* video=[1-9][0-9.]*fps" "$LOG"; }
online_guide() { python3 -c "
import json,sys; g=json.load(open('$DATA/guide.json'))
sys.exit(0 if sum(1 for v in g.values() for e in v if e.get('source')) > 0 else 1)"; }
snapshot() { ls "$DATA/snapshots/"*.jpg; }

echo "first run (fresh data and preferences; the HackRF is needed)"
osascript -e 'quit app "SDR TV"' >/dev/null 2>&1; pkill -f "SDR TV.app/Contents/MacOS" 2>/dev/null; sleep 2
defaults delete "$SUITE" >/dev/null 2>&1
rm -rf "$ROOT"; mkdir -p "$DATA"; write_finder
SDRTV_DATA_DIR="$DATA" SDRTV_DEFAULTS_SUITE="$SUITE" ATSC_DEBUG=1 "$APP" > "$LOG" 2>&1 &
PID=$!

wait_for 20 "introduction opens (page 1: welcome)" ui_find intro.next
if [ "${SKIP:-}" = 1 ]; then                 # an experienced user: skip straight to the scan
press intro.skip
else
press intro.next
wait_for 10 "page 2: connecting the HackRF, which is detected" device_ok
press intro.next
wait_for 5 "page 3: the antenna" ui_find intro.back
press intro.next
wait_for 5 "page 4: Scan for Channels offered" ui_find intro.scan
press intro.scan
fi
wait_for 15 "the scan starts" ui_find setup.stop
wait_for 180 "scan finishes and saves the channel list" scan_done
has_channels && pass "channels found: $(python3 -c "import json; c=json.load(open('$DATA/channels.json')); print(len(c), 'channels,', sum(1 for x in c if not x.get('hidden')), 'shown')")" || bad "no channels found"
wait_for 10 "Start Watching offered" ui_find setup.startWatching
press setup.startWatching
wait_for 20 "picture and sound start" playing
wait_for 60 "online guide listings arrive" online_guide
wait_for 20 "last-seen snapshot saved" snapshot
kill -0 $PID 2>/dev/null && pass "still running (no crash)" || bad "the app quit or crashed"

kill $PID 2>/dev/null; sleep 1
defaults delete "$SUITE" >/dev/null 2>&1
[ $fail -eq 0 ] && { rm -rf "$ROOT"; echo "First run passed."; } || echo "First run FAILED (log and data kept in $ROOT)"
exit $fail
