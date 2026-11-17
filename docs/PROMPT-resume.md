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
| D4 streaming | accepted 2026-08-31 with one item open: *"the game has hiccups sometimes"*. **Root causes found and fixed 2026-11-16; one confirmation drive is owed** |
| D6 mixed surfaces | driven 2026-11-16: three of four items pass. The tyre-AUDIO half of the fourth is untested and cannot be judged until the tyre audio itself is fixed (bug run) |
| D7 ruts | open, optional, first to cut |
| D8 bake / prune / end-to-end | open — closes Arc D |

The tree is clean apart from `docs/PROMPT-godot-46-migration.md`, which is untracked and was
written by ANOTHER session — read it when you reach step 3; do not commit it unless the driver
says to. Sessions run on this repo in parallel and one has already swept another's work into its
commit: **stage files by name, never `commit -a`, and `git log --oneline -3` before committing.**

---

## STEP 1 — close D4's open item (needs the driver for about four minutes)

### What the hiccups were

Not GPU upload of new chunk meshes, not the LOD count, not the retire cache. They were the
streamer's own **bookkeeping**, on the main thread, inside the physics tick
(`scripts/stage_chunks.gd`):

1. **An idle streamer cost more than the car.** `update()` re-scanned 338 resident chunks and 1521
   view-window cells on every tick with no job in flight: 4.3 ms of every 16.7 ms frame with the
   car PARKED on the stage, and 2.25 ms on the LEGACY map, where nothing can ever be wanted.
2. **The measured vertex cost tracked the mix of chunks being built, not the machine**, so the
   derived radii swung (`r_solid` 65–100 m) about twice a second, and every swing re-marked the
   whole far-field band — about 4 ms inside one physics tick. That made 8–10 ms ticks five times a
   second during the fill after `[B]`, which is *"worst in the first 20 sec"*.

Both are fixed, and the first fix is **proved to be the same streamer** — 5500 calls along a driven
path, 0 differences from the old per-tick scan. Numbers, method and the before/after table are in
`CHANGELOG.md` 2026-11-16. **What is NOT established is that this is everything the driver feels**:
the self-test parks the car, so the at-speed case is inferred. One drive settles it.

### The drive

A temporary frame logger is committed and always armed: `scripts/probe_framelog.gd`, wired at the
end of `world.gd _ready()`. It never runs headless, so `./check.sh` cannot disturb a log.

1. **Launch the game so its window comes to the FRONT.** A window opened behind another app is not
   vsynced and macOS throttles it; a run started that way is unreadable (this cost a whole drive).
   Run this in the background — it returns when the driver quits:
   ```bash
   open -n -W -a /Applications/Godot.app --args --path /Users/sgyzrbl/rally-sim
   ```
2. **Ask the driver to:** press `[B]` to SHAKEDOWN and drive away at once (the first 20 s is the
   part they reported), drive a few minutes at speed, stop and turn round once, drive back, and
   quit normally. Nothing else is needed — every key and pad button is logged as an event.
3. **Read it:**
   ```bash
   ls -t ~/Library/Application\ Support/Godot/app_userdata/Rally\ Sim\ \(M0\)/framelog-*.csv | head -1
   ```
   ```bash
   python3 tools/framelog_report.py "<that file>"
   ```
   The report gives what a normal frame costs per system, pacing by speed, and — the part that
   matters — every burst of late frames with the **section and system that caused it**, then a
   *BY CAUSE* table.

### What to do with the answer

| the report blames | meaning | next move |
|---|---|---|
| nothing on the streamer, and the driver calls it smooth | **done** | close the item (below) |
| `the STREAMER … PRIME after a teleport` | the known ~0.21 s freeze on arriving at the stage | already on the after-arc fix list; not this item |
| `the STREAMER … scan` or `finalise` | what is left of the streamer's own spikes: a scan is ~1.7 ms, only when the car has entered a new lattice cell AND a job has just finished; a full-detail chunk's finalise is unsliced | make the scan cheaper (walk the band's cells instead of the window) or make finalise resumable — and re-run the equivalence probe |
| `draw: blocked in present with no extra CPU work` at speed, with a high particle count | GPU-bound: plume overdraw, the mirror's second render of the scene, or a Retina-size window | A/B with `[G]` (effects off) and windowed vs fullscreen before changing anything |
| `draw: N pipeline(s) compiled` | first use of a shader variant mid-drive | pre-warm that material at load |
| `physics: vehicle_m2` or `jolt step` | the car itself — usually off the road or against a bank | look at what the car was doing; this is not D4 |
| `window focus`, `after draw`, `CPU itself slow` | the OS: a focus change, the event pump, the thread descheduled | tell the driver; it is not the game |
| no late frames at all, but the driver still feels it | the 25 ms threshold is too coarse for what they feel | ask WHERE and WHEN, and look at the 18–25 ms band in the log |

**To close the item:** tick D4 in §9 with the driver's words, add the verdict to `CHANGELOG.md`,
then remove the instrumentation — `git rm scripts/probe_framelog.gd scripts/probe_framelog.gd.uid
tools/framelog_report.py tools/probe_streamer_equivalence.gd`, delete the marked block at the end
of `world.gd _ready()` — run `./check.sh`, commit, push. (If a before/after is wanted around the
Godot 4.6 migration, the logger can be restored from git history.)

### Do not reach for these — each was measured or reasoned out

- **Cutting a LOD level.** The driver offered it *if it were the limiting factor*. It is not: the
  scan cost the same with one level. Every tile is still built about twice (LOD 4, then 2, then 1)
  and that is real build load, but it is not what hitched.
- **A rescan timer** ("every N ticks"). It makes the ground late by a TIME, which at speed is a
  distance the lead-distance derivation knows nothing about. The scan is keyed on the lattice
  cell the car is in — a distance — for that reason.
- **Widening the 20% re-derive band** to calm the radii. That hides the wobble and leaves the lead
  wrong. The estimator now samples only full-detail, fully-searched chunks.
- **More LOD hysteresis.** Flat at 1, 2 and 3 spans (1148 / 1164 / 1160 builds).
- **Spreading `prime()` over several ticks.** The car is already there; late ground under a car is
  a fall through the world.

### Measuring without the driver

The logger has a self-test, which is how the fix was measured before anyone was asked to drive:
`RS_FRAMELOG=/abs/out.csv RS_FRAMELOG_STAGE=1 RS_FRAMELOG_STALL=40` in front of the Godot binary
with `--path . --quit-after 1900` parks the car on SHAKEDOWN two seconds in and blocks the main
thread for 40 ms every 4 s, so both the steady cost and the recovery from a hitch can be read.
`tools/probe_streamer_equivalence.gd` is the call-for-call comparison against the old per-tick
scan: copy it to the project root as `_probe_tmp.gd`, run
`godot --headless --path . --script res://_probe_tmp.gd`, read the `PROBE` lines, delete the copy.
**If you change `update()`, `_scan()` or `_next_job()`, it must still print 0 differences.**

---

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
  needs them, and are deleted. The frame logger is the exception while D4's item is open.
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

Tell the driver in two lines what was found and fixed, launch the game in front, and ask for the
four-minute drive in step 1. Everything else waits on that verdict.

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
