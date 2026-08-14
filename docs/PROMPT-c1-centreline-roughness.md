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

All four corners peg 100% of suspension travel on the rally loop at 100 km/h, and C1 adds vertical
input on top of that. C1's fourth probe re-measures it. **If it degrades, do not reach for ride
height and do not shrink `roughness_gain` to hide it** — both have already been tried and ruled
out, and the elimination is complete:
- **Travel is NOT the constraint.** Gravel WRC cars run 250–300 mm of TOTAL travel. This car was
  taken to 500 mm and still pegged; it is now at **320 mm** (`rest_length` = `max_travel` = 0.32),
  and cutting it actually *lowered* peak Fz from 28.8 to 23.1 kN, because the spring builds force
  over the whole stroke. More travel was manufacturing its own load spikes.
- **B2 was the leading hypothesis and is disproven.** The asymmetric digressive damper shipped and
  is drive-verified; it cut peak Fz 23% but slightly *increased* stop contact (31 → 50 frames).
- **What remains is the bump stop itself**, which is still a pure displacement spring: it stores
  the impact and hands it back. Real end-of-travel control is hydraulic — velocity-sensitive and
  dissipating energy as heat. That is the outstanding B3 revision.
**So: expect the car to ride its stops often — that is correct, a real rally car does — report the
numbers against the recorded baseline, and stop. The hydraulic stop is not C1's job.**

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
4. Travel budget: peak `Fz`, max compression and bottomed-frame count on the rally loop at
   100 km/h, before vs after, against B3's recorded numbers.

## State of the tree

Arc A complete and drive-verified. **Arc B: B1, B2 and B3 done and drive-verified; B4 implemented
and awaiting its drive verdict; B5's prune and panel audit done, but its value-bake and the §8
end-to-end drive still need the user.** The B3 hydraulic-bump-stop revision is outstanding and is
NOT C1's job. Physics 120 Hz, ~1.84 ms/tick measured. Suspension travel is 320 mm.
Baseline to compare the travel probe against (rally loop, ~100 km/h, current build): 4/4 corners
pegged, 177 frames on the stops, peak Fz 23.1 kN.
`CHANGELOG.md` is the forensic history — grep it by SYMPTOM before diagnosing anything that smells
like a recurrence.
