# Execution prompt — Phase D4: chunked terrain, streaming and LOD

Paste this into a fresh session. It is an EXECUTION prompt, not a planning one: you are building
D4, then stopping at the user's drive checklist.

**PREREQUISITE — check this before writing any code.** Open `docs/PLAN-stages-ground-map.md` §9 and
confirm **D3 is ticked and drive-verified**. If it is not, STOP and tell the user. D3 owns
`StageGen`, `StageDef` and `StageArea`, and D4 replaces only `StageArea`'s BUILD step — so if the
generator is still being revised for feel, you would be chunking a road that is still moving.

---

Read `CLAUDE.md`, `docs/ROADMAP.md` and `docs/PLAN-stages-ground-map.md` before touching anything —
§0 has the working rules, §3.4 the research this phase rests on, §5 the phase specs, §7 the
regression surface, §8 the risks (3, 6 and 7 are yours), §9 the live status. They are the
authoritative project state. `CHANGELOG.md` 2026-08-28/29 is the D3 record; read the D3 entries,
because most of what bit D3 will bite D4 in a new costume.

**Execute Phase D4 ONLY**, exactly per §5 Phase D4, then stop at the user driving checklist. Do not
start D5, and do not touch the legacy map.

## What D4 is, and the one thing that makes it hard

The corridor around the active centreline becomes **chunks along `s`**, each owning a mesh (with
distance LOD) and a `HeightMapShape3D` collider, loading ahead of the car and unloading behind it
with hysteresis. That is what lifts stage length from D3's static ~900 m to the arc's 4–6 km target
(§1.2 answer 2), and it is a **build-step replacement, not a generator change** — `StageGen` should
need no edits at all. If you find yourself changing how the road is *shaped*, you have wandered out
of this phase.

**Collider cooking is the cost, and it is a SPIKE, not a steady load.** `terrain.gd` already
throttles its re-cooks to 0.1 s for exactly this reason, at small scale. At 150 km/h the car covers
42 m/s, so the cook must finish far enough ahead that the spike never lands under a wheel. **Lead
distance is derived from speed, never a constant.** An average frame time will look perfect while
the car takes a 30 ms hit every 200 m — §5 probe 1 exists because of this, and it measures the
WORST frame and where it happened, not the mean.

## The trap that got D3 three times, in the costume it will wear here

**Non-uniform sample spacing silently breaks every stencil.** D3 hit this three separate times:

1. The Catmull-Rom fit had degenerate end segments (missing phantom endpoints), leaving one 22 m gap
   in an otherwise 1.2 m polyline. That gap then broke the grade limiter, because it smooths against
   neighbours and cannot cope with a 20× spacing jump.
2. The run-up/runoff extensions used a fixed 4 m step against the road's own ~1.6 m samples. That
   2.4× jump at the two joins produced **4.70 g of wheel acceleration at 108 km/h against the rally
   loop's 1.10 g**, from nothing but the joins.
3. `_fit_spline` used a fixed 18 samples per control segment — a number tied to a control spacing
   that had since been retired — so halving the spine step made the spline 9× denser and generation
   went from seconds to minutes.

**A chunk boundary IS a spacing discontinuity by construction.** Every stencil that runs across one
— normals, LOD skirts, the ground map's blends, anything differencing neighbours — is a candidate
for the same failure. §5 probe 3 (seam continuity) is the direct defence; treat it as the phase's
central probe, not a formality.

## The other thing no probe in this repo can see

**A height-field measurement cannot see a mesh artefact.** D3's "jagged edges where the ground meets
the track" survived several rounds of measuring the height *function* — which was fine — because the
defect was in the *mesh*: a 7.5 m road on a 2.25 m grid is about three vertices across, so its edges
stair-step no matter how smooth the underlying function is. A screenshot found it in one look, and
`area_cells` 320 → 512 (1.41 m/cell) fixed it.

**Consequence for you: chunking must not silently coarsen the corridor.** If chunk meshes end up at
a lower resolution than 1.41 m/cell near the road, the jagged edges come straight back and no probe
here will tell you. **Photograph the road, from above and from the driver's eye, before and after.**
`[[rally-sim-screenshot-verification]]` is the house rule: capture a PNG and read pixels before
reasoning about shader or normal maths.

## Context the plan text predates

- **D3 built the stage as its own node** (`scripts/stage_area.gd`, a `StaticBody3D`), not inside
  `stage.gd` as §5's file list says — because D5's area manager loads and unloads whole areas, and
  folding it into `stage.gd` would have to be undone. D4's `stage_chunks.gd` therefore belongs
  *inside* `StageArea`, replacing its `_build()`, and §5's mention of `stage.gd` should be read as
  "the area's build step".
- **`StageArea` currently rebuilds the ENTIRE area** when a Tab stage-parameter changes (debounced
  0.55 s, `_regenerate()`). That is fine for one 720 m box and impossible for a streamed 6 km
  corridor. Decide deliberately what a live seed change means under streaming — most likely "drop
  all chunks and re-stream from the car's position" — and say so in the code.
- **The corridor occupancy mask is load-bearing for build cost.** `StageArea._mark_corridor()`
  exists because asking `nearest_point()` about all 103k terrain vertices took the build from
  instant to minutes: for a vertex 500 m from the road the (provably correct) expanding-ring search
  runs ~38 rings before it can stop. Chunks are corridor-local, which should make this cheaper, but
  **re-measure rather than assume** — and note the ring search was made provably correct on
  2026-08-28 precisely because the old fixed 3×3 was wrong at 9.85% of road-edge positions.
- **§8 risk 6 is now partly measured.** `nearest_point` costs 0.018 ms/tick on the centre line,
  0.046 at the road edge and 0.071 at the shoulder (4 wheels, against the 1.84 ms budget) on a
  ~1 km centreline. At 6 km the grid has more cells but the same occupancy per cell, so the cost
  should hold — **assert that, it is the assumption the whole arc rests on.**
- **§8 risk 7 (erosion) is NOT implemented.** §3.3 wants erosion baked per seed into a coarse
  control grid, with per-chunk detail as pure positional noise. D3 named it a seam and shipped plain
  fBm. You may keep it that way — but if you add erosion, bake it per seed **before** chunking, or
  chunk generation stops being order-independent and §5 probe 4 will catch you.
- **§8 risk 2's stance is satisfied empirically.** It said no terrain-adding phase ships until the
  bottoming re-measurement exists. The user drove SHAKEDOWN on 2026-08-29 and reported **the car
  does not bottom out**, and the vertical input measures at 0.65–1.06 g peak against the rally
  loop's 1.10 g. B3's hydraulic bump-stop revision is still outstanding and is still NOT this
  phase's job — but re-run the bottoming numbers over the full streamed stage anyway, because 6 km
  of terrain is a bigger sample than 900 m.

## Working rules for this session

- Compile gate: `./check.sh` must print `✅ Godot check clean` after every edit. It no-ops when
  nothing under `scripts/` is newer than its marker — `rm -f .last_check` to force a real run.
  **It only sees scripts the running game actually loads**: a new file that nothing instantiates
  yet can be badly broken and still pass. Check a not-yet-wired script directly with
  `godot --headless --path . --check-only --script res://scripts/<file>.gd`.
- **A new `class_name` script is not resolvable until the global class cache is rebuilt** —
  `Foo.new()` fails with *"Nonexistent function 'new' in base 'GDScript'"* even though the file
  parses. Run `godot --headless --path . --import`, then re-check. This bit D1 and will bite you.
- Validate with temporary headless print-probes, then REMOVE them (script AND the `world.gd`
  block). Harness pattern is in §0. For anything needing driver input, the probe node MUST sit
  before the car in the tree (`move_child(probe, 0)`).
- **Probe hygiene:** measure HORIZONTAL ground speed (`Vector2(v.x, v.z).length()`), never
  `linear_velocity.length()`. Bound every probe so it stops before it leaves the road, and make
  every wait condition match FAILURE as well as success or it will poll forever.
- **A synthetic autopilot is not a driver.** D3's could not drive either road representatively —
  the RALLY LOOP reference run spent 1103 of 2400 frames off the road. If you need a driven
  measurement and the autopilot cannot deliver one honestly, say so and defer that half to the
  drive test rather than publishing a number a bad driver produced. D4 probe 1 genuinely needs the
  car moving at speed, so budget real effort for the autopilot or drive it yourself via the user.
- **Derive bounds, never pick them.** Search caps, lead distances, hysteresis margins and taper
  lengths all get derived from something physical, with the derivation in a comment. D3 has four
  worked examples (min radius from design speed, vertical curvature from AASHTO comfort, taper
  length from `sqrt(6A/kmax)`, ring cap from grid extent). A picked constant that was right once is
  how `_mf_peak_u` silently produced wrong physics.
- New tunables = `@export` vars + a row in `tuning_panel.gd` `_specs` **and a HELP line in the same
  commit**. The panel binds VEHICLE properties only, so a tunable on another node must be mirrored
  onto `vehicle_m2.gd` and synced — see `stage_seed` / `stage_sinuosity` for the pattern. Put the
  distinguishing word at the FRONT of the label.
- Update `CHANGELOG.md` when the phase closes or a measured finding changes what we believe. Write
  entries to be GREPPED: name the symptom in driving words, and record the numbers.
- You cannot verify feel. Leave the D4 checkbox unticked with "awaiting drive verdict" and hand over
  the driving checklist.
- **Check `git log` before committing** — other sessions work in this repo concurrently and have
  swept unrelated work into commits before. Stage your own files explicitly; never `commit -a`.
- When the gate is clean, commit and push to origin/main (`github.com/sagizarbel-cloud/rally-sim`).

## Probes this phase must run (pass conditions in §5 Phase D4)

1. **Frame-time SPIKES, not averages.** Drive the full stage at speed; record the worst physics-frame
   time and the position it happened at, against the 1.84 ms/tick baseline. Pass: no spike lands
   while a wheel is on a newly-cooked chunk, and the worst frame stays inside budget.
2. **Memory ceiling.** Peak resident chunk count and collider memory over a full run. Assert the
   ceiling is FLAT — bounded, not growing with distance travelled. A leak here is invisible over
   900 m and fatal over 6 km.
3. **Seam continuity.** Sample `height_at` and the ground map on both sides of every chunk boundary:
   no step, no gap, no normal discontinuity. **This is the phase's central probe** — see the
   spacing-discontinuity trap above.
4. **Order independence.** Drive the stage forwards, then backwards; every chunk's heights and
   ground-map values must be identical either way. This is what proves chunk generation is a pure
   function of position and seed rather than of load order.
5. **Bottoming, re-measured over the full stage** against B3's rally-loop baseline (4/4 corners
   pegged, 177 frames on the stops, peak Fz 23.1 kN). Not in §5's list; added because 6 km of
   terrain is a far bigger sample than the 900 m the user drove, and §8 risk 2 says every
   terrain-adding phase re-runs it.

## User drive checklist

- [ ] Driving the full stage at speed produces no hitch, stutter or pop-in you can feel.
- [ ] No visible seam or step where chunks meet, including on crests.
- [ ] Turning round and driving back gives you exactly the road you just drove.
- [ ] FPS holds.
- [ ] The road still looks right at the edges — no return of the stair-stepping D3 fixed.

## State of the tree

Arc A, Arc B and Arc C complete and drive-verified. Arc D: **D1 (ground map) and D2 (timing, notes
and wear on arc length) are DONE and drive-verified; D3 (the stage generator) is built and its
latest revision is awaiting the user's re-drive** — confirm §9 before starting.

The project has **SHAKEDOWN**, a generated point-to-point stage on the fourth `[B]` entry: ~900 m
timed plus a 45 m run-up and an 80 m runoff, in its own 720 m area at origin `(0, 0, -3000)`,
1.41 m/cell, with a 154° hairpin, berms and ruts, and 10.7 corners/km that `pace_notes.gd` reads as
a road book. It grips, sounds, throws dust, lays wear and gets pace notes **without any of those
systems knowing it exists** — that is what D1's ground-map layers and D2's centrelines bought, and
D4 must not spend it. Physics 120 Hz, ~1.84 ms/tick measured; the ground map costs 0.272 ms/tick
inside the generated area and is free on the legacy map.

Every export you meet on the car is a drive-verified calibration value, not a default to improve on.
The legacy map — three circuits, centre patch, 4 km drag strip — is the calibration bed and stays
untouched (§1.1). Arc D is additive; a change that can only be made by editing the existing
circuits' geometry is out of scope for the whole arc.

`CHANGELOG.md` is the forensic history — grep it by SYMPTOM before diagnosing anything that smells
like a recurrence.
