# Planning prompt — Arc D: the ground map & real stages

You are the planning agent for `/Users/sgyzrbl/rally-sim`. Your job this session is to WRITE A
PLAN, not to write code. The executor is a fresh Opus session per phase with no memory of this
conversation, so the plan must be self-contained and readable top-to-bottom.

## Deliverable

`docs/PLAN-stages-ground-map.md` — a phased plan for **Arc D: the ground map and real stages**,
plus an explicit list of the amendments Arc D forces on **Arc C1** (already specified but NOT yet
built). Match the structure, voice and rigour of the existing
`docs/PLAN-drivetrain-suspension.md`: numbered sections, a phase-map table, per-phase
Files / Mechanism / Compile gate / Headless probes / User drive checklist, a regression-surface
section, a risks section, and a §9 phase-status checklist the executor ticks off.

## Read first (do not plan from this prompt alone)

1. `CLAUDE.md` — house rules and the GDScript gotchas that cause real bugs here.
2. `docs/ROADMAP.md` — milestone state; note M6 Phase 2, M10's deferred multi-stage sequence,
   M11 dust, M12 rivals.
3. `docs/PLAN-drivetrain-suspension.md` — **§0 how to work**, **§4 phase map**, **§5 Phase C1**
   (read in full — it is the foundation this arc builds on), **§6 regression surface**,
   **§7 risks**, **§9 status**.
4. The code that Arc D touches: `scripts/stage.gd`, `terrain.gd`, `wear.gd`, `pace_notes.gd`,
   `time_trial.gd`, `world.gd`, and the suspension raycast block of `vehicle_m2.gd`.

## What the user asked for

**Better maps — real stages worth learning — built on the ground mapping Arc C introduces.**

Arc C1 adds a procedural roughness FIELD keyed to world position: ISO-8608 broadband texture per
surface class, a coherent washboard term placed by `wear.gd`'s braking/curvature mask, and a
tyre-enveloping filter, injected at the suspension raycast hit distance. That field is the first
real instance of "the ground is a queryable function of position" in this project. Arc D's thesis
is that this should not stay a one-off: it should become **one authority for what the ground IS at
any (x, z)** — surface class, roughness class, deformability, grip, colour, audio — and the stages
should be built on top of that authority rather than beside it.

## Measured current state (verified 2026-08-12 — use these facts, don't re-derive them)

- **The world is one 720 m square, 320² cells = 2.25 m/cell** (`stage.gd:10-11`), hills at
  `hill_octaves 2` (`stage.gd:14`). Nothing below 2.25 m exists geometrically outside the centre
  deformable patch. This is exactly why C1 exists.
- **Every road is polar: `r = f(θ)` around the origin.** `_road(θ)` (dirt loop), `_asphalt_r(θ)`
  (asphalt ring), a centre skid pad, and a drag-strip spur. All three circuits are concentric and
  share the θ=0 finish ray.
- **Every downstream system is hard-wired to that polar form**, and this is the single biggest
  structural fact of the arc:
  - `time_trial.gd` detects laps and sectors by `atan2` crossings, disambiguating circuits by
    disjoint radius bands `RMIN/RMAX` (`time_trial.gd:17-18`), sectors by θ-thirds.
  - `pace_notes.gd` builds each route by sampling `θ ∈ [0, TAU)` and calling `_road`/`_asphalt_r`
    (`pace_notes.gd:50-57`).
  - `wear.gd` indexes its wear grid as `[arc_sample × lat_bin]` over `θ` (`wear.gd:49-53`).
  - `grip_at(x, z)` (`stage.gd:184`) classifies surface by polar distance tests.
  - The stage's whole public API is tiny: `grip_at`, `_height`, `_road`, `_road_halfwidth`,
    `_asphalt_r`, `_circuit_r`, `get_spawn`, `get_spawn_for`.
- **`terrain.gd` deformable terrain works but is wired only to the centre patch**, not to the
  stage corridor (roadmap M6 Phase 2).
- **The drag strip is 4 km** (2026-08-12): `strip_len` derives `strip_x1 = 4285`, with distance
  posts every 100 m down both shoulders, a billboard call-out each kilometre, and a W-beam
  guard-rail arc round the far lip of the runoff pad (`_guard_rail(polyline)` in `stage.gd` lays
  panels + posts along any polyline and is reusable for new areas). Note the world is therefore
  already not a 720 m square — the strip spurs far outside the heightmap, on flat slabs.
- **Physics runs at 120 Hz with large headroom on the M1** — 1.84 ms/tick measured at Phase 0.
- **Arc B is mid-flight:** B1 implemented and awaiting the user's drive verdict, B3 done, B2/B4/B5
  open. **B3 left an open item:** all four corners peg 100% of suspension travel on the dirt loop
  at 100 km/h because B1's softer springs took static sag 7.7 → 12.7 cm. C1 will make that worse,
  and Arc D's terrain choices (crests, jumps, ruts, ditches) will make it worse again. Any stage
  feature that adds vertical input must be planned against that budget, not on top of it blindly.

## Settled decision — do not reopen it, plan around it

**New maps go in a NEW area; the existing map is preserved untouched as the test and
calibration bed** (user's call, 2026-08-12). The three concentric circuits, the centre
deformable patch and the 4 km drag strip stay exactly as they are, because every calibration
baseline this project has is expressed in their terms — 259 km/h in 6th down the strip,
dirt-loop lap feel, B3's bottoming statistics at 100 km/h on the dirt loop, A2's coast-down
figures. A new stage that modified them would silently invalidate the entire regression surface
mid-arc.

Consequences the plan must carry:
- The world has to host **more than one area**. Decide and justify the mechanism: distinct
  regions in one coordinate space (the drag strip already spurs out to x = 4285, so the world is
  not really 720 m square any more), versus a stage manager that builds one area at a time
  (roadmap M10's deferred "multi-stage sequence"). Say what each costs in load time, collider
  memory and how the player moves between them.
- `stage.gd` currently hardcodes ONE stage's geometry. Whatever comes next needs the stage to
  become a thing you can have several of — but the old map's numbers must not shift by even a
  metre when that refactor lands. Name the probe that proves it: same spawn transforms, same
  `grip_at` classification, same `_height` samples at a fixed set of world positions, before and
  after.
- Every new-area feature is therefore additive. A change that can only be made by editing the
  existing circuits' geometry is out of scope for this arc.

## Interview the user BEFORE writing the plan

Ask these as one batched set of questions, take the answers, then write. Do not guess your way
past them — each one changes the shape of the arc. Record each answer and its date in the plan,
the way the existing plan records its 2026-08-02 interview and its 2026-08-11 ordering decision.

1. **Topology.** Real point-to-point rally stages (start → finish, no lap), enriched loops, or a
   stage manager where both coexist? Point-to-point is what "rally stage" means and is where pace
   notes finally pay off — but it forces the arc-length refactor below and rewrites how lap timing
   works.
2. **Authoring.** Seeded-procedural generation from stage parameters (length, sinuosity, surface
   mix, elevation character), authored control points checked into a data file, or imported
   heightmaps? Ask which one the user wants to be steering with.
3. **Scale and streaming.** A real special stage is 5–15 km. Today's world is 720 m square with a
   single static heightmap collider. How long does the user actually want, and are they willing to
   pay for chunk streaming to get it?
4. **Surface palette.** Which surfaces earn their place: gravel, tarmac, mixed-surface transitions,
   mud, snow/ice, sand, tarmac cut up by gravel dragged onto it? Each one is a ground-map class
   AND a C1 road class AND a grip/audio/particle entry.
5. **Reaching the new area.** Given the settled decision above: drive to it through a connecting
   road, teleport/select it from a menu or key, or load it as a separate world? Ask — it decides
   whether the areas share one coordinate space.
6. **Deformable ruts on the stage** (roadmap M6 Phase 2, `terrain.gd` along the driven corridor):
   in Arc D or deferred again?
7. **Ordering against Arc C.** Recommend C1 lands first — its mechanism is the ground-map
   primitive and its spec is already written — with Arc D then generalising the field into a map.
   Confirm, and record the consequence either way (as §4 of the existing plan does for C1 vs Arc B).

## The plan must resolve these, explicitly

- **The centreline abstraction.** Point-to-point stages mean roads are no longer `r = f(θ)`. Design
  the replacement — a sampled spline with arc-length parameterisation `s`, plus a
  `nearest_point(x, z) -> {s, lateral_offset, heading, curvature, width}` query — and then account,
  system by system, for what that costs `time_trial.gd` (start/finish/split triggers instead of
  angle crossings), `pace_notes.gd` (already samples a centreline — should get cheaper, not
  harder), `wear.gd` (already indexes by arc sample — should map over cleanly) and `grip_at`. Say
  plainly which of these is a genuine rewrite and which is a re-parameterisation.
- **The ground map itself.** One lookup — surface class, roughness/road class, deformability,
  grip, colour, audio key — that `grip_at`, C1's roughness field, `sound.gd`, `terrain.gd` and the
  particle work of M11 all read from, instead of each re-deriving surface from geometry tests.
  State the amendments to C1 this implies: its per-surface exports (`road_class_gravel`,
  `road_class_tarmac`, the washboard terms) become per-position lookups with the exports as class
  defaults.
- **Repeatability.** C1's third probe demands identical field values at the same world position
  across frames and respawns, because a stage that isn't repeatable isn't learnable. Everything
  Arc D generates must hold the same property — seeded, positional, no per-frame RNG.
- **The vertical budget.** Crests, jumps, compressions, ditches and ruts all spend the suspension
  travel B3 says is already exhausted. The plan must carry an explicit stance rather than
  discovering this per phase.
- **Performance.** Chunked heightmap colliders, mesh LOD, what streams and when, and a measured
  budget against the 1.84 ms/tick baseline. Name the probe that measures it.

## House rules the plan must obey and restate

- **Functions over constants.** Every behaviour from a physical or geometric model with meaningful
  tunables, not tuned magic numbers. This is the user's first principle — a "stage generator" made
  of hand-picked seeds and hand-placed bumps violates it, and the plan should say what the
  principled version looks like instead.
- **Everything procedural in code.** No `.tscn` editing for gameplay; `main.tscn` stays near-empty.
- **Compile gate:** `./check.sh` must print `✅ Godot check clean` after every edit. It proves
  loading, nothing about feel.
- **Feel gate:** every phase ends with a user drive checklist. The user is the only feel-verification
  instrument this project has. Never mark a phase done on a clean compile.
- **Headless probes** per phase, each with a stated pass condition and a note to delete the probe
  afterwards (probe-harness pattern in §0 of the existing plan).
- New tunables: `@export` on the node + a row in `tuning_panel.gd` `_specs`.
- Keyboard must keep working; the PS4 DualShock 4 is live and analog.
- Phases sized S/M/L, ordered so each one leaves the game fully drivable, and each one is a single
  executor session's work.

## Regression surface — name what must not break

At minimum: lap timing and ghosts on all three circuits, sector splits, pace notes on both routes,
the wear line and its grip effect, the deformable centre patch, the rear-view mirror overlay, the
HUD and component HUD, time-of-day, spawn/respawn for every circuit, the drag-strip top-speed run,
and the drive-mode/diff-preset controls. Cross-check against §6 of the existing plan and extend it.

## Research expectations

Match the citation standard of the existing plan's §3 — that section carries ISO 8608, MF-SWIFT
enveloping, Salisbury LSD and two-inertia driveline sources, each with a link and a "here's the
caveat" note. Bring the equivalent for this arc: road-geometry design (curve radius vs design
speed, superelevation, sight distance), procedural road/spline generation, terrain synthesis and
erosion, chunked terrain collision and LOD in Godot 4, and whatever exists on real special-stage
character. Where a source doesn't map cleanly onto a rally stage, say so — the existing plan's
honesty about ISO 8608's class-to-real-road gap is the standard to hit.

## Output

Write the file. Then post a short summary: the phase table, the decisions taken in the interview
with their consequences, and the single biggest risk you found. Do not start implementing.
