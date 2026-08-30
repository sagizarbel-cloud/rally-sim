# PLAN — Arc D: The Ground Map & Real Stages

_Written 2026-08-13 by the planning agent. Executor: a fresh Opus session per phase, with no
memory of this conversation — so this document is self-contained. Read it top to bottom, then
execute ONE phase per session, in order. Do not skip the feel checkpoints: the user is the only
feel-verification instrument this project has._

---

## 0. How to work in this repo (read first)

Identical house rules to `docs/PLAN-drivetrain-suspension.md` §0. Restated because the executor
arrives cold:

- Project: `/Users/sgyzrbl/rally-sim` — Godot 4.4 + Jolt, native M1, everything built
  procedurally in code (**no `.tscn` editing for gameplay**; `main.tscn` stays near-empty).
  Read `CLAUDE.md` and `docs/ROADMAP.md` before starting any phase.
- **Compile gate after every edit:** `./check.sh` must print `✅ Godot check clean`. It proves
  the code loads and NOTHING about feel. Note it no-ops when nothing under `scripts/` is newer
  than its marker — `rm -f .last_check` to force a real run.
- **Feel gate:** every phase ends with a user drive checklist. Never mark a phase done on a
  clean compile.
- **Functions over constants:** every behaviour from a physical or geometric model with
  meaningful tunables, not tuned magic numbers. A "stage generator" made of hand-picked seeds
  and hand-placed bumps violates this — see §3.2 for what the principled version looks like.
- **Repeatability is a hard requirement in this arc.** Everything Arc D generates must be a
  pure function of world position and a stage seed. No per-frame RNG, no dependence on chunk
  load order, no dependence on the order the player drives through. A stage that is not
  repeatable is not learnable, and learnable is the entire point.
- New tunables: `@export` on the node + a row in `tuning_panel.gd` `_specs`.
- **GDScript gotchas:** tabs not spaces; `:=` cannot infer from a Variant (untyped `stage.*` or
  dict access → `var x: Type = ...`); unshaded `StandardMaterial3D` ignores emission; macOS has
  no `timeout` (use `--quit-after N`, N = frames).
- **Input:** keyboard must keep working; the PS4 DualShock 4 is live with analog pedals.
- **Probe harness pattern** (§0 of the drivetrain plan): a probe that simulates driver input is
  a `Node` with a `_physics_process` state machine using `Input.action_press/release`, added by
  a temporary env-gated block in `world.gd` `_ready()` and then `move_child(probe, 0)` — it MUST
  sit before the car in the tree, because `is_action_just_pressed` only reports true on the
  press frame and the car reads input in tree order. Delete the script AND the `world.gd` block
  afterwards.
- **Probe hygiene learned the hard way (2026-08-12):** measure HORIZONTAL ground speed
  (`Vector2(v.x, v.z).length()`), never `linear_velocity.length()` — the latter includes
  vertical velocity, and a probe that ran off the end of the drag strip once reported a falling
  car as a 244 km/h top speed. Give every probe a bound that stops it before it leaves the
  road, and make its wait condition match failure as well as success.
- After finishing a phase, tick its checkbox in §9 and add a one-line status note (date + what
  the drive test concluded).

---

## 1. Vision & goal (interview outcome, 2026-08-13)

**Better maps — real stages worth learning — built on the ground mapping Arc C introduces.**

Arc C1 adds a procedural roughness FIELD keyed to world position. That is this project's first
instance of "the ground is a queryable function of position". Arc D's thesis: that should not
stay a one-off. It becomes **one authority for what the ground IS at any (x, z)** — surface
class, roughness class, deformability, grip, colour, audio — and the stages get built on top of
that authority rather than beside it.

### 1.1 Settled decision, 2026-08-12 — do not reopen

**New maps go in a NEW area; the existing map is preserved untouched as the test and
calibration bed.** The three concentric circuits, the centre deformable patch and the 4 km drag
strip stay exactly as they are, because every calibration baseline this project owns is
expressed in their terms: top speed down the strip, rally-loop lap feel, B3's bottoming
statistics at 100 km/h on the rally loop, A2's coast-down figures. A stage that modified them
would silently invalidate the entire regression surface mid-arc.

Every Arc D feature is therefore **additive**. A change that can only be made by editing the
existing circuits' geometry is out of scope for this arc.

### 1.2 Interview answers, 2026-08-13 (user's calls, with their consequences)

1. **Topology → point-to-point stages.** Start → finish, no lap. This is what "rally stage"
   means and it is where pace notes finally pay off.
   _Consequence:_ roads stop being `r = f(θ)`. The centreline abstraction of §3.1 becomes
   mandatory, and `time_trial.gd`'s angle-crossing lap detection is a genuine rewrite (§2.2).

2. **Scale → 4–6 km per stage, with the FULL streaming engineering** (chunk streaming, mesh
   LOD, memory budgeting) built from the start rather than a static heightmap that gets
   retrofitted.
   _Consequence:_ D4 is a large phase and lands before any long stage is playable. The payoff
   is that stage length stops being an engineering constant — going to 10–15 km later becomes a
   parameter change plus a budget re-measure, not a rewrite. The cost is that Arc D cannot ship
   a long stage early; D3 deliberately ships a SHORT non-streamed one first so the generator is
   provable before the streaming work starts.

3. **Authoring → procedural generation from stage parameters, plus authored control points,
   with a path left open for imported heightmaps.**
   _Consequence:_ the generator is the primary tool (length, sinuosity, surface mix, elevation
   character), and pinned waypoints are an override layer on top of it, not a parallel system.
   The heightmap-import path is designed for in D2's data model (§5.3) but NOT built in this
   arc — it is named as a seam, not a phase, so nobody has to retrofit it later.

4. **Reaching the new area → a connecting road you physically drive, which unloads one area and
   loads the other.** A mix of "drive there" and "separate world".
   _Consequence:_ this is the most demanding of the three options and it deserves saying
   plainly. It means (a) only one area is resident at a time, so the memory ceiling stays flat,
   but (b) the transition must happen while the car is moving, which forces asynchronous
   loading and a transition corridor long enough to hide the load, and (c) the calibration bed
   must rebuild **bit-identically** every time you drive back into it. §5.5 makes that a probe,
   not a hope.

5. **Surfaces → mixed-surface transitions only.** Gravel and tarmac already exist; mud, snow/ice
   and sand are explicitly out of this arc.
   _Consequence:_ D6 is a blend-and-classification phase rather than N new surface models. This
   is the cheapest big win available — it is where real stages punish you, and it needs no new
   tyre physics, only a ground-map class that interpolates between two classes that already
   work.

6. **Deformable ruts along the stage (roadmap M6 Phase 2) → a late OPTIONAL phase in Arc D.**
   _Consequence:_ specified as D7 and ordered last so the arc ships without it. Honest framing:
   streaming a deformable corridor along a 4–6 km point-to-point stage is a subsystem, not a
   feature, because deformation state must now persist across chunk load/unload (§8.4).

7. **Ordering → C1 first, then Arc D.**
   _Consequence:_ C1 builds the ground-map primitive on the existing map, where every
   calibration baseline lives. Arc D then generalises it. This also means C1's travel-budget
   finding (§8.2) lands **before** stage terrain adds more vertical input, which is the right
   order. §6 lists the amendments Arc D forces on C1 — read it before executing C1, because two
   of them are cheaper to honour up front than to retrofit.

### 1.3 Feel acceptance criteria (the end state, in the user's terms)

- **A stage is a route, not a lap.** You leave a start line, you arrive at a finish, and the
  road in between is worth learning — you remember specific corners, not a shape.
- **Pace notes finally matter.** On a point-to-point road you cannot see, the co-driver is the
  reason you can commit. Notes arriving late or wrong is now a real failure, not cosmetic.
- **The ground reads as ground.** Surface changes are felt through the car before they are seen,
  and a gravel-over-tarmac patch mid-corner is a handling event.
- **The same stage twice is the same stage.** Same corners, same bumps, same braking points.
- **Driving between areas feels like driving**, not like a menu — and coming back to the
  calibration bed lands you on a car that behaves exactly as it did before you left.

---

## 2. Current-state assessment (measured 2026-08-12/13 — use these facts, don't re-derive them)

### 2.1 The world today

- **One 720 m square, 320² cells = 2.25 m/cell** (`stage.gd:10-11`), hills at `hill_octaves 2`
  (`stage.gd:14`). Nothing below 2.25 m exists geometrically outside the centre deformable
  patch. This is exactly why C1 exists.
- **The drag strip already breaks the 720 m square:** `strip_len` derives `strip_x1 = 4285`,
  built as flat slabs that continue past the terrain edge, with distance posts every 100 m,
  km call-outs and a W-beam guard-rail arc round the runoff pad. `_guard_rail(polyline)` lays
  panels + posts along ANY polyline and is directly reusable for new areas.
- **`terrain.gd` deformable terrain works but is wired only to the centre patch**, not the
  stage corridor (roadmap M6 Phase 2).
- **Physics runs at 120 Hz with large headroom on the M1** — 1.84 ms/tick measured at Phase 0.
  That is the budget every Arc D perf probe measures against.
- **Arc B is mid-flight:** B1 implemented and awaiting the drive verdict, B3 done, B2/B4/B5
  open.

### 2.2 Everything is hard-wired to the polar form — and this is the arc's biggest structural fact

Every road is `r = f(θ)` about the origin: `_road(θ)` (rally loop), `_asphalt_r(θ)` (asphalt
ring), a centre skid pad, and the drag-strip spur. All three circuits are concentric and share
the θ=0 finish ray. What that costs, system by system — **and this table is the honest answer
to "which of these is a rewrite and which is a re-parameterisation":**

| System | How it is coupled to θ today | Verdict |
|---|---|---|
| `time_trial.gd` | Laps and sectors detected by `atan2` crossings (`:106`, `:119`), circuits disambiguated by disjoint radius bands `RMIN/RMAX` (`:17-18`), sectors by θ-thirds, lap logic assumes a closed loop that wraps | **Genuine rewrite.** Point-to-point has no wrap, no radius band, and no shared finish ray. Becomes trigger volumes placed at arc-length positions along the centreline. |
| `pace_notes.gd` | `_build_route` samples `θ ∈ [0, TAU)` and calls `_road`/`_asphalt_r` (`:52-57`) — but then immediately builds `pts`, `arc`, `elev`, `total` and does ALL detection on those | **Re-parameterisation, and it gets CHEAPER.** It already works on a sampled centreline with arc length; only the sampling source changes. Corner detection, severity and crest logic are untouched. |
| `wear.gd` | `_build_field` samples `θ` (`:50`) into `pts`/`seglen`, then indexes `[arc_sample × lat_bin]` (`:28`) | **Re-parameterisation**, with one real edge: the `% arc_samples` wrap-arounds (`:58`, `:63`) assume a closed loop and must become open-ended for point-to-point. |
| `grip_at(x, z)` | Classifies surface by polar distance tests (`stage.gd:184`) | **Replaced** by the ground-map lookup (D1) — but must return byte-identical classifications on the old map. |
| `stage.gd` public API | `grip_at`, `_height`, `_road`, `_road_halfwidth`, `_asphalt_r`, `_circuit_r`, `get_spawn`, `get_spawn_for` — small, which is lucky | Becomes the interface a *stage instance* implements, so several can exist. |

The good news buried in that table: **two of the three "hard" systems are already centreline-
based internally.** They derive a centreline from θ and then forget θ ever existed. Swapping the
source is a small, testable change. Only `time_trial.gd` genuinely assumes closed-loop polar
topology all the way down.

---

## 3. Research: chosen techniques, rationale, sources

### 3.1 The centreline: arc-length parameterised spline

**Chosen approach:** a sampled centreline with a **cumulative arc-length table**, exposing
`nearest_point(x, z) -> {s, lateral, heading, curvature, width, superelevation, surface}`. The
control polygon is interpolated with a **centripetal Catmull-Rom** spline, which passes through
its control points (what "authored waypoints" requires) and, unlike uniform Catmull-Rom, is
provably free of cusps and self-intersections within a segment — the failure mode that turns a
generated road into a knot — [Yuksel et al., *Parameterization and Applications of Catmull-Rom
Curves*](https://www.cemyuksel.com/research/catmullrom_param/catmullrom_cad.pdf).

Splines are not naturally arc-length parameterised: equal steps in the spline parameter are not
equal distances along the road. The standard fix is to build a lookup table of cumulative
distance at dense samples and invert it by binary search — [arc-length parameterisation
primer](https://www.geometrictools.com/Documentation/MovingAlongCurveSpecifiedSpeed.pdf). That
table IS the `s` axis that `wear.gd` and `pace_notes.gd` already want, which is why those two
systems fall out cheaply.

**Caveat:** `nearest_point(x, z)` on a long spline is the one query that could get expensive —
it is called per wheel per frame by the ground map. Do not solve it by brute force over 6 km of
samples. Bin the centreline samples into a coarse uniform grid keyed by world position, so the
query only ever searches a handful of candidate samples. Budget it in D2's probe, not later.

### 3.2 Road geometry: generating roads that are plausible rather than random

**Chosen approach:** the generator does not place bumps and corners; it samples a small number
of **stage parameters** and then solves geometry under real road-design constraints. That is the
functions-over-constants answer to "what does a principled stage generator look like".

The governing relation for a horizontal curve is `R = V² / (127·(e + f))` — radius from design
speed, superelevation `e` and side-friction factor `f` — with matching guidance on transition
(spiral) lengths and sight distance from the AASHTO Green Book — [FHWA horizontal curve design
summary](https://highways.dot.gov/safety/other/horizontal-curve-safety),
[superelevation and side friction](https://www.fhwa.dot.gov/publications/research/safety/09037/002.cfm).
Procedural road generation over terrain, including cost-based routing that trades curvature
against earthworks, is well covered by [Galin et al., *Procedural Generation of Roads*
(Eurographics)](https://perso.liris.cnrs.fr/eric.galin/Articles/2010-procedural-roads.pdf).

**Caveat, and it matters here:** AASHTO exists to make roads safe at their design speed with a
margin. A rally stage is the opposite — it is a public road driven far beyond any speed it was
designed for, and its character comes precisely from that mismatch. So use the design equations
as the **generator's constraint set** (they produce roads that look and flow like real roads),
and then set the design speed *below* the car's capability on purpose. The driver is meant to
be over-driving the geometry; that is the sport. Do not use these numbers as a target the
player is expected to respect.

### 3.3 Terrain synthesis and erosion

**Chosen approach:** fBm noise for the base landform (already in use via `FastNoiseLite`),
plus a **hydraulic-erosion pass** to give valleys and ridgelines that a road can plausibly
follow. Erosion is what separates "noise" from "landscape": it carves drainage networks, so
roads that follow valley floors and ridge lines look deliberate — [Musgrave, Kolb & Mace, *The
Synthesis and Rendering of Eroded Fractal Terrains*](https://dl.acm.org/doi/10.1145/74334.74337),
[practical particle-based hydraulic erosion](https://nickmcd.me/2020/04/10/simple-particle-based-hydraulic-erosion/).

**Caveat:** full erosion simulation over a streamed 6 km corridor is not affordable per-chunk at
load time, and running it globally breaks the "pure function of position" rule because erosion
is inherently a *global* iterative process — a chunk's eroded height depends on water that came
from outside it. Resolution: run erosion **offline per stage seed** over a coarse control grid,
bake the result into the stage's data, and let per-chunk detail be pure positional noise on top.
That keeps chunk generation local and deterministic. State this explicitly in D5; it is the kind
of thing that silently becomes non-repeatable if nobody names it.

### 3.4 Chunked terrain collision and LOD in Godot 4

**Chosen approach:** the corridor is divided into chunks, each with its own `HeightMapShape3D`
collider and its own mesh, loaded/unloaded around the car. Godot's own docs and the mature
community terrain plugins (Terrain3D, HTerrain) all converge on chunked heightmap colliders
plus distance-based mesh LOD — [Terrain3D](https://github.com/TokisanGames/Terrain3D),
[HTerrain](https://github.com/Zylann/godot_heightmap_plugin). `terrain.gd` in this project
already does per-tile `HeightMapShape3D` with a throttled re-cook (0.1 s), so the pattern is
proven in-repo, at small scale.

**Caveat:** collider *cooking* is the cost, not rendering. `terrain.gd` throttles re-cooks
precisely because Jolt has to rebuild the shape. Streaming means cooking a fresh chunk collider
while the car is moving at 150 km/h, which is a frame-time spike, not a steady cost. Two
mitigations belong in the plan: cook ahead of the car with enough lead time that the spike never
lands under the wheels, and measure the spike explicitly rather than the average — an average
frame time hides exactly this failure.

### 3.5 One ground map, not five surface tests

**Chosen approach:** a single `sample(x, z)` returning a small struct — surface class, road
class (C1's roughness spectrum), deformability, grip multiplier, colour, audio key. `grip_at`,
C1's roughness field, `sound.gd`, `terrain.gd` and M11's particles all read from it instead of
each re-deriving surface from geometry tests.

The rationale is not architectural neatness, it is **consistency**: today, surface is decided
independently in `stage.grip_at` (polar tests), in `world.gd`'s skid-mark gate (a grip
threshold), and in `sound.gd` (a base-grip split). Three places that can disagree. Once a stage
has gravel dragged onto tarmac (D7), disagreement stops being theoretical — the tyre would grip
one surface while the audio and particles played another.

### 3.6 What a real special stage is made of

Stage character in rallying is documented mostly through the road book and pace-note
conventions rather than engineering literature: stages are 5–25 km, described as a sequence of
corners with severity, distance-to-next, and modifiers (crest, over jump, into, tightens, long)
— [FIA rally sporting regulations](https://www.fia.com/regulation/category/119),
[pace note systems overview](https://en.wikipedia.org/wiki/Pace_notes).

**Caveat:** this is a description of how stages are *communicated*, not how they are *built* —
there is no published generative model of "what makes a stage good". Treat the note grammar as
the acceptance criterion instead: a generated stage is plausible if `pace_notes.gd` can describe
it in the same vocabulary a real road book uses, and if that description reads like a rally
stage rather than like noise. That is a testable property and it is already implemented —
`pace_notes.gd` produces exactly this grammar today. **Use it as the generator's own probe.**

---

## 4. Phase map (execute strictly in order)

| Phase | Title | Size |
|---|---|---|
| — | _(the centreline abstraction moved into **C1** — see below)_ | — |
| D1 | The ground map: one authority for what the ground is | M |
| D2 | Timing, notes and wear re-parameterised onto arc length | M |
| D3 | The stage generator: parameters + control points (short, static) | L |
| D4 | Chunked terrain, streaming and LOD | L |
| D5 | The area manager and the connecting tunnel | M |
| D6 | Mixed-surface transitions | M |
| D7 | Deformable ruts along the corridor (**optional** — may be cut) | L |
| D8 | Bake defaults, prune, end-to-end verification | S |

**Scope change 2026-08-13 (user's call): the centreline abstraction — the old phase D2 — moves
into C1.** C1 needs `s` for its washboard term, and having Arc D redefine `s` afterwards would
move every ripple on the existing map (the risk this plan recorded as §6.2). Building the real
centreline inside C1 costs one sub-phase there and deletes an entire L-sized phase here, plus the
class of rework it would have caused. C1's spec now carries it as **C1.0**, including the
millimetre-identity probe that protects the existing map. Arc D's remaining centreline work is
purely additive — open roads (`is_loop() == false`) and generated ones — and cannot move anything
C1 tuned.

**Ordering rationale, stated because it is deliberate:** D1–D3 add **no new content at all**.
They build on the centreline C1 already proved, and verify the ground map and the three
downstream systems by equality against the existing map — where every calibration baseline lives
and where any deviation is immediately visible. Only once all of that is proven on known-good
geometry does D3 generate anything new. This front-loads all the structural risk into phases that can be verified by
equality against a known answer, which is the cheapest kind of verification there is.

**Every phase leaves the game fully drivable, on keyboard, with the existing map intact.**

---

## 5. Phase details

### Phase D1 — The ground map: one authority for what the ground is

**Files:** new `scripts/ground_map.gd`; `stage.gd` (`grip_at` delegates); `world.gd` (wiring);
`sound.gd` and `world.gd`'s skid-mark gate (read the map instead of thresholding grip);
`tuning_panel.gd`.

**Mechanism.** `GroundMap.sample(x, z) -> GroundSample` with fields: `surface` (enum:
GRASS / DIRT / ASPHALT / PATCH), `road_class` (the ISO 8608 coefficient C1 wants),
`deformable` (bool), `grip` (float), `colour` (Color), `audio` (StringName). The map is
composed of **layers** queried in priority order, each of which is a pure function of position:
the base terrain class, then each road corridor, then overrides (the centre deformable patch,
the drag strip). This composition is what later lets a second area exist without touching the
first.

`stage.grip_at()` becomes a one-line delegation to `GroundMap.sample().grip`, preserving its
signature so `wear.gd`'s wrapper (`surface_source`) keeps working untouched — that wrapper is
load-bearing for M6 and must not be disturbed.

**This phase changes no behaviour.** It is a refactor whose success condition is that nothing
moves.

**Compile gate:** `./check.sh` clean.
**Headless probes (then remove):**
1. **Golden equality.** Sample `grip_at` at a fixed lattice of world positions (a few thousand
   spanning all four surfaces and both circuit shoulders) before and after the refactor. Pass
   condition: **byte-identical** classification at every point. This is the phase.
2. **Consumer agreement.** At the same lattice, assert the skid-mark gate, `sound.gd`'s surface
   split and `grip_at` all report the same surface class. Any disagreement found here is a
   pre-existing bug the refactor has just surfaced — record it, don't silently "fix" it.
3. **Cost.** `sample()` calls per frame × measured cost, against the 1.84 ms/tick baseline.

**User drive checklist:**
- [ ] Drive all three circuits: nothing feels different, at all. (This is a success, not a
      disappointment — D1 is scaffolding.)
- [ ] Skid marks still appear only on asphalt; tyre audio still changes on the same lines.
- [ ] The wear line still darkens and still adds grip on the rally loop.

---

### Phase D2 — Timing, notes and wear re-parameterised onto arc length

**Files:** `time_trial.gd` (**rewrite**), `pace_notes.gd` (re-parameterise), `wear.gd`
(re-parameterise), `hud.gd` (wording: "lap" vs "run").

**Mechanism.**
- **`time_trial.gd`:** replace `atan2` crossings and `RMIN/RMAX` radius bands with **trigger
  positions along `s`** — start, N splits, finish. For a loop, start and finish are the same
  `s` and the run repeats (today's behaviour preserved). For an open road they are the ends and
  the run terminates. Detection becomes "did `nearest_point().s` cross this trigger's `s`
  between the last frame and this one, travelling forward", which is robust and topology-
  agnostic. Ghosts stay transform-recordings and are unaffected in principle — but the ghost's
  *reset* semantics change for open roads (a run ends rather than wrapping), so state that.
- **`pace_notes.gd`:** `_build_route` takes a `Centreline` instead of sampling θ. Everything
  downstream — `_detect`, `_severity`, `_crest` — is untouched. Expect this file to get
  *shorter*.
- **`wear.gd`:** `_build_field` indexes by `s` from the `Centreline`. The `% arc_samples`
  wrap-arounds become conditional on `is_loop()`.

**Compile gate:** `./check.sh` clean.
**Headless probes (then remove):**
1. **Timing equality on the old map.** Drive a scripted identical line on each circuit before
   and after; lap, sector and split times must match to within one physics tick.
2. **Pace-note equality.** The corner list produced for both routes must be identical
   (direction, severity, modifiers, distances) before and after.
3. **Wear-field equality.** Same accumulated wear grid after an identical scripted run.
4. **Open-road behaviour.** A synthetic open centreline: run starts at the start trigger, splits
   fire in order, finish terminates the run, and no wrap-around occurs.

**User drive checklist:**
- [ ] Lap timing, sector splits and the purple/red best-sector flash all behave as before on all
      three circuits.
- [ ] Pace notes call the same corners at the same moments on both routes.
- [ ] The ghost still records and replays.
- [ ] The wear line still forms in the same places.

---

### Phase D3 — The stage generator: parameters + control points (short, static)

**Files:** new `scripts/stage_gen.gd`; new `scripts/stage_def.gd` (the stage data model);
`stage.gd` (becomes able to build a generated stage as well as the legacy one);
`tuning_panel.gd`.

**Mechanism.** A stage is defined by a `StageDef`: `seed`, `length_m`, `sinuosity`,
`elevation_character`, `surface_mix`, `design_speed`, `width_profile`, plus an optional array of
**authored control points** that the generated centreline must pass through. Generation:
1. Route a coarse path across the terrain, biased to follow valleys and ridges (§3.3), honouring
   any authored control points as hard constraints.
2. Fit a centripetal Catmull-Rom spline through the resulting control polygon.
3. Enforce road-design constraints (§3.2): minimum radius from design speed, transition
   lengths, superelevation on curves.
4. Emit a `Centreline` plus a surface profile along `s`.

**Deliberately short and static in this phase:** cap it at ~1–1.5 km and build it with the
existing single-heightmap approach so the phase is drivable and provable without streaming.
D4 replaces the build step, not the generator.

**The heightmap-import seam:** `StageDef` must be able to name an external elevation source
instead of the procedural one, and `stage_gen` must read elevation through one function so that
swapping the source is a one-place change. Design it; do not build it.

**Compile gate:** `./check.sh` clean.
**Headless probes (then remove):**
1. **Determinism.** The same seed produces a bit-identical centreline, surface profile and
   elevation across two runs and after a respawn.
2. **Geometric sanity.** No self-intersection; no radius below the design-speed minimum; no
   discontinuity in heading or curvature at spline segment joins; authored control points are
   hit within tolerance.
3. **The pace-note grammar test (§3.6).** Run `pace_notes.gd` over the generated stage and dump
   the note list. Pass condition: it reads like a road book — a varied sequence of severities
   with sensible distances, not a monotone run of identical corners nor noise. **This is the
   generator's real acceptance test** and it costs nothing to run.
4. **Vertical budget** (§8.2): bottomed-frame count and peak `Fz` over the generated stage
   against B3's rally-loop baseline.

**User drive checklist:**
- [ ] The generated road is drivable end to end and feels like a road, not like noise.
- [ ] Corners have rhythm — they connect into sequences rather than arriving at random.
- [ ] Pace notes describe it correctly and arrive in time to be useful.
- [ ] Changing `seed` produces a genuinely different stage; changing it back reproduces the
      first one exactly.
- [ ] Changing `sinuosity` / `elevation_character` moves the stage's character in the direction
      the name implies.

---

### Phase D4 — Chunked terrain, streaming and LOD

**Files:** new `scripts/stage_chunks.gd`; `stage.gd`; `world.gd`; `tuning_panel.gd`.

**Mechanism.** The corridor around the active centreline is divided into chunks along `s`. Each
chunk owns a mesh (with distance LOD) and a `HeightMapShape3D` collider. Chunks load ahead of
the car along `s` and unload behind it, with hysteresis so a car sitting near a boundary does
not thrash. Erosion is baked per stage seed into a coarse control grid (§3.3); per-chunk detail
is pure positional noise on top, so chunk generation is local, order-independent and repeatable.

**Cook-ahead is the whole game here.** Collider cooking is a frame-time spike, not a steady
cost (§3.4). Lead distance must be derived from the car's speed, not a constant: at 150 km/h the
car covers 42 m/s, so the lead must cover cook latency plus a safety margin at the highest speed
the stage allows.

**Compile gate:** `./check.sh` clean.
**Headless probes (then remove):**
1. **Frame-time spikes, not averages.** Drive the full stage at speed and record the *worst*
   physics-frame time and its position, against the 1.84 ms/tick baseline. Pass: no spike lands
   while a wheel is on a newly-cooked chunk, and the worst frame stays inside budget.
2. **Memory ceiling.** Peak resident chunk count and collider memory over a full run; assert the
   ceiling is flat (bounded) rather than growing with distance travelled.
3. **Seam continuity.** Sample `_height` and the ground map on both sides of every chunk
   boundary: no step, no gap, no normal discontinuity.
4. **Order independence.** Drive the stage forwards, then drive it backwards; every chunk's
   heights and ground-map values must be identical either way.

**User drive checklist:**
- [ ] Driving the full stage at speed produces no hitch, stutter or pop-in you can feel.
- [ ] No visible seam or step where chunks meet, including on crests.
- [ ] Turning round and driving back gives you exactly the road you just drove.
- [ ] FPS holds.

---

### Phase D5 — The area manager and the connecting tunnel

**Files:** new `scripts/area_manager.gd`; `world.gd`; `stage.gd`; `time_trial.gd` (area-aware);
`pace_notes.gd`, `wear.gd` (rebuild per area).

**Mechanism — the connector is a TUNNEL (user's suggestion, 2026-08-13, adopted).** An
`AreaManager` owns which area is resident. Areas: `CALIBRATION` (the existing
three circuits + patch + drag strip, untouched) and `STAGE` (a generated stage). A **connecting
road** runs between them, built from a `Centreline` like everything else and using the existing
`_guard_rail(polyline)` helper. Driving along it crosses a transition zone that triggers an
**asynchronous** unload of the departing area and load of the arriving one, sized so the load
completes inside the corridor at normal driving speed.

**The non-negotiable property:** the calibration bed must rebuild **bit-identically** every time.
Every baseline this project owns depends on it.

**Compile gate:** `./check.sh` clean.
**Headless probes (then remove):**
1. **Bit-identical rebuild.** Capture the golden lattice from D1 (grip classification, `_height`
   samples, all spawn transforms, `_road`/`_asphalt_r` at fixed θ) on first build. Drive to the
   stage, drive back, capture again. Pass: **identical**, not close.
2. **Memory across transitions.** Ten round trips; assert no growth in node count, collider
   count or resident memory — a leak here is invisible until it isn't.
3. **Transition timing.** Load completes before the car exits the corridor at the highest speed
   the connecting road permits, with margin. Report the actual margin.
4. **State survival.** Damage, tyre wear/temperature and fuel-equivalent state either survive
   the transition or are reset deliberately — decide which, and assert it.

**User drive checklist:**
- [ ] Driving through the tunnel feels like driving, with no freeze, no black screen and no
      visible pop-in at either mouth.
- [ ] Reversing back out mid-tunnel does something sensible rather than breaking.
- [ ] Arriving back at the old map, the car behaves exactly as it did before you left — run a
      drag-strip top-speed pass and a rally-loop lap and compare against your remembered
      baseline.
- [ ] Lap timing, ghosts and pace notes all work in whichever area you are in, and the other
      area's bests are still there when you return.

---

### Phase D6 — Mixed-surface transitions

**Files:** `ground_map.gd`; `roughness.gd` (C1's); `sound.gd`; `world.gd` (particles/marks);
`stage_gen.gd`; `tuning_panel.gd`.

**Mechanism.** A ground-map class that **interpolates** between two existing classes over a
blend distance, rather than a new surface model: grip, road class, colour and audio all
interpolate together from the same blend factor, so nothing can disagree. The generator places
transitions where they occur in reality — gravel dragged onto tarmac at junctions and corner
exits, tarmac sections through villages mid-gravel-stage, and the loose-over-hard patch on the
outside of corners.

**Why this is the cheapest big win:** no new tyre physics, no new thermal model, no new particle
system. It reuses two classes that already work and adds the thing that makes them matter — the
boundary between them.

**Compile gate:** `./check.sh` clean.
**Headless probes (then remove):**
1. **Blend continuity.** Sample grip, road class and colour across a transition: all continuous,
   all monotone, all reaching both endpoint classes exactly.
2. **Consistency.** Across the same transition, the tyre's grip, the audio key and the particle
   choice agree at every point (the D1 consumer-agreement probe, re-run on blended ground).
3. **Repeatability.** Transition positions are a pure function of stage seed.

**User drive checklist:**
- [ ] Hitting gravel-over-tarmac mid-corner is a handling event you feel before you see.
- [ ] Audio and dust change with the surface at the same moment the grip does.
- [ ] Tarmac sections mid-stage genuinely change how you drive that section.

---

### Phase D7 — Deformable ruts along the corridor (**OPTIONAL** — may be cut)

**Files:** `terrain.gd`, `stage_chunks.gd`, `ground_map.gd`.

**Mechanism.** Wire `terrain.gd`'s GPU height-displacement + per-tile `HeightMapShape3D` to the
stage corridor, gated by the ground map's `deformable` flag, so ruts form along the driven line
(roadmap M6 Phase 2).

**The hard part is not deformation, it is persistence.** Deformation state must survive chunk
unload/reload — a rut you carved on the way out must still be there on the way back, or the
stage stops being repeatable in the one way the player would most notice. That means
deformation is no longer a pure function of position: it is position **plus accumulated
history**, which must be stored per chunk, evicted with care, and bounded in memory.

**This phase is explicitly cuttable.** If D2's budget is tight or persistence proves expensive,
cut it and record the decision. The arc ships without it.

**Compile gate:** `./check.sh` clean.
**Headless probes (then remove):**
1. **Persistence.** Carve a rut, drive far enough to unload the chunk, return: the rut is
   there, at the same depth and position.
2. **Memory bound.** Deformation state over a full stage stays under a stated ceiling; eviction
   never drops the chunk the car is on.
3. **Budget.** Frame-time spikes with deformation active, against D2's numbers.

**User drive checklist:**
- [ ] A second pass down the same stretch is measurably different from the first — the line has
      developed.
- [ ] Ruts are where you actually drove.
- [ ] No hitch when a deformed chunk reloads.

---

### Phase D8 — Bake, prune, end-to-end

**Files:** all of the above; `docs/ROADMAP.md`.

1. Bake the user's preferred stage parameters and ground-map defaults into the exports.
2. Prune dead code: any polar-only helper left unused after D3, any duplicated surface test
   left after D1, temporary compatibility shims.
3. Full end-to-end verification with the user (§7's regression surface, driven).
4. Update `docs/ROADMAP.md`: M6 Phase 2 (done or explicitly cut), M10's multi-stage sequence
   (now delivered by the area manager), and record the new stage/ground-map state.

---

## 6. Amendments Arc D forces on Arc C1

C1 is already specified and runs FIRST. Three of these are cheaper to honour when writing C1
than to retrofit afterwards — **read this section before executing C1.**

1. **Per-surface exports become class defaults, not the authority.** C1 specifies
   `road_class_gravel` and `road_class_tarmac` as exports read directly by the roughness field.
   After D1 the road class is a **per-position lookup** from the ground map. Write C1 so the
   field asks a function `road_class_at(x, z)` — implemented in C1 as a simple surface test —
   rather than reading the export inline. Then D1 replaces the function body and nothing else
   moves. *Cost if ignored: every roughness call site changes in D1.*

2. **`s` for the washboard term must come from a centreline query, not from θ.** C1 models
   washboard as `sin(2π·s / λ)` with `s` = distance along the road centreline, and pre-D2 the
   only available `s` is polar arc length. **If C1 hardcodes the θ-derived `s` and D2 later
   changes how `s` is computed, every washboard ridge on the existing map moves** — which would
   silently invalidate C1's own drive-verified feel and any braking points the user has learned.
   Two acceptable resolutions, and C1 must pick one explicitly: derive `s` through a single
   function that D2 can re-point, or accept the shift and re-verify C1's checklist after D2.
   *This is the single most likely way Arc D silently breaks Arc C.*

3. **The deformable-patch exclusion generalises.** C1 excludes the centre deformable patch
   because `terrain.gd` puts real geometry there. That exclusion becomes the ground map's
   `deformable` flag (D1) and later covers the whole stage corridor (D7). Write C1's exclusion
   as a query, not a hardcoded radius test against the patch.

4. **The washboard placement mask is shared with `wear.gd`.** C1 reuses `wear.gd`'s
   curvature/braking mask so the line that gets worn is the line that gets ribbed. After D3 that
   mask is indexed by arc length on a `Centreline`, which makes it work unchanged for
   point-to-point stages. No C1 change needed — but D3 must not break the sharing, so its
   probes must cover it.

5. **C1's repeatability probe is Arc D's standard.** C1's third probe (identical field values at
   the same world position across frames and respawns) is exactly the property every Arc D phase
   must hold. Arc D reuses it verbatim, extended to survive chunk load/unload (D4) and area
   transitions (D5).

---

## 6b. Known open items outside Arc D's scope (carried, not forgotten)

These were surfaced by Arc D's probes or drives but belong to their own phases. Recorded here so a
future session finds them; full detail and numbers in `CHANGELOG.md`.

- **Tyre audio only fires on the handbrake** (2026-08-28). `sound.gd`'s tyre voice is gated on
  LONGITUDINAL slip ratio > 0.25, which effectively only a locked or spinning wheel reaches;
  `w.slip_angle` is absent, so a sideways gravel slide is silent. `wear.gd` uses both components
  and `effects.gd` uses contact-patch slip velocity, so sound is the odd one out. Fix direction:
  drive it from `effects.gd`'s `slip_speed(w, v)` so audio, particles and wear agree on when a
  tyre is sliding.
- **`sound.gd` vs the centre patch / grass split** — grass and gravel now sound identical
  (both non-asphalt). Fine today; D6's mixed surfaces may want a third class.
- **The centre patch has two shapes** (D1) — grip uses a euclidean radius, the roughness exclusion
  a chebyshev one; they disagree on 392/6608 lattice points.
- **`wear._cell()` still maps position to cell by polar radial offset** (D2) — the general path
  belongs with the first non-polar road, i.e. D3/D7.

---

## 7. Regression surface — what must not break

Extends §6 of the drivetrain plan. At minimum, and verified in D9:

- **Lap timing and ghosts on all three circuits**, per-circuit bests, and the live delta.
- **Sector splits** and the purple/red best-sector flash.
- **Pace notes on both routes**, with correct direction, severity, modifiers and timing.
- **The wear line** and its grip effect, including `wear.gd`'s `surface_source` wrapper of
  `grip_at` — every grip query must keep going through `surface_source`, never `stage.grip_at`
  directly.
- **The deformable centre patch.**
- **The drag strip:** distance posts, km call-outs, guard rail, and the top-speed run.
- **Spawn/respawn for every circuit** (`get_spawn`, `get_spawn_for`), and `[B]` circuit toggle.
- **The rear-view mirror overlay**, HUD, component HUD, and the bottom-right instrument.
- **Time-of-day** cycling.
- **Drive-mode `[T]` and diff presets `[1]/[2]/[3]`** with their HUD readout.
- **The whole vehicle model.** Arc D touches the ground under the car and nothing else. The
  suspension raycast block is the only vehicle code it modifies (C1's injection point), and
  Arc B/C's tuning must not shift as a side effect.
- **The calibration baselines themselves:** drag-strip top speed, rally-loop lap feel, B3's
  bottoming statistics, A2's coast-down figures. These are the reason §1.1 exists.

---

## 8. Risks & unknowns, and de-risking

1. **The `s`-definition trap (§6.2).** Highest-probability silent breakage in the arc: C1 ships
   washboard keyed to polar arc length, D2 redefines arc length, and every ripple moves. De-risk
   by routing `s` through one function in C1 and adding a D2 probe that asserts washboard
   positions on the old map are unchanged.

2. **The vertical budget — reframed 2026-08-13, and it is NOT a travel problem.** B3 recorded all
   four corners pegging 100% of travel on the rally loop at 100 km/h, and the obvious reading was
   "not enough travel, raise the ride height". Research says otherwise. Gravel WRC cars run
   **250–300 mm of total suspension travel**; this car has `max_travel` 0.45 m with 0.127 m of
   static sag, i.e. **323 mm of bump travel — more than a real rally car's entire stroke.**
   ([gravel setup overview](https://www.rallynews.autospeedmarket.com/rallynews/how-suspension-setup-affects-performance-on-gravel-stages/),
   [WRCwings](https://www.wrcwings.tech/2020/05/24/suspension-grip-and-aerodynamics/))
   The likelier causes, and the order to attack them: **(a)** the bump stop is a pure displacement
   spring, so it stores the impact and returns it instead of absorbing it — real end-of-travel
   control is *hydraulic*, velocity-sensitive and dissipates energy as heat, which is why the
   `bumpstop_g` sweep raised peak load to 63 kN without buying travel (full finding and sources in
   the drivetrain plan's B3 revision); **(b) B2 is not implemented yet**, and its asymmetric
   bump/rebound split is exactly the "soft compression, firm rebound" real gravel cars use — the
   single most likely fix; **(c)** the heightmap's input may simply be more severe than a real
   rally road.
   **Stance for this arc:** do **B2, then the hydraulic bump-stop revision, and re-measure**,
   before Arc D adds crests and compressions — and before anyone raises ride height, which the
   travel figures suggest is the wrong lever. D3 may not ship elevation features until that
   re-measurement exists. Every terrain-adding phase re-runs the bottoming probe against B3's
   numbers. Do **not** scale terrain amplitude down to hide it — that buries a suspension problem
   inside the map.

3. **Collider cook spikes under streaming (§3.4).** An average frame time will look fine while
   the car hits a 30 ms spike every 200 m. Measure worst-frame, not mean, and correlate it with
   chunk-load position.

4. **Deformation persistence breaks purity (§5, D8).** Everything else in Arc D is a pure
   function of position and seed. Ruts are not — they are position plus history. That is the
   real reason D8 is optional and last.

5. **`time_trial.gd` is a rewrite, and it owns the user's saved bests.** A rewrite that loses or
   invalidates per-circuit bests and ghosts is a real regression even though nothing crashes.
   D2's probes must assert timing equality on the old map before the new topology is trusted.

6. **`nearest_point(x, z)` cost (§3.1).** Called per wheel per frame against a 6 km centreline.
   Brute force is 24 000 distance tests per frame at 4 wheels × 120 Hz. Spatial binning is not
   an optimisation to add later; it is part of the design.

7. **Erosion is global, chunks are local (§3.3).** Naive per-chunk erosion is non-repeatable
   because a chunk's water comes from outside it. Bake erosion per seed offline; keep per-chunk
   detail positional.

8. **Area transition leaks.** Ten round trips is the probe because a per-transition leak is
   invisible in one. The bit-identical rebuild assertion (D5.1) is the single most important
   probe in the arc — it is what protects §1.1.

9. **Scope.** Nine phases, three of them L, one of them cuttable. If the arc needs to be
   shortened, cut D7 first, then D6. D1–D5 is the minimum coherent deliverable: one ground map,
   one centreline abstraction, one generated point-to-point stage, streamed, reachable by road.

---

## 9. Phase status (executor updates this)

- [x] D1 — The ground map: one authority for what the ground is — **DONE 2026-08-27,
  DRIVE-VERIFIED: all four checklist items hold — "goood all four hold".** The phase's feel claim
  was "nothing changed", and driving all three circuits confirmed it: no difference anywhere, skid
  marks still asphalt-only, tyre audio still switching on the same lines, the wear line still
  darkening and still adding grip, and all four surface effects still triggering on the same
  surfaces. Byte-identical classification is therefore confirmed by the probe AND by the driver.
  Built and probe-verified 2026-08-24.
  `scripts/ground_map.gd` composes GRASS/DIRT/ASPHALT/PATCH from layers resolved in priority
  order; `stage.grip_at` / `is_tarmac_at` / `deformable_patch_factor` / `_surface_color` are
  one-line delegations, `roughness.road_class_at` and `effects.gd`'s tarmac gate read the map.
  **Probe 1 (golden equality) PASS: byte-identical over 6608 points, SHA-256 `80bffdd150893337…`,
  verified as a controlled A/B against HEAD.** Probe 3 (cost): 52.8 classifier calls/tick,
  0.153 ms/tick = 8.3% of the 1.84 ms baseline.
  **DEVIATION from §5, made on probe 3's evidence:** §5 specifies `grip_at` as a delegation to
  `sample().grip`; it delegates to `ground_map.grip_at()` instead, because routing the hot path
  through the Dictionary would cost 0.487 ms/tick (26.5% of the budget) for a value the caller
  discards. Same classifier, byte-identical output. `sample()` stays the API for multi-field reads.
  **Probe 2 (consumer agreement) found two PRE-EXISTING bugs, both left unfixed and recorded in
  `CHANGELOG.md` 2026-08-24** — fixing either inside a refactor would have hidden a feel change:
  (a) `sound.gd` hears the rally loop as 40% asphalt (1504/1504 gravel points), because its
  `(grip-1.0)/0.25` split is only exact at `dirt_grip = 1.0` and the value is now 1.1;
  (b) the centre patch has two shapes — grip uses a euclidean radius, `deformable_patch_factor` a
  chebyshev one — disagreeing on 392/6608 points.
  Probe 1's script is KEPT at `scripts/probe_ground_lattice.gd` (unwired; header says how to run
  it) because D5 reuses it verbatim.
  **Budget note for D4:** ground map 0.153 + C1.0 centreline 1.05 = ~1.2 ms against a 1.84 ms
  baseline. Streaming arrives with less headroom than this plan assumed.
- [x] D2 — Timing, notes and wear re-parameterised onto arc length — **DONE 2026-08-28,
  DRIVE-VERIFIED: all four checklist items hold.** Lap timing, sector splits and the best-sector
  flash behave as before on all three circuits; pace notes call the same corners at the same
  moments on both routes; the ghost still records and replays; the wear line still forms in the
  same places. Built and probe-verified the same day. `time_trial.gd`'s `atan2` crossings and `RMIN`/`RMAX`
  bands are replaced by arc-length triggers on a per-circuit `Centreline`; `pace_notes.gd` and
  `wear.gd` take their geometry from the same shared centrelines. `Centreline` gained an OPEN
  topology (`from_points`; every wrap conditional on `is_loop()`). `world.gd` builds one centreline
  per circuit at **4320 samples** — the common multiple that lets pace_notes (1440, stride 3) and
  wear (1080, stride 4) keep their exact sample positions, which is what makes the probes exact.
  **Probe 1 PASS (byte-identical timing trace on all three circuits, not merely within a tick).
  Probes 2+3 PASS (bit-identical corner lists and wear field). Probe 4 PASS (open road: start once,
  splits in order, finish TERMINATES the run, no wrap).**
  **Two decisions worth not re-litigating:** (a) sector splits are the arc lengths at the legacy
  theta-thirds, NOT equal thirds — arc length is not uniform in theta, so equal splits would have
  moved every sector boundary; a generated stage gets equal arc-length splits instead. (b)
  `wear._cell()` keeps its polar radial-offset mapping, because changing it moves both the wear line
  and C1's washboard for no gain until a non-polar road exists (§1.1: the old map is the preserved
  calibration bed).
  **MEASURED WARNING, and §6.2's risk made concrete:** two centrelines over the SAME road do not
  agree on `s`. C1's roughness centreline (4000 samples) vs D2's (4320): total length agrees to
  **0.14 mm**, but local `s` diverges by **> 0.30 m at 2.57% of positions, worst case 4.35 m
  (7.2 washboard wavelengths)** — bimodal, because `nearest_point` resolves those positions to a
  different segment at different densities. The two were deliberately NOT unified; C1 is untouched.
  **RESOLVED AT THE ROOT, 2026-08-28 (same day).** The divergence was not a sampling artefact but a
  BUG in `Centreline.nearest_point()`: a fixed 3x3 grid scan that only guaranteed a hit within one
  cell (~2.58 m) while the car drives 4 m off the centreline and roughness queries reach the 7 m
  shoulder. Against brute-force truth it was **wrong at 9.85% of road-edge positions, worst 3.72 m
  = 6.21 washboard wavelengths**. The search now expands until provably correct (ring cap DERIVED
  from the grid extent). After: divergence max **4.35 m -> 0.025 m**, positions over half a ridge
  **2.57% -> 0.000%**, and the single-centreline error is 0.00% at every band. Cost 0.018-0.071
  ms/tick for 4 wheels against the 1.84 ms budget. Lap/sector/split times verified byte-identical
  against D2's saved baseline. **So D4 is no longer constrained on this point** — density may vary
  with streaming/LOD. Full numbers in `CHANGELOG.md` 2026-08-28.
- [ ] D3 — The stage generator: parameters + control points — **BUILT AND PROBE-VERIFIED
  2026-08-28, AWAITING DRIVE VERDICT.** `stage_def.gd` (StageDef), `stage_gen.gd` (StageGen),
  `stage_area.gd` (StageArea, its own area per §1.1). Appears as **SHAKEDOWN**, the fourth `[B]`
  entry, and is a point-to-point ROUTE - the first thing in the game to exercise D2's open-road
  timing. Probes 1 (determinism), 2 (geometric sanity), 3 (pace-note grammar) all PASS; probe 4
  measured as vertical INPUT (see below).
  **DEVIATION from §5's file list:** the stage is built as its own node rather than inside
  `stage.gd`, because D5's area manager loads and unloads whole areas and folding it into stage.gd
  would have to be undone.
  **THREE ROAD-DESIGN FINDINGS worth not rediscovering:**
  (a) A 60 km/h design speed is geometrically impossible here - R = 123 m makes one U-turn cost
  387 m of a 1200 m stage. 30 km/h (R = 30.8 m) fits 1200 m with ~7 corners in the same box. A
  tighter design speed buys BOTH length and corner count; raising it makes a stage straighter and
  shorter, never faster.
  (b) A free heading walk self-intersects. Building the road as a bounded lateral offset along a
  straight start-to-finish SPINE makes it a graph over that spine, so it CANNOT self-intersect -
  structural, not tested-for.
  (c) **Grade limiting alone made the road far WORSE.** Clamping slope leaves a kink, and a kink is
  a curvature spike: the grade-limited stage was gentler than the rally loop by every slope measure
  and **9.2x worse in peak d2y/ds2 - 10.12 g of wheel acceleration at 108 km/h**. Adding AASHTO's
  vertical-curve comfort constraint (~0.3 m/s^2 at design speed) brought it to 1.02x the rally loop.
  A road needs BOTH constraints; the vertical one looks redundant until the second derivative is
  measured.
  **Probe 4 is half-deferred:** peak Fz and bottomed-frame count need a driven lap, and the
  synthetic autopilot could not drive either road representatively (the RALLY LOOP reference spent
  1103/2400 frames off the road). Measured the vertical INPUT instead, which needs no driver. The
  Fz half goes to the drive test.
  **Open for a later phase:** corner severity clusters at the constraint boundary (2 bands, not a
  road book's 1-6). The lever is a design speed that VARIES along the stage, which is what real
  roads have. Full numbers in `CHANGELOG.md` 2026-08-28.
- [ ] D4 — Chunked terrain, streaming and LOD — **execution prompt written 2026-08-29:
  `docs/PROMPT-d4-streaming.md`.** Gated on D3 being drive-verified. Carries forward the three D3
  traps that will reappear here in new costumes: non-uniform sample spacing breaking stencils (a
  chunk boundary IS a spacing discontinuity), height-field probes being blind to mesh artefacts
  (D3's jagged edges were resolution, found only by screenshot), and derived-vs-picked bounds.
  Note the file-list deviation: `stage_chunks.gd` belongs inside `StageArea`, replacing its
  `_build()`, because D3 built the stage as its own node for D5's benefit.
- [ ] D5 — The area manager and the connecting tunnel
- [ ] D6 — Mixed-surface transitions
- [ ] D7 — Deformable ruts along the corridor (optional)
- [ ] D8 — Bake defaults, prune, end-to-end verification
_(the centreline abstraction that was D2 now lives in **C1.0** — see the drivetrain plan)_
