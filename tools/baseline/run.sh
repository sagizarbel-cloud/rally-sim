#!/bin/bash
# Engine-migration baselines: run every headless test of tools/baseline/capture.gd with one Godot
# binary and write the results to one directory. Same tree, two binaries, then diff:
#   GODOT=/Applications/Godot.app/Contents/MacOS/Godot  tools/baseline/run.sh /tmp/bl-4.4
#   GODOT=/Applications/Godot_4.6.3.app/Contents/MacOS/Godot tools/baseline/run.sh /tmp/bl-4.6
#   python3 tools/baseline/compare.py /tmp/bl-4.4 /tmp/bl-4.6
# JOBS=N runs N tests at once (default 2). The screenshots need a window: see capture.gd.
set -u
OUT="${1:?usage: run.sh OUT_DIR}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
JOBS="${JOBS:-2}"
cd "$(dirname "$0")/../.."
mkdir -p "$OUT"
"$GODOT" --version > "$OUT/engine.txt" 2>&1
one() {
	local t="$1" c="${2:-}"
	BL_TEST="$t" BL_CIRCUIT="$c" BL_OUT="$OUT" "$GODOT" --headless --path . --fixed-fps 120 \
		--script res://tools/baseline/capture.gd > "$OUT/log_${t}${c}.txt" 2>&1
	grep -h "^BASELINE" "$OUT/log_${t}${c}.txt" || echo "FAILED $t$c (see $OUT/log_${t}${c}.txt)"
}
export -f one
export OUT GODOT
printf '%s\n' "drag" "pogo" "skid" "lap 0" "lap 1" "lap 2" "stream" "lattice" \
	| xargs -P "$JOBS" -I{} bash -c 'one {}'
