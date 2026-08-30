#!/usr/bin/env bash
# Headless compile/parse gate for the rally-sim Godot project.
# No-ops instantly when no .gd files changed since the last clean check (so it's cheap to run every turn).
set -u
# Override with:  GODOT=/path/to/godot ./check.sh   (default = this Mac's install)
# Search the known install locations rather than hard-coding one. The app moved from Downloads to
# /Applications on 2026-08-29 and the gate went quiet - see below for why that was dangerous.
if [ -z "${GODOT:-}" ]; then
	for _g in \
		"/Applications/Godot.app/Contents/MacOS/Godot" \
		"/Users/sgyzrbl/Downloads/Godot.app/Contents/MacOS/Godot" \
		"$HOME/Applications/Godot.app/Contents/MacOS/Godot"; do
		if [ -x "$_g" ]; then GODOT="$_g"; break; fi
	done
fi
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="/Users/sgyzrbl/rally-sim"
MARKER="$PROJ/.last_check"
cd "$PROJ" || exit 0

# skip if nothing under scripts/ changed since the last clean check
if [ -f "$MARKER" ] && [ -z "$(find scripts -name '*.gd' -newer "$MARKER" 2>/dev/null)" ]; then
	exit 0
fi

if [ ! -x "$GODOT" ]; then
	# FAIL, do not skip. This used to `exit 0`, so when the Godot app moved the compile gate
	# silently reported success: every `./check.sh && <next step>` chain sailed straight through
	# with nothing verified. A gate that passes when it cannot run is worse than no gate at all.
	# Remote sessions that genuinely cannot run Godot (claude.ai/code) set GODOT_SKIP=1 and get
	# the old behaviour, explicitly and on purpose.
	if [ -n "${GODOT_SKIP:-}" ]; then
		echo "check.sh: Godot not found at $GODOT - SKIPPED (GODOT_SKIP set); NOTHING WAS VERIFIED" >&2
		exit 0
	fi
	echo "❌ check.sh: Godot not found at $GODOT - compile gate could NOT run." >&2
	echo "   Set GODOT=/path/to/Godot, or GODOT_SKIP=1 if this machine cannot run it." >&2
	exit 1
fi

OUT="$("$GODOT" --headless --path "$PROJ" --quit-after 60 2>&1)"
ERRS="$(printf '%s\n' "$OUT" | grep -iE 'SCRIPT ERROR|Parse Error|Failed to load|Invalid call|nonexistent|Cannot infer')"
if [ -n "$ERRS" ]; then
	echo "❌ Godot check FAILED:" >&2
	printf '%s\n' "$ERRS" | head -20 >&2
	exit 2
fi
touch "$MARKER"
echo "✅ Godot check clean"
exit 0
