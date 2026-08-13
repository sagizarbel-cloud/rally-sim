# Execution prompt — Phase C1: centreline + surface roughness

Paste this into a fresh session. It is an EXECUTION prompt, not a planning one: you are building
C1, then stopping at the user's drive checklist.

---

Read `CLAUDE.md`, `docs/ROADMAP.md` and `docs/PLAN-drivetrain-suspension.md` before touching
anything — §0 has the working rules, §5 the phase specs, §9 the live status. They are the
authoritative project state.

**Execute Phase C1 ONLY**, exactly per §5 Phase C1, then stop at the user driving checklist. Do
not start C2, and do not start Arc D.

C1 has two halves and **they must be done in order**:

- **C1.0 — the centreline abstraction** (`scripts/centreline.gd`). This was Arc D's phase D2 and
  was moved into C1 on 2026-08-13 specifically so it lands before anything depends on it.
- **C1.1–C1.4 — the roughness field**, enveloping filter, and injection at the suspension raycast.

## Why C1.0 comes first — do not reorder this

C1 models washboard as `sin(2π·s / λ)` where `s` is distance along the road centreline. The only
`s` available today is derived from θ, because every road in this project is polar, `r = f(θ)`.
Arc D redefines `s` as true spline arc length. **If C1 ships with a θ-derived `s` and Arc D then
changes the definition, every washboard ridge on the existing map moves** — silently invalidating
C1's own drive-verified feel and any braking points the user has learned, with nothing crashing to
tell anyone. Building the real centreline first removes that entire class of rework. This is
recorded as the top risk in `docs/PLAN-stages-ground-map.md` §6.2.

## Context the plan text predates

- **`pace_notes.gd` and `wear.gd` already build sampled centrelines internally.** They derive
  `pts` / `arc` / `elev` / `seglen` from θ (`pace_notes.gd:52-57`, `wear.gd:50`) and then never
  touch θ again. C1.0 should give them the same data through a shared class — **this is a
  re-parameterisation, not a rewrite**, and those two files are the proof that the abstraction
  fits. You do NOT have to convert them in C1 (Arc D's D2 does that); just make sure the class you
  build can serve them, or you will build the wrong shape.
- **`time_trial.gd` is the one that genuinely assumes closed-loop polar topology** (`RMIN/RMAX`
  radius bands at `:17-18`, `atan2` crossings at `:106`/`:119`, θ-thirds sectors). Leave it alone
  in C1. It is Arc D's problem.
- **`nearest_point(x, z)` is called per wheel per physics frame.** Brute force over a few thousand
  samples is 4 × 120 × N distance tests per second. Spatially bin the samples from the start —
  this is design, not optimisation.
- **The existing map is the calibration bed and must not move.** Every baseline this project owns
  is expressed in its terms. C1.0's identity probe holds the geometry to **1 mm**.
- **`_guard_rail(polyline)` in `stage.gd`** already lays panels + posts along any polyline; the
  drag strip is 4 km via `strip_len` deriving `strip_x1 = 4285`. Reusable, not something to rebuild.
- **Two forward-compatibility amendments** that cost nothing now and a refactor later (full list in
  `docs/PLAN-stages-ground-map.md` §6):
  - Ask a function `road_class_at(x, z)` for the ISO road class rather than reading the
    per-surface export inline. Arc D's D1 replaces that function's body and nothing else moves.
  - Write the centre-deformable-patch exclusion as a query, not a hardcoded radius test — it
    becomes the ground map's `deformable` flag.

## The bottoming interaction — read before you touch ride height

B3 recorded all four corners pegging 100% of suspension travel on the dirt loop at 100 km/h, and
C1 adds vertical input on top of that. C1's fourth probe re-measures it. **If it degrades, do not
reach for ride height and do not shrink `roughness_gain` to hide it.** Research on 2026-08-13
reframed this (drivetrain plan, B3 revision): gravel WRC cars run 250–300 mm of *total* travel
while this car has ~323 mm of *bump* travel alone, so "not enough travel" is very likely the wrong
diagnosis. The suspected causes in order are (a) the bump stop is a pure displacement spring that
returns energy instead of dissipating it, where real end-of-travel control is hydraulic and
velocity-sensitive, and (b) **B2 is not implemented yet** and its asymmetric bump/rebound split is
the most likely actual fix. **Report the numbers and stop; the decision is the user's, and it
probably belongs to B2, not to C1.**

## Working rules for this session

- Compile gate: `./check.sh` must print `✅ Godot check clean` after every edit. It no-ops when
  nothing under `scripts/` is newer than its marker — `rm -f .last_check` to force a real run.
- Validate with temporary headless print-probes, then REMOVE them. Probe harness pattern is in §0
  of the drivetrain plan: a `Node` with a `_physics_process` state machine using
  `Input.action_press/release`, added by a temporary env-gated block in `world.gd` `_ready()` and
  then `move_child(probe, 0)` — it MUST sit before the car in the tree.
- **Probe hygiene, learned the hard way:** measure HORIZONTAL ground speed
  (`Vector2(v.x, v.z).length()`), never `linear_velocity.length()` — the latter includes vertical
  velocity, and a probe that ran off the end of the drag strip once reported a falling car as a
  244 km/h top speed. Bound every probe so it stops before it leaves the road, and make any wait
  condition match failure as well as success or it will hang forever.
- New tunables = `@export` vars + a row in `tuning_panel.gd` `_specs`; every new state must be
  reset in `respawn()`.
- You cannot verify feel. Leave the C1 checkbox unticked with "awaiting drive verdict" and hand
  over the driving checklist.
- When the gate is clean, commit and push to origin/main (`github.com/sagizarbel-cloud/rally-sim`).

## Probes this phase must run (pass conditions in §5 Phase C1)

0a. Centreline geometry identity vs direct `_road(θ)`/`_asphalt_r(θ)` — **max deviation < 1 mm**.
0b. `nearest_point` correctness vs brute force, plus its cost against the 1.84 ms/tick baseline.
1. Spectrum: RMS per octave band follows the ISO 8608 power law; gravel clearly above tarmac.
2. Enveloping: a 3 cm × 4 cm bump is strongly attenuated while a 0.6 m washboard passes at near
   full amplitude. **This is the phase's key correctness test.**
3. Repeatability: identical field values at the same world position across frames and respawns.
4. Travel budget: peak `Fz`, max compression and bottomed-frame count on the dirt loop at
   100 km/h, before vs after, against B3's recorded numbers.

## State of the tree

Arc A complete and drive-verified. B1 implemented and awaiting the user's drive verdict, B3 done
(with the revision above outstanding), B2/B4/B5 open. Physics 120 Hz, ~1.84 ms/tick measured.
Last commits: the linear-damping top-speed fix, the 4 km drag strip, and the Arc D plan.
