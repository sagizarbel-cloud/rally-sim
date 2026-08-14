# Rally Sim — project instructions

Native Apple-Silicon (M1) realistic rally sim, **Godot 4.4 + Jolt**, built procedurally in code (no `.tscn` editing for gameplay). Full milestone state, decisions, and working patterns live in **`docs/ROADMAP.md` — read it first.**

## Verify every code change (headless)
After editing `.gd` files, run **`./check.sh`** (or the command below). It must print no errors:
```bash
"/Users/sgyzrbl/Downloads/Godot.app/Contents/MacOS/Godot" --headless --path /Users/sgyzrbl/rally-sim --quit-after 60 2>&1 | grep -iE "SCRIPT ERROR|Parse Error|Failed to load|Invalid call|nonexistent|Cannot infer"
```
I verify that code **compiles/loads**; the **user drives to test feel** (grip, handling, sound). I cannot verify feel headlessly — don't claim a feel change works, ask the user to test it.

## Naming the three circuits — use these exact names
`time_trial.gd` holds the canon: **DIRT CIRCLE** (the centre skid-pad inside the deformable
patch), **RALLY LOOP** (the main winding loop — the one nearly every measurement in this project
is taken on), **ASPHALT RING** (the outer circuit). Say **"rally loop"**, never "dirt loop":
there is a separate dirt circle, so "dirt loop" reads as that one and has caused real ambiguity.
`get_spawn_for(0/1/2)` follows the same order.

## Conventions
- **Functions over constants**: improve realism/fun via physical functions, not by tuning magic-number constants. Always prefer a physical model, and say so.
- Expose new tunables as `@export` vars; add sliders to `tuning_panel.gd` (Tab in-game) when useful.
- Validate geometry/detection with a temporary `print()` probe, then REMOVE it before finishing.
- **Update `CHANGELOG.md`** when a plan phase closes, a bug is fixed, or a measured finding changes what we believe about the car — including the user's drive verdicts, which are otherwise lost in chat. `docs/ROADMAP.md` stays the authoritative state; the changelog is how it got there. **It is a forensic tool** — when something breaks or an old bug returns, GREP IT FIRST for hints before touching code, and write every entry so that works: name the symptom in driving words ("pogos above 400 km/h", "inside rear cooking on gentle turns"), not just the fix, and record the measured numbers so a recurrence is recognisable when they drift back.

## Surface-effect names - use these EXACTLY, never mix them
Four separate effects, four separate systems (`scripts/effects.gd`). They have been confused
before; the user named them so that a future session cannot blur them together:

| Name | Surface | What it is | LAYERS key |
|---|---|---|---|
| **asphalt smoke** | tarmac | white-grey burnt rubber from long drifts, spinouts, hard stops | `smoke` |
| **asphalt tire tracks** | tarmac | the dark rubber marks laid on the road (a MultiMesh, not particles) | marks |
| **dirt/dust plumes** | gravel/dirt | the big billowing dust cloud the car trails | `plume` |
| **dirt/gravel particles** | gravel/dirt | small stones and sand thrown ballistically from the tyre | `gravel` |

Never call the plume "smoke", never call the gravel particles "dust", and never call the tire
tracks "skid marks" in a way that could be read as the dust layer. When the user reports a problem
with one of these, confirm WHICH of the four before changing anything - the fixes are unrelated.

## GDScript / Godot gotchas (these cause real bugs)
- **Tabs, not spaces** for indentation — never mix.
- `:=` CANNOT infer a type from a Variant (`dict[key]`, untyped `stage.*` calls, `Array` elements) → use `var x: Type = ...`.
- Unshaded `StandardMaterial3D` ignores emission → toggle `albedo_color` instead.
- macOS has NO `timeout` command → use Godot's `--quit-after N` (N = FRAMES).
- Controllers: the **PS4 DualShock 4 IS detected** (confirmed driving since 2026-08-09) — analog throttle/brake are live and bypass the virtual-pedal shaping, pad layout in `world.gd` `_setup_input()`. The **wired Xbox One pad is still not detected** on Godot 4/macOS (engine bug). The HUD `input` line names whichever pad is live.

## Key files (scripts/)
- `world.gd` — bootstrap + wiring, input map, environment / time-of-day.
- `vehicle_m2.gd` — the car: slip-ratio drivetrain, combined-slip tyre (already has a friction ellipse), tyre thermal/wear/puncture, damage.
- `stage.gd` — procedural terrain: rally loop, asphalt ring, dirt circle (centre deformable patch), drag strip, collidable obstacles.
- `time_trial.gd` — 3-circuit lap timing + ghost + sector splits.
- `pace_notes.gd` · `wear.gd` · `sound.gd` · `hud.gd` · `component_hud.gd` · `terrain.gd` · `tuning_panel.gd`.
