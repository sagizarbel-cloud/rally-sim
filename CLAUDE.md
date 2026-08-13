# Rally Sim — project instructions

Native Apple-Silicon (M1) realistic rally sim, **Godot 4.4 + Jolt**, built procedurally in code (no `.tscn` editing for gameplay). Full milestone state, decisions, and working patterns live in **`docs/ROADMAP.md` — read it first.**

## Verify every code change (headless)
After editing `.gd` files, run **`./check.sh`** (or the command below). It must print no errors:
```bash
"/Users/sgyzrbl/Downloads/Godot.app/Contents/MacOS/Godot" --headless --path /Users/sgyzrbl/rally-sim --quit-after 60 2>&1 | grep -iE "SCRIPT ERROR|Parse Error|Failed to load|Invalid call|nonexistent|Cannot infer"
```
I verify that code **compiles/loads**; the **user drives to test feel** (grip, handling, sound). I cannot verify feel headlessly — don't claim a feel change works, ask the user to test it.

## Conventions
- **Functions over constants**: improve realism/fun via physical functions, not by tuning magic-number constants. Always prefer a physical model, and say so.
- Expose new tunables as `@export` vars; add sliders to `tuning_panel.gd` (Tab in-game) when useful.
- Validate geometry/detection with a temporary `print()` probe, then REMOVE it before finishing.
- **Update `CHANGELOG.md`** when a plan phase closes, a bug is fixed, or a measured finding changes what we believe about the car — including the user's drive verdicts, which are otherwise lost in chat. `docs/ROADMAP.md` stays the authoritative state; the changelog is how it got there.

## GDScript / Godot gotchas (these cause real bugs)
- **Tabs, not spaces** for indentation — never mix.
- `:=` CANNOT infer a type from a Variant (`dict[key]`, untyped `stage.*` calls, `Array` elements) → use `var x: Type = ...`.
- Unshaded `StandardMaterial3D` ignores emission → toggle `albedo_color` instead.
- macOS has NO `timeout` command → use Godot's `--quit-after N` (N = FRAMES).
- Controllers: the **PS4 DualShock 4 IS detected** (confirmed driving since 2026-08-09) — analog throttle/brake are live and bypass the virtual-pedal shaping, pad layout in `world.gd` `_setup_input()`. The **wired Xbox One pad is still not detected** on Godot 4/macOS (engine bug). The HUD `input` line names whichever pad is live.

## Key files (scripts/)
- `world.gd` — bootstrap + wiring, input map, environment / time-of-day.
- `vehicle_m2.gd` — the car: slip-ratio drivetrain, combined-slip tyre (already has a friction ellipse), tyre thermal/wear/puncture, damage.
- `stage.gd` — procedural terrain: dirt rally loop, asphalt ring, centre deformable patch, drag strip, collidable obstacles.
- `time_trial.gd` — 3-circuit lap timing + ghost + sector splits.
- `pace_notes.gd` · `wear.gd` · `sound.gd` · `hud.gd` · `component_hud.gd` · `terrain.gd` · `tuning_panel.gd`.
