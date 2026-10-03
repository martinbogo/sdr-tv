#!/bin/bash
# Regression checks, run before every install (macos/build.sh --install).
# Recordings live in captures/ (not in git); checks whose recording is missing are skipped.
#   SDR TV receiver: lock time and quality on known-good recordings
#   media layer: channels, guide, descriptions, video and audio from transport streams
#   channel list rules (Swift)
set -uo pipefail
cd "$(dirname "$0")/.."
FF=third_party/ffmpeg-install
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
fail=0
pass() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }
skip() { echo "  skip  $1 (no captures/$2)"; }

clang -O3 -mcpu=apple-m1 -ffast-math -Idsp -o "$OUT/test_acq" dsp/test_acq.c dsp/atsc_rx.c -framework Accelerate || exit 1
clang -O2 -mcpu=apple-m1 -I"$FF/include" -o "$OUT/test_media" dsp/test_media.c dsp/atsc_media.c dsp/atsc_captions.c \
    "$FF/lib/libavfilter.a" "$FF/lib/libswscale.a" "$FF/lib/libswresample.a" "$FF/lib/libavcodec.a" "$FF/lib/libavutil.a" \
    -framework CoreFoundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Security \
    -framework AudioToolbox -lz -liconv 2>/dev/null || exit 1

# receiver: file, minimum good trials of 8, maximum mean lock time, minimum SNR
acq() {
    local f=captures/$1 name=$2
    [ -f "$f" ] || { skip "$name" "$1"; return; }
    local r; r=$("$OUT/test_acq" "$f" 8 1.5 | grep RESULT)
    local good lock snr
    good=$(echo "$r" | sed -E 's/.*good=([0-9]+).*/\1/'); lock=$(echo "$r" | sed -E 's/.*meanlock=([0-9.]+).*/\1/')
    snr=$(echo "$r" | sed -E 's/.*minsnr=([0-9.-]+).*/\1/')
    if [ "$good" -ge "$3" ] && awk "BEGIN{exit !($lock <= $4 && $snr >= $5)}"; then
        pass "$name: $good/8 good, lock ${lock}s, SNR ${snr} dB"
    else bad "$name: $good/8 good (need $3), lock ${lock}s (max $4), SNR ${snr} dB (min $5)"; fi
}

# media: file, program, then minimums for channels, video frames, guide events, descriptions, rated events
media() {
    local f=captures/$1 name=$2
    [ -f "$f" ] || { skip "$name" "$1"; return; }
    local log; log=$("$OUT/test_media" "$f" "$3" "$OUT/frame.ppm" 2>&1)
    local nch v ev de ra
    nch=$(echo "$log" | sed -nE 's/^virtual channels \(([0-9]+)\).*/\1/p' | tail -1); nch=${nch:-0}
    v=$(echo "$log" | sed -nE 's/.* ([0-9]+) video frames.*/\1/p' | tail -1); v=${v:-0}
    ev=$(echo "$log" | sed -nE 's/.* ([0-9]+) guide events.*/\1/p' | tail -1); ev=${ev:-0}
    de=$(echo "$log" | sed -nE 's/.* ([0-9]+) descriptions.*/\1/p' | tail -1); de=${de:-0}
    ra=$(echo "$log" | sed -nE 's/.* ([0-9]+) rated.*/\1/p' | tail -1); ra=${ra:-0}
    if [ "$nch" -ge "$4" ] && [ "$v" -ge "$5" ] && [ "$ev" -ge "$6" ] && [ "$de" -ge "$7" ] && [ "$ra" -ge "$8" ]; then
        pass "$name: $nch channels, $v video frames, $ev guide events, $de descriptions, $ra rated"
    else bad "$name: $nch channels (min $4), $v frames (min $5), $ev events (min $6), $de descriptions (min $7), $ra rated (min $8)"; fi
}

echo "receiver"
acq kgw_now.iq "KGW, multipath" 8 0.15 24
acq rf25.iq "KOIN" 8 0.15 19

echo "media layer"
media ch26_20s.ts "KGW transport stream" 3 6 500 1800 1500 900
media rf25.ts "KOIN transport stream" 3 6 60 280 0 0

# dropouts: lose 300 packets every ~3 s; damaged frames must be held back and decoding must recover
if [ -f captures/ch26_20s.ts ]; then
    log=$(DROP_EVERY=40000 DROP_LEN=300 "$OUT/test_media" captures/ch26_20s.ts 3 "$OUT/frame.ppm" 2>&1)
    gaps=$(echo "$log" | sed -nE 's/^dropouts: ([0-9]+) stream gaps.*/\1/p'); held=$(echo "$log" | sed -nE 's/.* ([0-9]+) damaged frames.*/\1/p')
    v=$(echo "$log" | sed -nE 's/.* ([0-9]+) video frames.*/\1/p' | tail -1)
    if [ "${gaps:-0}" -ge 5 ] && [ "${held:-0}" -ge 1 ] && [ "${v:-0}" -ge 200 ]; then
        pass "KGW with dropouts: $gaps gaps, $held damaged frames held back, $v shown"
    else bad "KGW with dropouts: ${gaps:-0} gaps (min 5), ${held:-0} held (min 1), ${v:-0} shown (min 200)"; fi
else skip "KGW with dropouts" ch26_20s.ts; fi

# channel change speed: picture after a subchannel switch (from the keyframe cache) and from a cold start
if [ -f captures/ch26_20s.ts ]; then
    worst=0; for to in 4 5 6 7; do for at in 100000 160000 220000; do
        ms=$(SWITCH_AT=$at SWITCH_TO=$to "$OUT/test_media" captures/ch26_20s.ts 3 "$OUT/frame.ppm" 2>/dev/null | sed -nE 's/.*picture after (-?[0-9]+) ms.*/\1/p')
        [ "${ms:--1}" -lt 0 ] && ms=99999; [ "$ms" -gt "$worst" ] && worst=$ms
    done; done
    if [ "$worst" -le 50 ]; then pass "subchannel switch: picture within $worst ms (12 switches)"; else bad "subchannel switch: worst $worst ms (max 50)"; fi
    cold=$("$OUT/test_media" captures/ch26_20s.ts 3 "$OUT/frame.ppm" 2>/dev/null | sed -nE 's/^timing: first picture ([0-9]+) ms.*/\1/p')
    if [ "${cold:-99999}" -le 2500 ]; then pass "cold start: first picture after ${cold} ms of stream"; else bad "cold start: ${cold:-none} ms (max 2500)"; fi
else skip "channel change speed" ch26_20s.ts; fi

echo "channel list rules"
swiftc -O -parse-as-library -o "$OUT/library_tests" macos/Sources/Channels.swift tests/LibraryTests.swift 2>&1 | grep -E "error" && fail=1
if [ -x "$OUT/library_tests" ]; then
    SDRTV_DATA_DIR="$OUT/data" "$OUT/library_tests" | sed 's/^/  /' || fail=1
    [ "${PIPESTATUS[0]}" -eq 0 ] || fail=1
fi

[ $fail -eq 0 ] && echo "All checks passed." || echo "Some checks FAILED."
exit $fail
