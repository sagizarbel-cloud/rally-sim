# Rally Sim — project instructions

Native Apple-Silicon (M1) realistic rally sim, **Godot 4.4 + Jolt**, built procedurally in code (no `.tscn` editing for gameplay). Full milestone state, decisions, and working patterns live in **`docs/ROADMAP.md` — read it first.**

## Verify every code change (headless)
After editing `.gd` files, run **`./check.sh`** (or the command below). It must print no errors:
```bash
"/Users/sgyzrbl/Downloads/Godot.app/Contents/MacOS/Godot" --headless --path /Users/sgyzrbl/rally-sim --quit-after 60 2>&1 | grep -iE "SCRIPT ERROR|Parse Error|Failed to load|Invalid call|nonexistent|Cannot infer"
```
I verify that code **compiles/loads**; the **user drives to test feel** (grip, handling, sound). I cannot verify feel headlessly — don't claim a feel change works, ask the user to test it.

## Naming the circuits and the stage — use these exact names
`time_trial.gd` holds the canon: **DIRT CIRCLE** (the centre skid-pad inside the deformable
patch), **RALLY LOOP** (the main winding loop — the one nearly every measurement in this project
is taken on), **ASPHALT RING** (the outer circuit). Say **"rally loop"**, never "dirt loop":
there is a separate dirt circle, so "dirt loop" reads as that one and has caused real ambiguity.
`get_spawn_for(0/1/2)` follows the same order.

**SHAKEDOWN** (added by Arc D's D3, 2026-08-28) is the fourth `[B]` entry and is **not a circuit —
it is a point-to-point STAGE**: a generated route with a start line and a finish line that ends
rather than wrapping. Say "stage", not "lap", about it; the HUD already switches to "run". It lives
in its own area well clear of the legacy map, which stays untouched as the calibration bed.

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
- **A NEW `class_name` script is not resolvable until the global class cache is rebuilt.** `Foo.new()` fails with *"Nonexistent function 'new' in base 'GDScript'"* even though the file parses, because this project never opens the editor. Fix: `"/Users/sgyzrbl/Downloads/Godot.app/Contents/MacOS/Godot" --headless --path . --import`, then re-run `./check.sh`.
- `:=` CANNOT infer a type from a Variant (`dict[key]`, untyped `stage.*` calls, `Array` elements) → use `var x: Type = ...`.
- **Terrain invisible from above but solid from below = TRIANGLE WINDING, not normals or shaders.** It has bitten this project twice (M5's stage, then D3's `stage_area.gd`). A grid quad must be wound `a,b,c` / `b,d,c` with `a=(i,j) b=(i+1,j) c=(i,j+1) d=(i+1,j+1)` so the TOP is the front face — copy the order from `stage.gd`, don't re-derive it. (Distinct from `cull_mode = CULL_DISABLED`, where a back-to-front face renders DARK rather than invisible.) Verify with a screenshot from above AND below before theorising.
- Unshaded `StandardMaterial3D` ignores emission → toggle `albedo_color` instead.
- macOS has NO `timeout` command → use Godot's `--quit-after N` (N = FRAMES).
- Controllers: the **PS4 DualShock 4 IS detected** (confirmed driving since 2026-08-09) — analog throttle/brake are live and bypass the virtual-pedal shaping, pad layout in `world.gd` `_setup_input()`. The **wired Xbox One pad is still not detected** on Godot 4/macOS (engine bug). The HUD `input` line names whichever pad is live.

## Key files (scripts/)
- `world.gd` — bootstrap + wiring, input map, environment / time-of-day.
- `vehicle_m2.gd` — the car: slip-ratio drivetrain, combined-slip tyre (already has a friction ellipse), tyre thermal/wear/puncture, damage.
- `stage.gd` — procedural terrain: rally loop, asphalt ring, dirt circle (centre deformable patch), drag strip, collidable obstacles.
- `ground_map.gd` — **the one authority for what the ground IS** at any (x, z): surface, road class, deformability, grip, colour, audio, composed of layers in priority order. Every surface question goes through it.
- `centreline.gd` · `stage_def.gd` · `stage_gen.gd` · `stage_area.gd` — arc-length centrelines (open or closed) and the SHAKEDOWN stage generator.
- `time_trial.gd` — 3-circuit lap timing + ghost + sector splits.
- `pace_notes.gd` · `wear.gd` · `sound.gd` · `hud.gd` · `component_hud.gd` · `terrain.gd` · `tuning_panel.gd`.
