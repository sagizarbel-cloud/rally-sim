# Continuation prompt — picking rally-sim back up

Paste this into a fresh session. This is **not** a phase execution prompt: the project was paused
mid-flight on 2026-09-05 and nothing has moved since. Your first job is to resolve that, not to
start new work.

Read `CLAUDE.md` and `docs/ROADMAP.md` first — ROADMAP is the authoritative state. `CHANGELOG.md`
is the forensic history; grep it by SYMPTOM before diagnosing anything that smells like a
recurrence.

---

## FIRST: the tree is dirty, and that blocks more than it looks

`git status` has **uncommitted work in four files** (~60 lines): a `stage_max_chunks` resident-chunk
budget export on the car, a `[J]` performance overlay reporting the stage streamer's residency
alongside draw calls and primitives, and the `fx.stage_area` wiring that feeds it.

**That is not stray debris — it is instrumentation aimed squarely at D4's one open item** (the
hiccups, below). Someone was part-way through measuring exactly the right thing.

There is also an **untracked `docs/PROMPT-godot-46-migration.md`** (a 4.4 → 4.6 engine upgrade
prompt). Note its own prerequisite: *"`git status` must be CLEAN and §9 must show no phase
mid-flight."* Neither holds right now, and its own instruction is to defer to the bug-cleaning slot
between arcs — which is where the user's sequencing already puts it. **Do not start the migration.**

**Ask the user before doing anything with the uncommitted work.** The options are finish it, commit
it as-is, or stash it — and it is their call, not yours. Sessions work on this repo in parallel and
an earlier `commit -a` has already swept another session's work into its commit, so: **stage your
own files explicitly, never `commit -a`, and check `git log` before committing.**

## Where Arc D actually stands

| phase | state |
|---|---|
| D1 ground map | **done, drive-verified** |
| D2 timing/notes/wear on arc length | **done, drive-verified** |
| D3 stage generator | **done, drive-verified** |
| D4 chunked terrain + streaming | built, probe-verified — **one item open** |
| D5 area manager + tunnel | **done, drive-verified** |
| D6 mixed-surface transitions | built, probe-verified — **awaiting drive verdict** |
| D7 deformable ruts | open, **optional and cuttable** |
| D8 bake, prune, end-to-end | open — closes the arc |

The game has **SHAKEDOWN**, a generated point-to-point stage: 4779 m timed in a 4 km box, streamed,
reachable by driving through a tunnel, with a surface that varies along its length.

## The two things that need the USER, not you

**1. D4's open item — the hiccups.** *"The feel is that the game has hiccups sometimes"*, with no
fps drop. **This cannot be settled headless, because headless has no GPU.** The hypothesis is chunk
mesh creation (26.6 ArrayMeshes/s, GPU upload on first draw). The test is a minute of driving: down
a stretch, turn round, come back. The LRU cache means the second pass creates almost nothing, so
**smooth on the way back = it IS chunk creation** (fix: fewer LOD levels) and **identical = it is
not**. The uncommitted `[J]` overlay exists to make this visible — finishing it is probably the
cheapest path to an answer.

**2. D6's drive checklist**, four items, in §9. One of them is a question rather than a pass/fail:
D6 fixed a D3 bug where the corner berm had been piling material on the **inside** of every corner
since D3 (against its own comment), so the user is being asked whether the stage reads better or
worse now that it is on the outside.

## What is queued behind that

1. **D7 (optional)** — the plan says cut D7 first if the arc needs shortening; D1–D5 was the minimum
   coherent deliverable and it is already exceeded.
2. **D8** — bake the user's preferred parameters, prune dead code, end-to-end verification.
3. **The after-arc fix list** (`docs/ROADMAP.md`, five items, all recorded with their drive context):
   engine takes too much damage from jumps; carve the terrain for the tunnel portal (the user has
   already chosen "solution 2"); berm scalloping at the road edge; **stages are not relocatable**
   (elevation is sampled at ABSOLUTE world coordinates, so moving an area changes its terrain);
   corner rhythm and hairpin tightness.
4. **Arc C's open items** — C2 (self-aligning torque) was DRIVEN and REOPENED: gravel vs tarmac
   differ (pass) but the wash-out cue is unconfirmed, which is the whole point of the phase. Also
   open alongside it: *"very hard to get out of an oversteer when the wheels are hot."* C3/C4 need a
   steering wheel and C4 may honestly conclude "not feasible".
5. **The §6b carried defects** in `docs/PLAN-stages-ground-map.md`: tyre audio only fires on the
   handbrake (the voice is gated on longitudinal slip and `slip_angle` is absent, so a sideways
   gravel slide is silent); grass and gravel sound identical; the centre patch has two shapes; and
   `wear._cell()` is still polar.
6. **B3's hydraulic bump stop**, still outstanding from Arc B.
7. Then the user's own sequencing: **a bug-cleaning run, then Arc E** (procedural ground texturing,
   roadside foliage, clouds/skybox, a real car model, car profiles) — sketched in `docs/ROADMAP.md`
   under "Arc E (sketch)". Two notes already recorded there: **car profiles are physics, not art,
   and are unblocked today**; and **ground texturing must come after D6**.

## Working rules (the ones that have actually caught bugs here)

- **Compile gate:** `./check.sh` must print `✅ Godot check clean`. It no-ops when nothing under
  `scripts/` is newer than its marker — `rm -f .last_check` to force a real run. It **only verifies
  scripts the running game LOADS**, so a new unwired file can be badly broken and still pass; check
  those with `--check-only --script res://scripts/<file>.gd`. (It used to `exit 0` when Godot was
  missing, which silently passed the gate for a whole session — it hard-fails now, but confirm it
  actually RAN.)
- **A new `class_name` script needs `--import`** before `Foo.new()` resolves.
- **Non-uniform sample spacing silently breaks every stencil.** This caught Arc D at least four
  separate times (degenerate spline endpoints, a fixed-step extension against variable samples, a
  sample-count constant tied to a retired spacing, and chunk boundaries). Anything that differences
  neighbours is a candidate.
- **A height-field probe cannot see a mesh artefact.** D3's "jagged edges" survived several rounds
  of correct measurement because the defect was mesh resolution. **Screenshot it** — a windowed
  Godot run can photograph itself.
- **Derive bounds, never pick them**, with the derivation in a comment. Arc D has many worked
  examples (min radius from design speed, vertical curvature from AASHTO comfort, curve widening
  from vehicle off-tracking, taper length from the curvature limit).
- **A synthetic autopilot is not a driver** — Arc D's spent 1103 of 2400 frames off the road on the
  reference circuit. Defer a measurement to the drive test rather than publish a bad driver's number.
- Temporary probes get REMOVED (script and the `world.gd` block). `scripts/probe_ground_lattice.gd`
  is the one deliberate exception — D5 reuses it.
- New tunables = `@export` + a `tuning_panel.gd` row **and a HELP line in the same commit**. The
  panel binds VEHICLE properties only, so a tunable on another node is mirrored onto `vehicle_m2.gd`
  and synced (see `stage_seed`).
- **You cannot verify feel.** Leave the checkbox unticked with "awaiting drive verdict" and hand
  over the checklist.
- Update `CHANGELOG.md` when a phase closes or a measured finding changes what we believe — written
  to be GREPPED, naming the symptom in driving words with the numbers.
- When the gate is clean, commit and push to origin/main
  (`github.com/sagizarbel-cloud/rally-sim`).

## Suggested opening move

Report the dirty tree and ask the user which they want: finish the `[J]` instrumentation and settle
the D4 hiccups, take the D6 drive verdict, or park Arc D and start the bug-cleaning run. **Do not
pick for them** — and do not start the Godot 4.6 migration, which has its own prompt and its own
prerequisite that is not currently met.
