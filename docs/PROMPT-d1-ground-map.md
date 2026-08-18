# Execution prompt — Phase D1: the ground map

Paste this into a fresh session. It is an EXECUTION prompt, not a planning one: you are building
D1, then stopping at the user's drive checklist.

**PREREQUISITE — check this before writing any code.** D1 is the first phase of Arc D, and Arc D
runs AFTER Arc C1. Open `docs/PLAN-drivetrain-suspension.md` §9 and confirm C1 is ticked and
drive-verified. If it is not, STOP and tell the user — C1 owns the `road_class_at(x, z)` seam and
the centreline that D1 and D2 build on, and doing D1 first means writing that seam twice.

---

Read `CLAUDE.md`, `docs/ROADMAP.md` and `docs/PLAN-stages-ground-map.md` before touching anything —
§0 has the working rules, §5 the phase specs, §6 the amendments Arc D forces on C1, §7 the
regression surface, §9 the live status. They are the authoritative project state. Also read §0 and
§9 of `docs/PLAN-drivetrain-suspension.md`, because the car's calibration lives there.

**Execute Phase D1 ONLY**, exactly per §5 Phase D1, then stop at the user driving checklist. Do not
start D2, and do not touch `time_trial.gd`.

## What D1 is, and the one thing that makes it hard

`GroundMap.sample(x, z) -> GroundSample`: one authority for what the ground IS at any position —
`surface` (GRASS / DIRT / ASPHALT / PATCH), `road_class` (C1's ISO 8608 coefficient), `deformable`,
`grip`, `colour`, `audio`. Composed of **layers queried in priority order**, each a pure function of
position: base terrain, then road corridors, then overrides (centre deformable patch, drag strip).
That composition is the whole point — it is what later lets a second area exist without touching
the first.

**This phase changes no behaviour. Its success condition is that NOTHING MOVES.** That is what
makes it hard: there is no feel to aim for, only equality to preserve. Resist every temptation to
improve something while you are in there. If you find a real bug, record it and leave it.

`stage.grip_at()` becomes a one-line delegation to `GroundMap.sample().grip`, **keeping its exact
signature** — `wear.gd` wraps it as `surface_source` and that wrapper is load-bearing for M6. Every
grip query in the project must keep flowing through `surface_source`, never `stage.grip_at`
directly.

## Why this is worth doing at all

Surface is currently decided independently in at least three places: `stage.grip_at` (polar
distance tests), `world.gd`/`effects.gd`'s skid-mark gate (a grip threshold), and `sound.gd` (a
base-grip split). Three sources that can disagree. Today that is theoretical; the moment D6 adds
gravel dragged onto tarmac it stops being theoretical, because the tyre would grip one surface
while the audio and particles played another.

## Context the plan text predates

- **Surface names are canonical and must not be blurred.** `CLAUDE.md` has both lists: the three
  circuits are **DIRT CIRCLE / RALLY LOOP / ASPHALT RING** (say "rally loop", never "dirt loop" —
  there is a separate dirt circle), and the four surface effects are **asphalt smoke / asphalt tire
  tracks / dirt-dust plumes / dirt-gravel particles**. The ground map's `audio` and `colour` keys
  will be read by those systems, so use their names exactly.
- **M11 landed since the plan was written.** Particles now live in `scripts/effects.gd`, driven by
  contact-patch slip velocity and tyre temperature — not the old "is it spinning" test in
  `world.gd`. That file is a `GroundMap` consumer and belongs in probe 2's agreement check.
- **C1 will have created `road_class_at(x, z)`** as a simple surface test (§6.1). D1 replaces its
  BODY with a ground-map lookup and changes nothing else. If C1 did not leave that seam, say so in
  your report rather than quietly refactoring every roughness call site.
- **C1 will also have written the centre-patch exclusion as a query** (§6.3). That query becomes
  the ground map's `deformable` flag. Same rule: replace the body, not the call sites.
- **The stage's public API is small** — `grip_at`, `_height`, `_road`, `_road_halfwidth`,
  `_asphalt_r`, `_circuit_r`, `get_spawn`, `get_spawn_for` — which is why this refactor is
  tractable. Keep it that way.

## Working rules for this session

- Compile gate: `./check.sh` must print `✅ Godot check clean` after every edit. It no-ops when
  nothing under `scripts/` is newer than its marker — `rm -f .last_check` to force a real run.
- Validate with temporary headless print-probes, then REMOVE them (script AND the `world.gd`
  block). Harness pattern is in §0: a `Node` with a `_physics_process` state machine using
  `Input.action_press/release`, added by a temporary env-gated block in `world.gd` `_ready()` and
  then `move_child(probe, 0)` — it MUST sit before the car in the tree, because
  `is_action_just_pressed` only reports true on the press frame and the car reads input in tree
  order.
- **Probe hygiene, learned the hard way here:** measure HORIZONTAL ground speed
  (`Vector2(v.x, v.z).length()`), never `linear_velocity.length()` — the latter includes vertical
  velocity, and a probe that ran off the end of the drag strip once reported a falling car as a
  244 km/h top speed. Bound every probe so it stops before it leaves the road, and make any wait
  condition match FAILURE as well as success or it will poll forever.
- **Beware fixed search bounds in derived maths.** A `_mf_peak_u` bisection over a hard-coded
  `[0, 60]` bracket silently mis-placed a derived curve peak once the shape factor moved outside
  the range it was written for — no crash, no symptom, wrong physics. If D1's layer composition
  or any lookup uses a bounded search or a clamp, derive the bound instead of picking one.
- New tunables = `@export` vars + a row in `tuning_panel.gd` `_specs` **and a HELP line in the same
  commit** — the panel is A-Z sorted with a hover banner, and coverage is asserted. When two
  tunables differ only by which AXIS or SURFACE they act on, put that word at the FRONT of the
  label; four sliders once began "Peak slip" and the user could not find the one they wanted.
- Update `CHANGELOG.md` when the phase closes or a measured finding changes what we believe.
  Write entries to be GREPPED: name the symptom in driving words, and record the numbers.
- You cannot verify feel. Leave the D1 checkbox unticked with "awaiting drive verdict" and hand
  over the driving checklist.
- When the gate is clean, commit and push to origin/main (`github.com/sagizarbel-cloud/rally-sim`).

## Probes this phase must run (pass conditions in §5 Phase D1)

1. **Golden equality — this IS the phase.** Sample `grip_at` at a fixed lattice of world positions
   (a few thousand, spanning all four surfaces and both circuit shoulders) before and after the
   refactor. Pass: **byte-identical classification at every point.** Capture the "before" lattice
   FIRST, from the unmodified build, and keep it — D5 reuses exactly this probe to prove the
   calibration bed rebuilds bit-identically after an area transition.
2. **Consumer agreement.** At the same lattice, assert the skid-mark gate (`effects.gd`),
   `sound.gd`'s surface split and `grip_at` all report the same surface class. **Any disagreement
   is a pre-existing bug this refactor has just surfaced — record it in the CHANGELOG and report
   it; do NOT silently "fix" it**, because that would be a feel change hidden inside a refactor.
3. **Cost.** `sample()` calls per frame × measured cost, against the 1.84 ms/tick baseline. It is
   called per wheel per frame and by several consumers, so measure rather than assume.

## User drive checklist

- [ ] Drive all three circuits: nothing feels different, at all. (This is a SUCCESS, not a
      disappointment — D1 is scaffolding for everything after it.)
- [ ] Skid marks still appear only on asphalt; tyre audio still changes on the same lines.
- [ ] The wear line still darkens and still adds grip on the rally loop.
- [ ] Dust plumes, gravel particles and asphalt smoke all still trigger on the same surfaces.

## State of the tree

Arc A complete and drive-verified. Arc B complete and drive-verified (B1–B4); B5's prune, audit and
bake are done, with only its §8 end-to-end drive-through outstanding — that is the user's to run
and does not block Arc D. M11 particles landed. Physics 120 Hz, ~1.84 ms/tick measured.

Every export you will meet is a drive-verified calibration value, not a default to improve on.
Suspension travel is 320 mm; the car rides its bump stops often on the rally loop and that is
correct — the outstanding B3 hydraulic-bump-stop revision is NOT Arc D's job.

`CHANGELOG.md` is the forensic history — grep it by SYMPTOM before diagnosing anything that smells
like a recurrence. It is also where the reasoning behind the current calibration lives, which
matters here because D1 must preserve all of it exactly.
