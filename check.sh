#!/usr/bin/env bash
# Headless compile/parse gate for the rally-sim Godot project.
# No-ops instantly when no .gd files changed since the last clean check (so it's cheap to run every turn).
set -u
GODOT="/Users/sgyzrbl/Downloads/Godot.app/Contents/MacOS/Godot"
PROJ="/Users/sgyzrbl/rally-sim"
MARKER="$PROJ/.last_check"
cd "$PROJ" || exit 0

# skip if nothing under scripts/ changed since the last clean check
if [ -f "$MARKER" ] && [ -z "$(find scripts -name '*.gd' -newer "$MARKER" 2>/dev/null)" ]; then
	exit 0
fi

if [ ! -x "$GODOT" ]; then
	echo "check.sh: Godot not found at $GODOT (skipping)" >&2
	exit 0
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
