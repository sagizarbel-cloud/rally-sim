# Continuation prompt — rally-sim, handed over 2026-11-16

Paste this into a fresh session. It is a hand-over, not a phase prompt: it says where the project
stands, what was learned in the session that wrote it, and what to do next and in what order.

**Read first, in this order:** `CLAUDE.md`; `docs/ROADMAP.md` — the block headed *"State as of
2026-11-16"* and the *after-arc fix list* under it; the top entry of `CHANGELOG.md` (2026-11-16);
and the D4 and D6 entries in `docs/PLAN-stages-ground-map.md` §9. `CHANGELOG.md` is forensic —
grep it by SYMPTOM, in driving words, before diagnosing anything that smells like a recurrence.

---

## The order of work — set by the driver, still in force

> "we start with the dirty tree - finish D4 open items - move to the other bugs and clean them and
> then migrate to godot 4.6 before continuing development"

So: **(1) close D4's one open item → (2) a bug-cleaning run → (3) migrate to Godot 4.6 → (4)
development continues** (D7 optional, D8, then Arc E). Do not reorder it and do not start the
migration early; it has its own prompt and its own prerequisite.

## Where things stand

| phase | state |
|---|---|
| D1, D2, D3, D5 | done, drive-verified |
| D4 streaming | **done** - its last item, the hiccups, closed on the drive 2026-11-16 (*"i think it looks better"*; the frame log blamed nothing on the streamer) |
| D6 mixed surfaces | driven 2026-11-16: three of four items pass. The tyre-AUDIO half of the fourth is untested and cannot be judged until the tyre audio itself is fixed (bug run) |
| D7 ruts | open, optional, first to cut |
| D8 bake / prune / end-to-end | open — closes Arc D |

The tree is clean apart from `docs/PROMPT-godot-46-migration.md`, which is untracked and was
written by ANOTHER session — read it when you reach step 3; do not commit it unless the driver
says to. Sessions run on this repo in parallel and one has already swept another's work into its
commit: **stage files by name, never `commit -a`, and `git log --oneline -3` before committing.**

---

## STEP 1 — close D4's open item: DONE 2026-11-16

The confirmation drive happened: *"i think it looks better"*, and the frame log (27 late frames in
6536, 107 s on SHAKEDOWN) blamed no burst on the streamer's scan or finalise. D4 is ticked in §9,
the verdict is in `CHANGELOG.md`, and the frame logger, its report script and the equivalence
probe were removed. **They are in git at commit c7b5a3d** if a before/after is wanted around the
Godot 4.6 migration - restore `scripts/probe_framelog.gd`, `tools/framelog_report.py` and the
six-line block at the end of `world.gd _ready()`. The log's one new finding, a 150 ms Jolt step
stall ~6.6 s after arriving on the stage, is on the after-arc fix list beside the arrival freeze.

The streamer's do-not-retry list (no LOD cut, no rescan timer, no wider re-derive band, no more
LOD hysteresis, no spreading `prime()` over ticks) lives in §9's D4 entry.

## STEP 2 — the bug-cleaning run

Everything below is already written up with its drive context; the pointers are where. **Put the
list to the driver and agree an order before starting** — several are real trade-offs, and they
have asked to be shown the levers and costs rather than have them picked. A proposed order:

1. **Tyre audio** (`docs/PLAN-stages-ground-map.md` §6b): the tyre voice is gated on longitudinal
   slip with no slip angle, so it only fires on the handbrake and a sideways gravel slide is
   silent; grass and gravel also sound identical. **This is first because it unblocks D6's last
   item** — "audio changes with the surface at the same moment the grip does" cannot be judged
   while there is nothing to hear. Fix it, ask for that one verdict, and D6 closes.
2. **The after-arc fix list** (`docs/ROADMAP.md`): engine takes too much damage from jumps (needs a
   per-component damage model, not a bigger threshold); carve the terrain for the tunnel portal
   (the driver chose "solution 2"); berm scalloping at the road edge **together with** the new
   corner-berm item — *"we will need to tweak it for a more precise generation"* — **ask what
   "precise" means first**, and note the ridge is about one lattice vertex wide, so tuning its four
   numbers cannot make it precise; stages are not relocatable (elevation sampled at absolute world
   coordinates); corner rhythm and hairpin tightness; the ~0.2 s freeze on arriving at the stage;
   and the frame-headroom list the logger produced.
3. **§6b's other carried defects:** the centre patch has two shapes; `wear._cell()` is still polar.
4. **Arc C's open items** (`docs/PLAN-drivetrain-suspension.md` §9): C2 was driven and REOPENED —
   the wash-out cue is unconfirmed, which is the point of the phase — and alongside it *"very hard
   to get out of an oversteer when the wheels are hot"*. C3/C4 need a steering wheel.
5. **B3's hydraulic bump stop**, outstanding since Arc B.

## STEP 3 — migrate to Godot 4.6

`docs/PROMPT-godot-46-migration.md`. Its own prerequisite is a CLEAN tree and no phase mid-flight
in §9, so D4 and D6 have to be closed first (or the driver waives it — ask, do not assume). The
2026-11-16 changelog table of what a normal frame costs per system is a ready-made "before" for
the engine change.

## STEP 4 — after that

D7 (optional — cut it first if the arc needs shortening), D8 (bake the driver's preferred
parameters, prune, end-to-end), then Arc E, sketched in `docs/ROADMAP.md`: procedural ground
texturing, roadside foliage, clouds and skybox, a real car model, car profiles (physics, not art,
and unblocked today).

---

## What this session learned — beyond the fix

- **One number per frame cannot find a hitch.** Three drives logged `delta` and each was read
  differently. Cutting the frame into the sections the engine executes, per system, found the
  cause in one self-test. When the question is "where does the time go", time the sections.
- **Three instrument faults, all silent:** `delta` is clamped at 8 physics steps (66.7 ms);
  `Performance.TIME_PHYSICS_PROCESS` is the worst tick of the last SECOND, not this frame; and a
  window launched behind another app is not vsynced.
- **A default-on probe with one fixed output path will be destroyed by the compile gate**, which
  runs the game headless for 60 frames. A measured drive was lost that way.
- **Measure before spending the driver's time.** The discriminating test in §9 was checked before
  the drive and found unable to work; later the fix was measured with a self-test before asking
  for a drive. Both saved a drive.
- **A "derived" quantity can still be fed by a bad measurement.** The lead distance was correctly
  derived from a vertex cost that was sampled from the wrong population.
- **Losing window focus stalls the game for up to 0.6 s** and is the OS, not a bug. Bursts of long
  frames at walking pace at the END of two driven runs are probably the driver stopping to quit —
  unconfirmed; the new log's focus and key events will say.

## Working rules that have actually caught bugs here

- **Compile gate:** `./check.sh` must print `✅ Godot check clean`. It no-ops unless something under
  `scripts/` is newer than its marker — `rm -f .last_check` forces a real run. It only verifies
  scripts the running game LOADS; check an unwired file with `--check-only --script`.
- **A new `class_name` script needs `--import`** before `Foo.new()` resolves.
- **Derive bounds, never pick them**, with the derivation in a comment — and name the tempting
  wrong fix beside it, because the next session will reach for it.
- **Temporary probes live in the scratchpad**, are copied under `res://` only for the seconds a run
  needs them, and are deleted.
- **A height-field probe cannot see a mesh artefact** — screenshot it; a windowed run can
  photograph itself.
- **A synthetic autopilot is not a driver.** Defer a feel measurement to the drive.
- New tunables = `@export` on `vehicle_m2.gd` (the Tab panel binds vehicle properties only) + a
  `tuning_panel.gd` row + a HELP line, in the same commit.
- **You cannot verify feel.** Tick a checkbox only on the driver's verdict, in their words.
- Update `CHANGELOG.md` when a phase closes or a measurement changes what we believe.
- When the gate is clean, commit by file name and push to origin/main
  (`github.com/sagizarbel-cloud/rally-sim`, public).

## Suggested opening move

Step 1 is done. Open step 2: put the bug list to the driver and agree an order, starting with the
tyre audio so D6 can close.

## UPDATE 2026-11-17: the D4 confirmation drive was made (log framelog-2026-11-16T22-30-36.csv)

110 s, 2.1 km on SHAKEDOWN. Run it again with `python3 tools/framelog_report.py "<that log>"`.
- **The streamer is clean while driving.** No late frame is blamed on it after arrival. Typical
  physics 4.0 ms/frame. Band re-marked 2 times. r_solid 77-92 m.
- **What remains:** (1) the known `prime()` freeze when arriving on the stage: 198 ms, 16 chunks
  (already on the fix list). (2) ONE NEW stall: 0.7 s at t=16.7 s, 6.6 s after arriving, about 65 m
  driven, 44 km/h. The whole stall is inside the **Jolt step** (150 ms steps x3), and it starts the
  same frame as the **co-driver's second spoken note** (TTS start 16.38, stop 17.37). The other 15
  notes caused nothing. Suspects, not proven: Jolt meeting new chunk colliders for the first time,
  or the macOS TTS call blocking. It is NOT the streamer's scan.
  (3) Older v1 logs show similar 200-320 ms stalls at low speed after minutes of driving. These are
  unexplained.
- **Next:** ask the driver whether the drive FELT smooth. If yes, tick D4 and file the 0.7 s
  Jolt/TTS stall as its own bug in the bug run. Reproduce it first with the logger kept in place.
  Do not remove the instrumentation until that stall is understood.
