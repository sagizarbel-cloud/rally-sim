# Changelog

Newest first. One entry per working day, grouped by what changed and why it mattered — not a
copy of the commit log. **`docs/ROADMAP.md` remains the authoritative state**; this file is the
history of how it got there, so a future session can answer "when did this change, and why?"
without reading every diff.

**Keep it current:** add an entry when a plan phase closes, when a bug is fixed, or when a
measured finding changes what we believe about the car. Feel verdicts belong here too — they are
the only verification this project has for feel, and they are otherwise lost in chat.

**Write entries to be SEARCHED, because that is what this file is for.** Its main job is
forensic: when something breaks, or an old bug comes back, this is where you grep for hints
before touching code. So every entry must name the **symptom in the words you would use while
driving** — "inside rear wheel cooking on gentle turns", "car pogos above 400 km/h", "top speed
capped around 130", "launches on grass feel like ice" — not only the mechanism or the name of the
fix. A symptom you cannot search for is a symptom you will diagnose twice. Record the measured
numbers alongside it (before/after, per-wheel loads, distances), since a recurrence is usually
recognised by the numbers drifting back rather than by the symptom returning in full.

---

## 2026-08-27 (B5 §8 driven — Arc B CLOSES; and the C2 steering spike diagnosed, fixed, and two theories killed)

### B5 §8 end-to-end drive-through — Arc B is done

User drove the whole checklist. **Items 1, 2, 5, 6, 7 pass outright** (cold-start ritual and
restart, launch assist, money-shift guard, asphalt ring, `[P]` puncture, damage, ghost, sector
splits, pace notes, wear line, every toggle). **Item 3 passes with notes; item 4 FAILS.** Arc B
closes on that, but the drive-through earned its keep — it turned up four separate things:

- **REGRESSION, unattributed: top speed 236 km/h in 6th against the recorded 259 km/h baseline**
  (−9%). Suspects, in order: broadband roughness was recalibrated **4.5x louder** (`9073979`);
  C1's road-aware damper measurably raises MEAN Fz ~10% over texture via the `max(...,0)`
  rectifier, which raises rolling resistance; and D1 (`cc7b90d`) moved surface classification
  behind `GroundMap`, so a mis-classified drag strip would cost grip in 6th. **A
  `roughness_gain` 0-vs-1 top-speed run separates the first two in one probe** — not yet done.
- **FAIL, item 4 — "i dont think it changed, hard to tell" on the diff presets.** This is a
  REGRESSION: A3 was drive-verified on this exact test (2026-08-05, "feels good") and the presets
  were kept deliberately as a permanent A/B tool. Something since then masks axle-locking
  character. Grep `[1]/[2]/[3]` and `apply_diff_preset` when picking this up.
- **Handling notes, explicitly DEFERRED by the user to a future session — a note, not a bug
  report:** AWD **"seems too slippery - too easy to get into oversteer AND understeer"**; RWD
  **"constantly oversteers"**; the car **"feels too light, too easy to lose control for a 4wd"**.
  Lap times are close to the pre-plan ghost, so pace is intact — this is controllability, not speed.
  Worth checking against the 1 kN-scale one-tick Fz steps documented below, which would make grip
  genuinely unpredictable.
- **Stage request (M6 / Arc D):** widen the band of full-traction surface beyond the track edge so
  running a little wide does not instantly throw the car off; would also help the tight hairpins.

### C2 — the steering spike was NOT what either theory said

**Drive verdict: gravel vs tarmac clearly differ (PASS)** — the 16 deg / 9 deg peak slip angles
read as intended. **The wash-out cue is UNCONFIRMED**, which is the phase's whole point, so **C2 is
not done.** And a real artefact: *"steering jumps to ~15 in each direction for a split second when
turning, or when going straight into a turn doing nothing, before correcting to an opposite lower
value, 3-10 usually."*

**Two plausible theories were both WRONG, and a probe killed them — do not re-chase these:**
1. *"`_apply_arb()` bails when either wheel of a pair lifts, snapping the Fz split"* (the lead
   recorded but not pursued in the 2026-08-25 entry below). Measured: **contact gain/loss coincides
   with only 0.2% of large jumps.** Also note `_apply_arb`'s existing `clampf(t, -a.Fz, b.Fz)`
   already drives the transfer smoothly to zero as a wheel unloads, so the early return is
   redundant rather than harmful.
2. *"an airborne front wheel silently drops out of the `_sat_moment` sum"* — same 0.2%, same
   verdict.

**What it actually is: vertical load stepping by kN in a single tick while the tyre never leaves
the ground.** Measured over 4802 ticks of the rally loop: the raw rack torque jumps >3 N.m on
**22.9% of ticks**, and **99.9% of those coincide with an Fz step over 1 kN**. The worst single
event, with both front wheels marked `GND` throughout:

```
torque +0.00 -> -29.70 N.m in one tick
w0 GND Fz 6991 (d +6991)  util 0.94  aRel +1.78 deg  slip +2.30 deg
w1 GND Fz 7441 (d +7441)  util 0.95  aRel +1.69 deg  slip +2.23 deg
```

Slip angles are small and steady, so this is **not** a slip-angle or relaxation transient — it is
purely `Fz = max(spring + damper, 0)` riding its zero floor and slamming off it, driven by C1's
road-aware damper term.

**Fix: the reported signal now goes through the steering system's own inertia.** A column, rack and
pair of arms cannot follow an 8 ms load spike — that is a tiny angular impulse, not a jolt — and we
were reporting the raw per-tick tyre moment with no filtering whatsoever. `steer_filter_tau`
(0.04 s, Tab row "Steer response", 0 = RAW for A/B) is a first-order lag, so **steady cornering
torque passes through untouched while impulses are killed**. Same probe after:

| | jumps >3 N.m | sign FLIPPED | worst jump |
|---|---|---|---|
| raw | 22.9% of ticks | 21.8% | 29.70 N.m |
| filtered | **4.2%** | **0.0%** | **11.02 N.m** |

**The sign reversal — the exact thing the user described — goes to zero.** The survivors still
correlate 100% with real Fz steps, which is correct: a genuinely large load change SHOULD reach
your hands. **The load steps themselves are deliberately NOT suppressed** — they are real, they are
shared with the "body jumps at max slider settings" report, and they are a candidate for the AWD
controllability note above. Panel: 97 rows, 97 HELP.

- **Still open on C2:** the wash-out cue, and *"very hard to get out of an oversteer when the
  wheels are hot"* — start at M7's `overheat_grip` (0.85) compounding with B4's post-peak lateral
  shape (`cy_gravel`).

## 2026-08-25 (SECOND attempt at the slide-stop jerk - the first fix was real but not it; found a stale relaxed slip angle)

The binary-force-switch fix below did NOT resolve the report - user confirmed *"the jerking bug is
not fixed as of now."* Went back with the user for a better description: happens on **both** the
dirt circle and the rally loop/asphalt (rules out anything terrain-specific - kerbs, camber,
washboard), and feels like *"a force pushes the car in the opposite direction of the slide, like a
spring."* Default car (auto clutch, AWD).

**Found a second, real mechanism, and it matches "like a spring" almost exactly.** B4's relaxation
length (`alpha_rel`, `sigma_lat`) is deliberately RATE-limited **per distance rolled**, not per
time - documented and correct for how a real tyre carcass twists in. But at the tail of a slide the
car's speed collapses toward zero while it is *still rotating fast*, so distance-rolled nearly
stops even though the true slip angle is changing quickly - `alpha_rel` gets stuck.

Measured with a scripted slide-then-countersteer on FLAT ground (dirt circle, no terrain
involved): at the moment the car is essentially stopped (v = 0.2 m/s), the TRUE front-wheel slip
angle had already unwound to **6 deg**, but the RELAXED angle the tyre force actually uses was
still sitting at **45 deg** - a stale value from ~1.5 s earlier, well past the tyre's peak grip
angle. Because Magic Formula force depends only on angle, not on how fast the tyre is actually
moving, that stale 45 deg commanded close to full lateral grip (`util` pinned at 1.00) on a wheel
carrying almost no speed to justify it - a real spring-back force, aimed opposite the slide (that
is the geometric meaning of "relaxing" back toward zero), applied at a moment the driver already
felt the car had stopped sliding.

**Fix:** lateral (slip-angle) force now fades to zero as the wheel's own ground speed drops below
`LOW_SPEED_LAT_FLOOR` (1.2 m/s) - a physical floor, not a hack: slip angle is fundamentally a rate
quantity, and a tyre that is not rolling has no rate left to generate a cornering force from,
however stale or fresh the number sitting in `alpha_rel` is. Verified on the same scripted repro:
utilisation at the near-stop moment drops from **1.00 to 0.21** - the phantom force is mostly gone
exactly where it was diagnosed. The gate only engages in the last ~1 m/s before a stop, so it
changes nothing about how a slide FEELS while it is still happening - B4's relaxation lag during an
active slide is untouched.

**Honesty about verification, per the project's own rule (`CLAUDE.md`): this is NOT confirmed to
fix the reported feel.** The countersteer repro shows the mechanism and its mitigation cleanly, but
(unlike the VM_BAND fix below, which had a crisp single-tick before/after on the exact same
scenario) it did not produce an equally clean before/after on the whole-car velocity trace - the
scripted repro may not be hitting the same conditions as an actual drive. **Please test again and
say whether this one lands.** If it does not, the next lead worth chasing (found but NOT pursued
this session, to avoid guessing a third time without evidence): `_apply_arb()` skips load transfer
entirely the instant either wheel of a pair loses contact (`if not (a.contact and b.contact):
return`), which snaps that axle's Fz split back to the un-transferred value in one tick when a
wheel goes briefly airborne under hard weight transfer - plausible on any surface, not reproduced
cleanly here because the synthetic test that found airborne wheels also had bad spawn-orientation
artifacts on sloped terrain that make its numbers untrustworthy.

## 2026-08-25 (fixed: hard jerk coming to a stop during a slide — a binary force switch, not a snap in the model)

Drive report: *"the car jerks really hard when coming to a stop during a slide."* Real bug, in the
gross-sliding block of the friction ellipse (A5): once a tyre is saturated past the ellipse
(`e > 1`), its force is blended away from the raw two-curve Magic Formula result and toward a force
that opposes the contact patch's actual slip VELOCITY - physically correct, and it is what makes a
locked rear axle let go on its own. That blend was gated by `if vm > 0.2:` where `vm` is the slip
speed magnitude: above 0.2 m/s, full physical-direction force; at or below, an instant, complete
switch back to the raw ellipse-scaled force. **A slide ending is exactly a wheel's `vm` decaying
toward zero**, so every wheel crossed this line once, right as the car settled - the symptom's own
words, "coming to a stop during a slide," describe the crossing exactly.

Measured the size of the switch directly, headless (a standalone car over a flat floor, braked
hard through a 13 m/s mostly-sideways slide, same seed before and after): at the instant `vm`
ticked below 0.2, front-R went from **(-2432, 1557) N to (-2041, 1973) N in one 120 Hz physics
tick** - an 11 degree, ~570 N snap in the force actually applied to the chassis, and all four
wheels take their own such snap at their own moment as the slide runs out (front-L 249 N, rear-R
207 N, rear-L 16 N in this run), so the car takes several of these in quick succession right at the
end - which is what a slide-to-stop looks like from the driver's seat as one hard jerk, not four.

Fix: the binary gate is gone. `vm_gate := clampf(vm / VM_BAND, 0.0, 1.0)` (new `VM_BAND = 0.4`)
fades the SAME blend continuously to zero as the patch actually stops sliding, instead of cutting
it. Re-measured on the identical scenario: the same four crossings now move the applied force by
**9 N, 37 N, 25 N and 80 N** - a 6-26x reduction, and nothing changes for a wheel that is still
genuinely sliding (`vm` well above `VM_BAND`), where `vm_gate` is already 1 and the blend behaves
exactly as before. The division `vsx/vm, vsy/vm` that gives the slip direction still guards against
literal `vm == 0` (`if vm > 0.001`), but its result is now weighted toward zero by `vm_gate` well
before it gets there, so the guard threshold itself is no longer where the car feels anything.

Reproduced and verified with a temporary standalone probe (car + flat floor, no World/stage needed)
that read `_brake_pedal`/`Input.action_press("brake")` directly and logged Fx/Fy at the exact
before/after tick of each wheel's crossing; removed once the fix was confirmed. `stability_assist`
(default OFF) was ruled out as a contributor - it is gated on speed above `slip_ref_speed` (2 m/s)
and never touched in this scenario.

**Housekeeping, not a fix:** while diagnosing this, also read the earlier stall/restart entry -
`a7d849f`, *"A stalled engine can be restarted again, and stalls far less often"* - which had
already landed (and the user separately confirmed: *"good the change works"*) for the anti-stall/
ignition/bump-start bug reported alongside this one. Nothing further was needed there.

## 2026-08-24 (D1 — one authority for what the ground is; two surface bugs surfaced, neither fixed)

Arc D opens. `scripts/ground_map.gd` is now the single answer to "what is the ground at (x, z)?" —
`sample()` returns surface / road_class / deformable / grip / colour / audio, composed of **layers
resolved in priority order**, each a pure function of position. `stage.grip_at`, `is_tarmac_at`,
`deformable_patch_factor` and `_surface_color` are now one-line delegations; `roughness.gd`'s
`road_class_at` and `effects.gd`'s tarmac gate read the map. **Nothing about the car changed, and
that was the hard part** — the phase's success condition is that nothing moves.

**Probe 1, golden equality — THE phase.** 6608 lattice points spanning all four surfaces, both
circuit shoulders (radial sweeps at 1 m steps across each edge), the drag strip to its far end and
the centre patch past its blend. Captured from the unmodified build first, then re-run on the
shipped build: **byte-identical, SHA-256 `80bffdd150893337…`**, across grip, tarmac classification,
patch factor AND vertex colour. Surface census: 4182 grass / 1504 dirt / 922 asphalt.
The probe is kept at `scripts/probe_ground_lattice.gd` (not wired; wiring instructions in its
header) because **D5 reuses it verbatim** to prove the calibration bed rebuilds bit-identically
after an area transition.

**Probe 2, consumer agreement — two pre-existing bugs found. NEITHER IS FIXED**, because a feel
change hidden inside a refactor is exactly what this phase must not do. Both are recorded here so
the next session finds them by symptom:

1. **"The rally loop plays a tarmac squeal when you slide, and the gravel rumble is too quiet."**
   `sound.gd`'s tyre-audio split is `asph = (grip - 1.0) / 0.25`, which reads **0.400 on every
   gravel point — 1504 of 1504 dirt samples**, i.e. the audio hears the rally loop as 40% asphalt.
   That drives two things: the asphalt squeal layer plays at 40% strength while sliding on gravel
   (`squeal_level = tv * asph`), and the gravel rumble is cut 28% (`* (1.0 - 0.7 * asph)`).
   **Cause is drift, not the formula:** the `/0.25` divisor is exact when `dirt_grip = 1.0`, which
   is what `docs/ROADMAP.md` still documents — but `dirt_grip` is **1.1** in code. The moment that
   value moved, the split stopped landing on zero. Fixing it is a real audio change and wants a
   drive test, so it is left alone and `sound.gd` carries a comment saying why.
2. **The centre patch has two different shapes.** `grip_at` decides PATCH with a **euclidean**
   radius test (`r < 75`); `deformable_patch_factor` — which C1 uses to suppress the roughness
   field — uses a **chebyshev** one (square, blended 75→93). They disagree on **392 of 6608
   points**, e.g. `(-84, -84)`: grip says grass, the patch factor says 0.5 (half-suppressed
   roughness). So there is a ring of ground in the square's corners where the roughness field is
   damped for no reason the grip model knows about. Both shapes preserved exactly.

`effects.gd`'s gate was the third suspect and it is **clean**: its retired `asphalt_grip = 1.2`
threshold agreed with the surface test on **0 disagreements / 6608 points**, so switching it to the
map was a measured no-op. The export is gone; the gate is now a class, not a number.

**Probe 3, cost — and it changed a decision.** Measured 52.8 classifier calls per physics tick
(min 1, max 74) with the car settled and effects running. Per call: `ground_map.grip_at` **2.90 µs**,
`stage.grip_at` (through the delegation) **3.81 µs**, `sample()` **9.22 µs**. So the shipped scalar
path costs **0.153 ms/tick = 8.3% of the 1.84 ms baseline**, of which the refactor's own share is
only the extra call hop (~0.9 µs × 52.8 ≈ **0.048 ms/tick, ~2.6%**) — the trig was always there.
**§5 specifies `grip_at` as a delegation to `sample().grip`; it is a delegation to
`ground_map.grip_at()` instead**, because `sample()` builds a Dictionary the caller throws away and
routing everything through it would cost **0.487 ms/tick — 26.5% of the whole physics budget**.
Same classifier, same values (byte-identical), one third the cost. `sample()` remains the API for
consumers that genuinely want several fields.
**Budget note for D4:** C1.0's centreline already costs 1.05 ms/tick. Ground map + centreline is
now ~1.2 ms against a 1.84 ms baseline, so streaming arrives with less headroom than Arc D assumed.

**Godot gotcha that cost a build:** a NEW `class_name` script is not resolvable until the global
class cache is rebuilt — `GroundMap.new()` failed with *"Nonexistent function 'new' in base
'GDScript'"* even though the file parsed. This project never opens the editor, so the cache only
refreshes on `godot --headless --path . --import`. Added to `CLAUDE.md`.

---

## 2026-08-24 (fixed: the engine dies and NOTHING starts it again - no ignition, no bump start)

Drive report: *"when having manual clutch off, sometimes the car still stalls - even with anti stall
on - and the bug is that it doesn't turn on when doing bump starts or when pressing ignition (and
because there is no manual clutch there is no holding it with that option) so it makes it so that on
default start settings there is no way to reignite the engine after stalling."* Both halves are real
and they are different bugs. **Nothing in this file mentioned stalling before today** - grep
`_stalled`, `_dead_t`, `w_stall`.

**The soft-lock: `_stalled` described the SETTINGS, not the engine.** Entry required
`manual_clutch and not anti_stall`, so on the default car (auto clutch, anti-stall ON) the flag
could never be set - while the crank could still reach zero, because nothing else stopped it. And
every restart route sits behind that flag: `[I]`, the 0.5 s clutch-hold starter, and the bump-start
catch. Measured on the default car with the engine at **0.0 rpm**: `[I]` did nothing, a **40 km/h
bump start in gear** did nothing, neutral + `[I]` did nothing, coasting did nothing. The HUD's
`** STALLED - [I] ignition **` line is also behind the same flag, so the driver was not even told
what had happened. `_stalled` is now a statement about the engine - below the firing floor
`_engine_torque()` returns zero and motoring friction only drags the crank further down, so it is
dead however it got there - and `[I]` fires whenever the engine is not turning over rather than only
when the flag happens to be set.

**Why it was only "sometimes", which is the useful part to remember.** Combustion torque decays
through the intake lag (`intake_tau` 0.07 s) rather than vanishing, so a crank flicked briefly under
the floor can still pick itself up on the residual charge, and usually does. Only a *sustained* dip
is fatal. So the stall test has a **dwell of `intake_tau * 3` (0.21 s)** - long enough to keep every
self-recovery that already worked, short enough that a genuinely dead engine is admitted quickly.
Proof it matters: a hard brake to a stop in 3rd dips to **430.8 rpm, below the 500 rpm floor**, and
recovers on its own with no stall declared.

**Two routes dragged the crank under the floor even with anti-stall ON, and both were in the
locked-clutch follow.**

1. **Selecting reverse while still rolling forwards** - `omega_gb` goes negative, and the follow
   `_omega_e = clampf(omega_gb, 0.0, ...)` clamped the crank to **zero in a single tick**. The
   "follow hit a physical limit -> plates must slip" test was written *after* the assignment, so it
   noticed only once the engine was already dead. Measured **2658.4 -> 0.0 rpm**. The follow is now
   tested before it is taken.
2. **Hitting something solid while the plates are locked** - the lock slaves the crank straight to a
   stopped wheel, and the clutch travels at pedal rate (`CLUTCH_OUT_RATE` 25/s, ~40 ms), which at
   120 Hz is far too slow to save it. Measured **2517.2 -> 31.0 rpm**. Anti-stall (and any auto
   clutch, which is always clamped) now **opens the plates rather than letting them drag the crank
   below its firing speed** - which is what a real anti-stall is for.

| trial (default car) | min rpm before | min rpm after |
|---|---|---|
| wall impact while plates locked | 31.0 | **971.2** |
| reverse engaged while rolling forward | 0.0 | **929.5** |
| handbrake at walking pace in gear | 886.3 | 886.3 (was already safe) |

**Every recovery route now works, each tested from a fresh dead engine.** Default car (auto clutch,
anti-stall ON): no input at all -> re-fires; `[I]` -> re-fires; rolling in gear -> re-fires. Hardcore
(manual clutch, anti-stall OFF): clutch held -> starter fires; in gear rolling with the clutch out ->
bump start catches at **2277 rpm**; `[I]` -> re-fires. **With an auto clutch, anti-stall now re-fires
the engine about half a second after it dies instead of stranding the driver** - there is no clutch
pedal to hold, so that recovery has to be the car's job.

**No spurious stalls.** Six driving phases (idle in gear, full throttle up through the box, hard
brake to a stop in gear, standing start, handbrake turn, coasting in neutral): **0 stalled frames**,
lowest rpm seen 430.8.

**NOT verified: feel.** Whether a stall now reads as dramatic-but-recoverable, or whether the 0.5 s
auto re-fire is too eager, needs driving. The hardcore config is unchanged in intent: you can still
genuinely kill it and have to bump start.

**Housekeeping:** a parallel session's `commit -a` swept the temporary probe for this bug into commit
`9073979` ("Broadband roughness was 4.5x too quiet") and pushed it; this commit removes it. Second
time this week - see the note under 2026-08-19.

## 2026-08-20 (fixed: dust born on grass turned white the moment you reached tarmac)

Drive report: *"it should also be given color on birth and not change every surface change after
birth - so if it starts green from grass it shouldn't turn white when I hit the asphalt - only the
new ones should be white"*, plus *"on grass it changes, on the rally loop it changes also and also
on asphalt, but on the dirt circle it doesn't change."* **Two separate defects, and the second
sentence is the tell for both.** This is the DIRT/DUST PLUMES and the DIRT/GRAVEL PARTICLES - the
two surface-tinted layers. ASPHALT SMOKE has a fixed white-grey and was never involved.

**1. A particle could not keep the colour it was born with, because it never owned one.**
`ParticleProcessMaterial.color` is a uniform that the particle process shader re-reads **every
frame**, so writing it re-tints every particle already in the air. Measured, because it is not at
all obvious and three plausible escapes all fail: with `color_ramp` (delta 0.54), with `alpha_curve`
instead (0.58), with **no** over-life ramp at all (0.60), and even with a per-particle
`emission_color_texture` whose colours were swapped while emission was OFF (live particles went
green -> red anyway). **There is no way to bake a colour into one particle of a shared emitter** -
the colour belongs to the emitter, not the particle.

So a tinted layer now gets **several emitters per wheel, each holding ONE frozen colour**. A new
ground colour hands over to a different emitter; the retired one just stops emitting and its
particles live out their lifetime in the colour they were born with. `_pick_slot()` prefers an
emitter *already* holding that colour, so grass -> dirt -> grass reuses the green one and never cuts
a cloud short. The count is derived, not picked: a retired emitter must not be wanted again until
its last particle has died, so `gens = ceil(life / tint_hold)`, clamped 2..4 - plume (life 4.6 s)
gets 3, gravel (0.55 s) gets 2, smoke (untinted) stays at 1.

Proof, both clouds on screen at once: a cloud laid down as green, then the ground colour switched to
white and emission moved a few metres sideways - **old cloud (0.34, 0.76, 0.26) still green, new
cloud (0.80, 0.68, 0.55) white**, with `gen0 emitting=false colour=(0.12,0.80,0.16)` and
`gen1 emitting=true colour=(0.95,0.95,0.97)`.

Also removed the sharpest edge of the same bug: winding a plume down over tarmac passed
`Color.WHITE` as its colour, which - being a live uniform - flashed the **whole fading cloud** white
in one frame. Both branches now sample the real ground colour; dust is the colour of the ground it
was lifted off, wherever the car happens to be.

**2. `_surface_color()` did not know the dirt circle existed.** It blends grass -> road -> asphalt
-> drag strip and had **no term for the centre deformable patch**, even though `grip_at()` has
always had one. So across the whole skid-pad it returned plain `grass_color`, and dust kicked up on
the dirt circle was tinted **green** - and, because the value was constant over the entire patch, it
was also the one place the colour never changed in flight, which is exactly what the report says.
Now blended through `deformable_patch_factor()` (the same query C1 uses, so the patch's extent stays
defined in one place). Measured `ground_color()`, before -> after:

| | before | after |
|---|---|---|
| dirt circle centre | (0.496, 0.496, 0.334) — *identical to grass* | **(0.694, 0.532, 0.334)** |
| rally loop | (0.640, 0.577, 0.460) | unchanged |
| grass | (0.496, 0.496, 0.334) | unchanged |
| asphalt ring | (0.298, 0.298, 0.325) | unchanged |

`terrain.gd` still owns that colour; `world.gd` pushes `patch.dirt_color` into `stage.patch_color`
at wiring time so the two cannot drift apart. **Do not re-tune it in `stage.gd`.**

**Cost — the extra emitters are close to free, which is the surprise worth recording.** Worst case
(all four wheels emitting plume AND gravel, ground colour flipped every 1.5 s to force a handover
every time): emitters **12 -> 24**, particle slots **1920 -> 4120**, but draw calls **1452 -> 1463
(+11)** and primitives **3,050,156 -> 3,054,481 (+4.3k)**, with process ms **18.20 -> 18.09**
(inside the run-to-run spread) and FPS pinned at 60 both. A retired emitter that is not emitting and
has no live particles costs essentially nothing, so the cost tracks *colours actually in flight*,
not the number of emitters allocated. Do not "optimise" this back to one emitter per wheel; that is
the bug.

**NOT verified: how it looks while driving.** Tunables are `tint_bin` (0.10 - the RGB distance at
which a colour earns its own emitter) and `tint_hold` (1.6 s).

## 2026-08-19 (C1 revision: washboard enveloping back to the contact patch — "still can't feel it above 20 km/h"; C1 ACCEPTED)

Recorded late — this shipped as `d43713b` and was never written up.

**Symptom:** after the 2026-08-15 revision below, washboard *still* could not be seen or felt above
~20 km/h on the rally loop. **Cause: the swept-footprint filter from that revision was the wrong
call.** Physical tyre enveloping depends on the CONTACT PATCH and is speed-independent — a real
tyre on a 0.6 m ripple follows it at any speed, because 0.6 m is three times its contact length.
Folding the per-tick swept distance into the footprint low-passed the road *by speed* and cost
**74% of the ridge amplitude at 100 km/h** (transmission 82/66/49/26/9% at 0/30/60/100/150 km/h):
a numerical anti-aliasing fix applied as though it were physics, which deleted the feature exactly
where it matters most.

Sampling once per tick is a real limit, but **only past Nyquist**. One wavelength needs two
samples, so filtering now begins only when a tick travels more than half a wavelength — about
**130 km/h at 120 Hz on 0.6 m corrugation**, well above rally-loop corner speeds, where a 0.6 m
ripple still gets **4.3 samples per wavelength at 60 km/h**. Below that threshold the profile is
untouched: **transmission at 60 km/h goes 49% → 83%.**

**USER DRIVE VERDICT 2026-08-24: C1 ACCEPTED.** Arc C's roughness work is drive-verified and Arc D
is unblocked. Note for anyone re-opening this: the accepted build is the contact-patch footprint
plus `damper_reads_road`, not the swept-strip version described in the 2026-08-15 entry below.

---

## 2026-08-19 (fixed: whole dirt tiles go DARK BROWN when they load — a backwards mesh winding)

Drive report: *"the dirt tiles/squares still have the rendering issue where unloaded tiles are much
lighter than loaded ones... whole tiles change color when rendered, from dark brown to light
brown... not talking about the color of berm or ruts, just the color of the dirt in general."*
The user's own hunch — *"maybe this issue is similar to godot's texture flipping we had in the
beginning"* — was exactly right, and is the fastest route to this class of bug.

**`_build_plane()` wound the shared tile mesh back-to-front, so the top of every live tile was its
BACK face.** The shader runs `render_mode cull_disabled`, so nothing went invisible — instead Godot
negates `NORMAL` on back faces, which turned the vertex shader's carefully-built up-normal into a
*down*-normal. `N·L` against a sun at −72° then contributes **nothing**, so every loaded tile was
lit by **ambient sky only**: dark brown, hard-edged, sitting inside a field of correctly-wound
(PlaneMesh) flat squares in full sun. **`cull_disabled` is what hid this for so long** — with
normal culling it would have shown up as the obvious "half invisible / upside-down" symptom the M5
stage mesh had, and been fixed the same day.

Measured from a top-down capture over **undug** ground (`dug: 0`), 2×2 live tiles surrounded by
flat squares:

| | live tile | flat square |
|---|---|---|
| before | (0.184, 0.153, 0.122) | (0.753, 0.565, 0.365) |
| after | **(0.753, 0.565, 0.365)** | (0.753, 0.565, 0.365) |

Byte-identical after the flip. Note the before-ratio is **4.1 / 3.7 / 3.0 per channel, not a flat
scale** — the dark side is relatively *bluer*, which is the signature of ambient-sky-only lighting
and is what pointed at `N·L` rather than at albedo.

**How it was attributed, in three controls** (worth copying for the next "why is this surface the
wrong colour"): forcing `ALBEDO = dirt` unconditionally **did not change either side** → not the
colour mix; disabling the sun's shadows *and* the tiles' `cast_shadow` changed **nothing** → not
shadowing; `ALBEDO = FRONT_FACING ? green : red` rendered **live tiles RED and flat squares GREEN**
→ winding, conclusively.

**Watch for the recurrence:** any new mesh built by hand for this shader must put its top face
front. `cull_disabled` means a regression will not look like a hole — it will look like *this*, a
whole surface dropping to roughly a third of its brightness and going blue-ish.

## 2026-08-19 (also fixed, but NOT the reported symptom: the ruts you dug vanish when you drive away)

**Read the entry above first — that was the bug the user was actually reporting.** This one is real
and was fixed on the way to it (user confirmed: *"now they do stay in view"*), but it is a separate
defect and diagnosing the report as this one cost a pass. The lesson for next time: *"tiles are
lighter"* meant whole tiles, uniformly — a **lighting** claim. Ruts and berms were explicitly not
what was being described. **Photograph the thing before theorising about the shader maths**; one
top-down capture over undug ground would have separated these two in the first five minutes.

Symptom in driving words: **the ruts and berms you just dug vanish the moment you drive away from
them**, and re-appear when you come back within 36 m. **Rendering only. `t.heights`, the
HeightMapShape collider and the whole Bekker dig model were correct throughout and were not
touched.**

**The centre patch draws its ground two ways and swaps between them by distance.** Within
`unload_radius` (36 m) a tile is live: its own tessellated mesh, its own material, its own
`_tn x _tn` height texture that the wheels rewrite as they dig. Beyond it, the tile is freed and a
flat square takes over. Every one of those 169 squares shared **ONE material pointing at ONE 2x2
texture filled at `bed_height`** — so `vh == bed`, `depth == 0`, and every unloaded square rendered
as **pure `dirt_color`, the lightest value the shader can produce**. Measured on a 10.5 cm rut:
loaded albedo luma **0.245**, unloaded luma **0.502** — a **2.05x brightness step** at the boundary.
Driving away from a rut visually erased it; driving back re-materialised it at 36 m.

**A wrong conclusion recorded on purpose, because the reasoning looked airtight.** This entry
originally claimed undriven ground had no seam, on the grounds that both paths encode pristine
ground as the identical quantised constant (0.1482 m through RGBA8) and both *compute* the same up
normal. Both halves are true and the conclusion was still wrong: the live tile's computed normal
was being **negated by the back-face rule** after the shader had produced it (see the entry above).
**Reading the shader tells you what it computes, not what the rasteriser does with it.**

**The half that is easy to miss: the flat square has 4 vertices.** The shader read the height in
`vertex()` and passed it to `fragment()` as a varying, so colour resolution was the MESH's
resolution. Handing each square its own height texture — the obvious fix — would still have shown
nothing, because 4 corners cannot carry a rut. So the height is now read **per pixel in
`fragment()`**: rut colour is set by the texture, not by how finely the mesh is divided, and the
two paths land on byte-identical colour (rut 0.245/0.245, berm 0.777/0.777 luma).

**What was built.** A released tile no longer throws its visual state away: it hands its heights
*and its height texture* to a `Rut` record, and its square switches to its own material bound to
that texture plus a 32-cell mesh (`flat_vis_cells`, snapped to an exact divisor of `tile_cells` so
the visual's nodes land on tile nodes and the meshes still meet at borders). **Ground that was
never dug keeps the one shared pristine material and its 2-triangle quad**, so undriven field costs
nothing. Reloading a tile now reuses the persisted `Image`/`ImageTexture` instead of re-running a
4,225-pixel `set_pixel` loop. Two smaller bugs fell out on the way: `_mirror()` never marked the
neighbour `dug`, so a tile whose only deformation was a mirrored border row lost it on unload; and
the height sampler was `repeat`-wrapping, so a tile's left edge blended with its own right edge
12 m away — a phantom half-strength rut line at borders. Sampler is now `repeat_disable`.

**Cost, measured on `[J]`** — parked on the dirt circle, whole corridor rutted (34 dug tiles),
whole field on screen, car frozen so the live-tile set is identical (5 tiles) run to run:

| | before | after |
|---|---|---|
| draw calls | 1436 | **1540** (+104) |
| primitives | 3,045,200 | **3,262,084** (+7.1%) |
| process ms | 34.28 (32.9-35.2 over 5 runs) | 34.95 (34.6-35.2) |
| FPS | 37.1 | **35.5** (mean of 3 back-to-back runs each) |
| triangles on the unloaded field | 338 | 69,902 |

**The geometry is not what costs — grep this before "optimising" it by lowering
`flat_vis_cells`.** Forcing the dug squares back to 2 triangles (542 total instead of 69,902)
measured the *same* frame rate. The whole +104 is **draw calls**: ~3 per dug square, i.e. the main
pass plus two shadow splits. The lever that actually works is `cast_shadow` — switching it off on
the flat squares put draw calls at **1432, below the baseline**. It was left ON deliberately: a
rut that self-shadows while loaded and stops when it unloads is the same class of boundary
divergence this entry exists to remove, and 4% of draw calls is not worth reintroducing it. If the
frame-rate hunt needs it back, that is where it is.

**Also worth grepping: an alarming "60 -> 52 FPS" reading here was a measurement artifact.** The
baseline had been captured with a different probe configuration (car not frozen, so it settled onto
a different set of live tiles and pointed the camera somewhere cheaper). Re-baselined with the car
frozen, before and after sit inside each other's run-to-run spread. Pin the car before trusting any
A/B on this patch.

**NOT verified: appearance.** Godot's `--headless` runs a dummy renderer — `ImageTexture.update()`
does not even round-trip through `get_image()` there — so every number above is texture content and
counters, not pixels. Needs a drive on the dirt circle.

**Housekeeping:** this `terrain.gd` change was swept into commit `09d0a7b` ("Measure the grip
channel") by a parallel session's `commit -a` while it was still in progress, and pushed there. The
code in that commit is the finished, verified fix; only its attribution is wrong.

## 2026-08-15 (measured: washboard DOES cost grip — the tyre is airborne 30-43% of the time)

Drive report: *"the C1 roughness is felt at the wheels, but the suspension eats it completely
above 20 km/h."* **The body not responding is correct and is not a bug.** Above resonance a
base-excited spring-mass transmits about `2*zeta/r`; with the body at 1.4 Hz, zeta 0.55 and 0.6 m
corrugation that is **17% at 20 km/h, 8% at 40, 5.5% at 60, 3.3% at 100** — the reported ~20 km/h
threshold is almost exactly where the maths puts it. A real rally car's chassis does not heave at
46 Hz either. Chasing this with more travel, stiffer springs or deeper ridges is the wrong tree.

**So the question became whether the OTHER channel — load fluctuation costing grip — is actually
working.** Measured with a quasi-static quarter car (body held fixed, ground oscillating beneath
it; accurate above ~40 km/h precisely because transmissibility there is only 3-8%) through the real
spring / damper / bump-stop / load-sensitivity code, one front corner, static Fz 3.07 kN:

| speed | Fz mean | Fz min | Fz max | frames unloaded | grip vs smooth |
|---|---|---|---|---|---|
| 20 km/h | 2.83 kN | 0.73 | 4.75 | 0.0% | **90.3%** |
| 40 km/h | 2.82 kN | 0.00 | 6.15 | **30.8%** | **84.3%** |
| 60 km/h | 3.14 kN | 0.00 | 7.47 | **37.5%** | **88.3%** |
| 100 km/h | 3.38 kN | 0.00 | 7.65 | **42.8%** | **91.2%** |

**The tyre is completely off the ground 30-43% of the time at speed, and available lateral force
drops 9-16%.** That is a large handling effect and it is already in the car — washboard should
make it skate, wash wide on entry and refuse to hold a line, even though the body stays calm.
Note the loss is WORST at 40 km/h, not at the top end: past that, mean Fz climbs above static
(3.07 -> 3.38 kN) and partly compensates.

**Second finding, worth watching: that rising mean is rectification.** `Fz = max(spring + damper, 0)`
lets the suspension push but never pull, so an oscillating damper force clips on the down-stroke and
spikes on the up-stroke, netting upward impulse. At 100 km/h it is +0.31 kN per corner — about
**10% of the car's weight pushing it up** over sustained corrugation. Real (washboard does make cars
float and go light), but it is the same mechanism behind the "body jumps and shakes" report at
exaggerated slider settings, so it should be re-checked if bottoming or float behaviour drifts.

**Conclusion: nothing to build yet.** The perceptual channels we lack (unsprung mass / wheel hop,
seat and steering-column shake, camera shake) are all real gaps, but the grip channel is live and
strong, and the enveloping-footprint fix that restored ridge amplitude at speed landed *after* the
drive that produced this report. Re-drive at defaults before adding anything.

## 2026-08-15 (C1 REVISION — the damper can finally see the road; roughness goes from 3% to dominant)

Fixes the *"couldn't differentiate when the roughness gain was on and when it was off, washboard
was only noticeable when driving slow"* verdict below. Both halves are physical; neither is an
amplitude tweak, because amplitude was never what was wrong.

**1. The damper now feels the ROAD's vertical velocity, not just the body's.** `comp_vel` was
`-pv.dot(up)` — purely body-side — so a wheel crossing corrugations registered no damper velocity
at all while the body sat still. A damper responds to RELATIVE velocity across itself, and with no
unsprung mass the wheel follows the ground exactly, so the ground's own vertical speed
(local slope x ground speed) belongs in that term. Slope comes free from a least-squares fit
through the samples the enveloping filter already takes — no extra field evaluations.
**Measured on real washboard (2 cm deep, 0.6 m wavelength, front spring 24 000 N/m):**

| speed | transmitted | spring force | road m/s | DAMPER force | damper:spring |
|---|---|---|---|---|---|
| 30 km/h | 66% | 319 N | 1.38 | **2 008 N** | 6.3x |
| 60 km/h | 49% | 236 N | 2.36 | **3 351 N** | 14.2x |
| 100 km/h | 26% | 123 N | 3.00 | **4 216 N** | 34.2x |
| 150 km/h | 9% | 45 N | 2.73 | **3 844 N** | 85.3x |

The spring column IS the old behaviour: **123 N against a ~4 kN static corner load at 100 km/h,
i.e. 3%** — which is precisely why it could not be felt. The damper term is comparable to the
entire static corner load, so the wheel genuinely unloads and reloads across corrugations.
**And the effect now GROWS with speed instead of shrinking, which inverts the reported symptom** —
correct, because corrugations get more violent the faster you cross them. Road velocity saturates
at its 3.0 m/s clamp around 100 km/h and then eases as the tyre starts skimming the tops.

**2. The enveloping footprint now spans the strip the tyre SWEEPS during a tick, not a fixed
0.2 m patch.** This is both the honest footprint and the correct anti-aliasing filter. The field is
sampled once per tick, so the sampling interval is a DISTANCE that grows with speed: a 0.6 m
washboard gets 8.64 samples/wavelength at 30 km/h, **2.59 at 100, and 1.73 at 150 — past the
Nyquist limit of 2**, where a fixed footprint aliases the ripple into low-frequency garbage.
With the swept footprint, transmission instead rolls off smoothly as a sinc (82 / 66 / 49 / 26 / 9%
across the table above) — the ripple simply gets quieter with speed, the way a real tyre averages
over its contact length, and the way a 120 Hz tick can actually represent.

**Stability checked, because a large new damper force at 120 Hz is exactly how a sim explodes:**
900 frames under full power, all `Fz` finite, **max 23.4 kN** — in line with B3's recorded 23.1 kN
baseline, no divergence. Road velocity is exactly 0 at a standstill by construction (slope x zero
speed), so there is no parked buzz. New Tab row `damper_reads_road` (ON) is the A/B that isolates
this term; 96 rows / 96 HELP.
**Expect this to be STRONG.** If washboard now feels violent rather than informative, the fix is
`washboard_amp` down from 2 cm (it is a slider now), NOT `damper_reads_road` off — that toggle
exists to prove what the term bought, not as a tuning knob.

## 2026-08-15 (C1 drive verdict: "couldn't tell gain on from off"; two root causes found, then C2 built)

**DRIVE VERDICT ON C1 — the phase's central A/B FAILED.** User: *"i couldnt differentiate when the
roughness gain was on and when it was off, washboard was only noticeable when driving slow
otherwise the suspension smooths it completely"*. Also, separately: *"bottoming when going uphill
is fixed as far as i saw"* (that part PASSES — the grass leak fix earlier the same day). C1 stays
UNTICKED for feel. Three findings explain the silence, and **two of them are arithmetic, one is a
genuine model gap** — worth grepping before anyone "turns the amplitudes up" again, because
amplitude is not what is wrong.

**1. The washboard is below the spatial Nyquist limit at speed — this exactly matches "only
noticeable when driving slow."** The field is sampled once per wheel per physics tick, so the
sampling interval is a DISTANCE that grows with speed. At 120 Hz: 30 km/h = 0.069 m/tick =
**8.6 samples per 0.6 m wavelength** (clean). 100 km/h = 0.232 m/tick = **2.59 samples/wavelength**
(barely above the Nyquist limit of 2, so heavily distorted). 150 km/h = 0.347 m/tick =
**1.73 samples/wavelength — BELOW Nyquist**, so the ripple aliases into a low-frequency wobble or
vanishes. Raising `washboard_amp` cannot fix this; it amplifies an alias.

**2. Even sampled perfectly, the BODY should barely move — that part is correct physics, not a
bug.** A 0.6 m ripple at 100 km/h is a 46 Hz input against a 1.4 Hz suspension. Transmissibility
at that frequency ratio (r = 33) is roughly 2*zeta/r = **~3%**, so 2 cm of road becomes ~0.7 mm of
body motion. A real car transmits washboard to the driver through the STEERING, through tyre-load
(and therefore grip) fluctuation, and through structure-borne vibration — not through body heave.
This car has no unsprung mass, so it has no wheel-hop mode either. The conclusion: injecting at
the suspension was necessary but was never going to be sufficient on its own.

**C2 — self-aligning torque, built the same day, and it is the channel finding 2 says is missing.**
What a driver feels through the wheel is not body motion, it is the torque the front tyres exert
about their steering axis: `Mz = Fy * (t_pneumatic + t_mechanical)`, summed over the front wheels
and divided by `steer_ratio`. Taken from the FINAL `Fy` — after the friction ellipse and after A5's
gross-sliding correction — so a tyre trimmed by combined slip reports the weaker signal it
physically would. Read it on the HUD as `steer Nm`.
**The point is the COLLAPSE, and the first implementation got its shape wrong.** Pneumatic trail
shrinks as the contact patch starts sliding, so the wheel goes LIGHT just before the front washes
out — that lightening arrives BEFORE the grip does, which makes it more informative than raw force.
A straight-line collapse (`t_p0 * (1 - |alpha|/alpha_peak)`, what the plan suggested first) measured
with the torque **peaking at 1.1 deg against a 9 deg grip peak — only 12% of the way to the
limit**, because `Fy` saturates extremely early (98% of peak by 2.2 deg). The wheel would lighten
across the entire range and the lightening would carry no information about where the limit is.
Switched to the **cosine (Pacejka Mz) form**, which the plan explicitly permitted and which is what
the physics says: trail holds near its static value while the patch still ADHERES, then falls away
as the rear begins to slide. Measured after: peak moves to 1.6 deg (tarmac) / 2.8 deg (gravel), and
crucially the weight is HELD longer early then dropped harder late — 4.5 deg to 9 deg now sheds
**51%** of the torque versus 43% before, so the cue concentrates where it matters.
Probe (removed): Mz peaks before Fy on both surfaces PASS; falls to **42%** of its own peak by
2x peak slip PASS; reverses sign with steering direction and is exactly 0.000 N·m on centre PASS.
**Honest note:** the torque peak is still early in absolute terms, and that is a property of B4's
drive-verified lateral curve saturating at ~2 deg, NOT of the trail model — B4 is drive-verified and
was deliberately not touched here. New Tab rows: `trail_pneumatic`, `trail_mechanical`,
`steer_ratio`, `sat_gain` (95 rows / 95 HELP, no gaps). No rumble wired: `start_joy_vibration()`
is rumble, not force feedback, and must never be described as FFB.

**3. REAL MODEL GAP — the damper is blind to the road.** `comp_vel` is computed purely from the
BODY's velocity at the contact point (`linear_velocity + angular_velocity.cross(contact_off)`) and
never includes the rate of change of ground height under the wheel. A real damper reacts to
RELATIVE velocity, so a wheel crossing corrugations should see large damper velocities even with
the body dead still. Ours sees none. **Pre-C1 this was harmless — the ground was smooth, so
d(ground)/dt was ~0 — and C1 is what makes it matter.** Consequence: roughness currently produces
only a SPRING force change: 2 cm x 24 181 N/m = **484 N on a ~4 kN static corner, a 12% wobble**.
Had the damper seen the road, the same input at 46 Hz reaches its 3.0 m/s clamp and the digressive
curve returns **~4.98 kN** — an order of magnitude more, and the thing that would actually make the
car skip and dance. NOT fixed here: it is a real physics change with real harshness risk and wants
its own probe (energy per impact) plus its own drive test, exactly like B3's hydraulic bump stop.

## 2026-08-15 (real bug: washboard was firing on open grass, "out of control" - root cause of a loose-surface FPS drop)

**User verdict from a parallel session: the frame-rate drops on loose surfaces traced to C1
roughness "being out of control on grass."** Confirmed and fixed - `wear.is_tracked(x,z)`, added
in C1.1 as the washboard placement mask, only checked the ANGULAR SECTOR (theta from the map
centre), never the lateral distance from the actual road. So any point at ANY radius that shared
an angle with one of the rally loop's tracked corner/braking zones read as "tracked" - including
open grass hundreds of metres out, far past the drivable corridor. Full-amplitude washboard
(`sin(2*PI*s/lambda)`, default depth up to 6 cm now that it's Tab-tunable) was landing on wide-open
grass wherever the driver's angle-from-centre happened to line up with a corner zone, which is
most of the map's angular span once you account for `brake_dist` (32 m of arc before every
corner). At speed and off-road, the raycast's spatial sampling rate can alias the washboard's
0.3-1.0 m wavelength into effectively frame-to-frame noise, which explains both the "out of
control" feel and the FPS cost (erratic Fz/compression every tick from a term that should never
have been active there at all).

**Fix: `is_tracked` now delegates to `_cell(x,z) >= 0`** instead of re-deriving half its logic -
`_cell()` already checks BOTH the tracked flag AND the lateral corridor bound (`lat_extent` around
the centreline) correctly, and is the same test the worn-line placement itself uses. Verified
headless: a point at a tracked angle but 250 m further out than the road now reads `is_tracked =
false` and `washboard = 0.0` (previously would have returned the full sine amplitude). Washboard
is now provably confined to the actual tracked corridor on the actual road - it cannot leak onto
grass regardless of angle or distance.

**First drive report: "feels pretty smooth, only the asphalt kerb edges feel like anything."**
Clarified first — the kerb is real geometry that predates C1 entirely, unrelated to this phase;
washboard only lives on the rally loop's corner/braking zones (`wear.gd`'s mask), and tarmac gets
joints/patches, not washboard. The most likely explanation is that the C1.1 defaults (2 cm
washboard, 6 mm joints, 12 mm patches) are genuine physically-grounded starting points but too
small to clear the perception threshold against 20+ kN of cornering/braking load already in play -
exactly the "let the drive test move it" case the plan called out in advance.

**So the individual amplitudes are now live-tunable, not just `roughness_gain`.** They were
exports on the `Roughness` node, which the Tab panel can't reach (it only ever reads/writes
`vehicle` properties). Mirrored five of them onto `vehicle_m2.gd` instead — `road_class_gravel`,
`road_class_tarmac`, `washboard_amp`, `joint_amp`, `patch_amp` — synced into `roughness_field` once
per physics tick before the raycast pass, so the car stays the single source of truth the panel
already knows how to edit. This lets the amplitudes be dialled up hard (e.g. washboard to 5 cm) as
a quick pass/fail: if a strongly exaggerated value is still not felt, that points to an actual bug
rather than a tuning gap. Panel: 91 rows, 91 HELP entries, no gaps.

## 2026-08-15 (the A/B toggles were unreachable on macOS; real perf readout added)

**The [F9]/[F10] toggles added earlier never worked, and the reason is worth remembering:
macOS reserves F9 and F10 for Mission Control and volume, so the application never receives them.**
The handlers were fine — nothing in the project calls `set_input_as_handled`, and Tab reaches
`_unhandled_input` normally — the KEYS were unreachable. Any future in-game debug key must avoid
F-keys on this machine.

Replaced with polled letter keys, which cannot be swallowed by input handling either:
- **[G]** all surface effects off/on (dirt/dust plumes, dirt/gravel particles, asphalt smoke)
- **[H]** worn-line overlay off/on
- **[J]** on-screen performance readout

**The readout is the point.** It shows FPS, frame time, **process ms**, **physics ms**, **draw
calls**, **primitives**, and the live emitting-particle count. Those separate the candidates that
a description cannot: if the frame rate falls while draw calls and primitives stay flat, it is not
the particles — it is CPU. If physics ms is what climbs, it is the physics tick, not rendering.

**A suspect worth naming, since the report attributed the drop to the particle-rate increase:
C1 landed at almost the same time**, and it adds a per-wheel roughness sample at 120 Hz whose own
measured cost is **1.05 ms/tick against a 1.84 ms/tick baseline** — a ~57% increase in physics tick
cost, and it is active on exactly the loose surfaces where the drop is reported. That is not an
accusation, it is the other thing that changed; the [J] readout distinguishes them in one drive by
showing whether *physics ms* or *draw calls* is what moves. `roughness_gain = 0` in the Tab panel
disables C1's sampling for the same A/B.

**Also: plumes and asphalt smoke now expand FASTER at speed, not just larger.** Final size already
scaled with speed; this scales the rate. A puff reaches full size 2.07 s after birth at 20 km/h,
1.23 s at 100, and **0.66 s at 160** — three times sooner, which is what a plume torn off at speed
actually does. Implemented as a handful of pre-baked growth curves selected by speed bucket, since
the curve is a texture and rebuilding it per frame would be wasteful; swapping is a pointer
assignment.

## 2026-08-15 (C1 — the ground finally has texture: washboard, ISO gravel/tarmac noise, tyre enveloping)

**"The rally loop was a smooth floor with a friction number" — that's the bug this closes.**
Outside the centre deformable patch the collision grid is 2.25 m/cell, so no amount of suspension
tuning (Arc B) could ever put real bump feel under the tyres; C1 adds a procedural roughness FIELD
sampled per wheel and injected into the suspension raycast's ground distance, not baked geometry -
repeatable (same bump every lap, so the stage stays learnable), and free of collider resolution.

**C1.0 first: a real arc-length `Centreline` (`scripts/centreline.gd`), not a theta hack.** C1
models washboard as `sin(2*PI*s/lambda)` with `s` = distance along the road; the only `s` that
existed before this was theta-derived, and Arc D was always going to replace that with true spline
arc length. Building the real thing first (moved forward from Arc D's D2 on 2026-08-13, see
`docs/PLAN-stages-ground-map.md` §6.2) means the existing map's washboard ridges cannot silently
shift out from under a drive-verified feel later. It reproduces the direct polar formula to
**0.0000 mm** on both circuits and costs 1.05 ms/tick for 4 wheels x 120 Hz of `nearest_point`
against the 1.84 ms/tick baseline - real but budgeted, thanks to a spatial grid instead of brute
force.

**The field itself: ISO 8608 broadband noise + washboard on gravel, joints/patches on tarmac.**
One physically meaningful coefficient per surface (`road_class_gravel` 128, `road_class_tarmac` 4,
roughly ISO class D vs A/B) sets an octave-spaced noise spectrum instead of a pile of bump knobs.
Washboard corrugation reuses **`wear.gd`'s own corner/braking-zone mask** (new `wear.is_tracked`)
so the line that gets worn is the line that gets ribbed - no second mask invented.

**Enveloping filter, measured, not assumed: a tyre bridges anything shorter than its own contact
patch.** Sampling 9 points across `contact_patch_len` (0.2 m) and combining with a peak-biased
weighted mean, a synthetic 3 cm x 4 cm bump ridden dead-centre comes through at only **31% of its
raw depth**, while a 0.6 m washboard crest comes through at **83%** - texture survives, buzz gets
filtered, confirmed by feeding both synthetic profiles through the actual filter function.

**Injection is one line in `vehicle_m2.gd`: shift the raycast's `hit_pos`, not add a force.**
Everything downstream (spring, damper, B3's bump stop, `Fz`, load-sensitive grip, weight transfer,
tyre heat/wear) inherits it for free and correctly, and `w.contact_point` moves with it so dust,
tyre marks, terrain dig and audio all read the same offset ground. New Tab row `roughness_gain`
(default 1.0) is the phase's whole A/B - 0 skips the sample and is bit-for-bit the pre-C1 car.
Excluded over the centre deformable patch via a blend query (`stage.deformable_patch_factor`), not
a hardcoded radius, so `terrain.gd`'s real geometry there is never double-counted.

**Headless probes, all six PASS** (spectrum, enveloping, repeatability, centreline identity,
`nearest_point` cost, travel budget) - full numbers in `docs/PLAN-drivetrain-suspension.md` §9.
**One honest caveat on the travel-budget probe:** its synthetic autopilot only sustains ~45 km/h
average on the rally loop (a curvature-governed pure-pursuit driver, not a racing line), well
under the 100 km/h B2/B3 measured at - so while `roughness_gain=0` reproduces B3's baseline within
1% (22.8 vs 23.1 kN peak, 4/4 pegged either way, confirming the injection is truly inert at zero),
the gain=1 comparison (22.6 kN, slightly FEWER bottomed frames, not more) is suggestive rather than
load-bearing. **This is a feel phase - the real verdict is the user's drive**, per the checklist in
the plan: is washboard felt as a handling event under braking into a dirt corner, does the rally
loop read as a surface at speed, does tarmac stay smooth-but-alive rather than dead glass, is there
no buzz at parking speed or 250 km/h, and is bottoming no worse than B3's baseline.

## 2026-08-15 (frame-rate drops on loose surfaces — two real costs found, plus an A/B instrument)

Symptom reported: *"massive fps drops when going over dirt/grass/gravel"*, and crucially *"even
after dust plumes seem to disappear"*. That last clause is the useful one — it rules out anything
whose cost ends with the visible particles, and points at work that continues.

**1. The worn-line overlay was re-pushing every cell, every physics frame.** `wear.gd
_update_visual()` walked all ~5900 tracked cells at 120 Hz, calling `set_instance_color` on each
worn one. Worse, it DEGRADED as you drove: the "skip unworn cells" early-out stopped firing as the
line developed. Measured: **0.24 ms/frame with a fresh line, rising to 0.57 ms once fully worn** —
28 to 68 ms of CPU per second — against **0.0002 ms/frame** for the four cells the wheels actually
touch. Now only changed cells are pushed (a dirty set filled in `_accum`), which is the same
picture for ~1/2800th of the work. This is dirt-only and independent of particles, so it matches
the "persists after the dust is gone" part of the symptom exactly.

**2. Faded particles still cost full fill rate.** A particle at alpha 0.02 is rasterised exactly
like an opaque one — the GPU shades every pixel of a 4.4 m sprite to blend nothing. With a 4.6 s
plume life and a long fade, the plume kept costing full price for **seconds after it looked gone**.
The growth curve now peaks mid-life and collapses to half diameter over the fade, so the invisible
tail costs a quarter of the area it did. Measured: **peak diameter unchanged at 4.42 m**, whole-life
area-seconds 941 → 820 (87%), and in the faded half specifically **653 → 434 (66%)**.
Also dropped `draw_order` from VIEW_DEPTH back to INDEX: a per-frame depth sort of ~1900 particles
buys nothing here, because the puffs are near-identical in colour so mis-ordered blending is
invisible.

**3. An A/B instrument, because the rest cannot be attributed from a description.**
- **[F9]** kills every surface effect outright (dirt/dust plumes, dirt/gravel particles, asphalt
  smoke) and prints the particle-slot count.
- **[F10]** hides the worn-line overlay.
Neither touches the input map, so nothing can clash. Drive the rally loop watching the frame
counter and toggle one at a time: if F9 restores the frame rate the cost is particle fill; if F10
does, it is the overlay; if neither does, it is neither and the next suspects are the deformable
centre patch (`terrain.gd`) and the per-wheel `ground_color()` sampling.

**Not yet attributed beyond these two.** GPU particles do not simulate under `--headless`, so
fill-rate cost cannot be measured here — only reasoned about and reduced. The toggles turn the
remaining question into one drive.

## 2026-08-14 (particle density and cost — measured, not guessed)

**These particles are FILL-RATE bound, not count bound. That is the whole story, and it should be
grepped before anyone "adds more particles" again.** Every transparent sprite is drawn back-to-front
whether or not something later covers it, so cost scales with AREA on screen, not with how many
there are. Measured at the 160 km/h ceiling: one dirt/dust plume particle is 4.42 m across = 15.3 m2
of sprite, and 600 of them is ~9 200 m2 — roughly **23x full-screen overdraw** if they overlapped in
view. Doubling the count doubles that while barely looking denser, because the cloud is already
opaque where it overlaps.

**So density was bought from alpha and from the sprite, not mainly from count.**
- Alpha ceilings up: plume 0.44 → 0.52, asphalt smoke 0.30 → 0.36. Free — same pixels, more opacity.
- The puff sprite now has a **denser core and a shorter fringe** (alpha x1.35, clamped). A wide band
  of near-transparent pixels costs exactly as much fill as opaque ones and shows almost nothing;
  after the change one frame still carries 564 of 4096 pixels in the near-invisible 0.02–0.25 band,
  which is where any further fill savings would come from.
- Counts raised moderately, paid for by the savings below: plume 150 → 240/wheel, smoke 100 → 170,
  gravel 40 → 70. Total 1160 → 1920 particles across 12 emitters.

**Optimisations applied, all verified present in the API before use:**
- **`fixed_fps = 30` + `interpolate = true`** — particles simulate at 30 Hz instead of every rendered
  frame and are interpolated between steps. Dust has no fast transients to miss, so this is most of
  the simulation cost back, and it is what pays for the extra count.
- **Mipmaps on the atlas** — distant particles sample a smaller level, which stops them shimmering
  and cuts texture-cache pressure when a plume fills the screen. Frames already fade to alpha 0 at
  their borders, so lower mips do not bleed one frame into its neighbour.
- **A fixed `visibility_aabb`** — without one Godot recomputes bounds, and a moving emitter with
  world-space particles can cull a plume that is still plainly visible.
- **`draw_order = VIEW_DEPTH`** for correct back-to-front blending between particles.
- **`density`** export (build-time multiplier on every layer's ceiling) so the ceiling can be raised
  deliberately with the cost understood, rather than by editing three numbers.

**Known next step, not taken:** the 12 emitters (3 layers x 4 wheels) could collapse to 3 using
`emit_particle()` to spawn at arbitrary transforms from one pool per layer — fewer draw calls, and
density could pool where it is needed instead of being split four ways. `emit_particle` is confirmed
to exist, but GPU particles do not simulate under `--headless`, so it cannot be verified without
driving; it was left rather than changed blind.

**Not drive-tested.** If the frame rate drops, `density` is the first knob (try 0.6), then
`plume_d_max_tyres` — halving the diameter quarters the fill cost, which no count change can match.

## 2026-08-14 (four named effects; plumes and gravel split apart)

**The four surface effects now have fixed names, recorded in `CLAUDE.md`** so a future session
cannot blur them: **asphalt smoke**, **asphalt tire tracks**, **dirt/dust plumes**, and
**dirt/gravel particles**. They are four separate systems with unrelated fixes — the user named
them precisely because confusing them was already causing wrong changes. LAYERS keys renamed to
match (`plume`, `gravel`, `smoke`).

**Sizes are now quoted in TYRE DIAMETERS, not metres**, because that is how they are specified
("4-6 times larger than the tires", "half a tire", "2x tire size") and because it stays correct if
the wheel size ever changes. The particle mesh is a 1x1 quad, so a particle's scale IS its diameter
in metres and the arithmetic stays readable. Tyre diameter is read from `car.wheel_radius` (0.68 m).

**DIRT/DUST PLUMES — now speed-driven, and much bigger.** They kick up from 20 km/h, are fully
established by 40, and sliding adds on top (0.60 straight, 1.00 sliding) — a change from the
previous slip-only gate, which meant a fast straight line on gravel threw nothing.
Measured size: 40 km/h → 2.0 tyre diameters, 60 → 2.7, **100 → 4.2, 120 → 5.0, 160 → 6.5**, holding
at the ceiling beyond (checked at 200 km/h). That puts 100 km/h+ in the requested 4–6x band.
**Frequency has two parts now.** Per-metre emission (rate proportional to speed, because particles
live in world space and a fixed rate smears over more ground the faster you go) TIMES a *fluidity
gain* so the plume also thickens in its own right. Measured against 40 km/h: 60 → 1.78x, 100 →
3.91x, **120 → 5.25x**, 160 → 6.99x. Of that 5.25x at 120, 3x is distance and **1.75x is the gain**,
which is the 1.5–2x asked for. Rise speed scales with speed too (x0.6 → x1.7).

**DIRT/GRAVEL PARTICLES — split from the plumes and gated separately.** Mainly slides, but high
speed alone flicks some stones, and the same slide throws fewer of them when slow. Measured:
20 km/h sliding 0.52, 60 sliding 0.66, 120 sliding 0.98; 120 straight 0.12, 160 straight 0.22,
20 straight 0.00. Stones do not scale with the tyre — they stay 7 cm.

**ASPHALT SMOKE — born half a tyre, grown to two.** Baseline is exactly the spec: born 0.34 m
(0.5 tyres), reaching 1.36 m (2.0 tyres). The pressure build-up now grows it BEYOND that baseline
(x1.4 at a full column → 2.8 tyres) rather than up to it. It is also more frequent from the start
(density floor 0.45, so 0.71 at speed with no build-up at all) and rises faster (3.0 vs 1.8 m/s),
and it uses the same speed-based frequency formula as the plumes.

**Not drive-tested — visual.** Knobs: `plume_d_min_tyres` / `plume_d_max_tyres` for plume size,
`fluid_gain` (1.75) for the extra frequency ramp, `plume_speed_start` / `_full` / `_ceiling` for
where it begins and tops out, `gravel_speed_share` for stones without sliding, and
`smoke_d_birth_tyres` / `smoke_d_death_tyres` / `smoke_build_gain` for the smoke column.

## 2026-08-14 (particles: speed-scaled dust, building smoke column)

**Accepted look, refined behaviour** — user verdict on the rebuilt system: *"the particles look
much much better and mimic a lot more closely the behavior i wanted"*. This entry is the tuning
pass on top of it, plus one API change that was needed to do it honestly.

**Moved the emitters from CPUParticles3D to GPUParticles3D**, for one reason: `amount_ratio`. It
scales emission density continuously with no restart. The CPU node has no equivalent — its only
rate control is `amount`, and writing that mid-drive restarts the system and wipes the live cloud.
Verified `amount_ratio` exists on GPUParticles3D and does NOT exist on CPUParticles3D before
committing to the change. The move also brought turbulence, so dust now swirls instead of drifting
in straight lines.

**Dust grows and thickens with speed, from 20 km/h to a ceiling at 120.** Frequency has to scale
with speed, not just size: particles are left in world space, so a fixed emission rate is smeared
over three times the ground at 100 km/h that it covers at 30 — the plume visibly thins exactly when
it should be biggest. Emission per METRE is the honest quantity. Measured: 20 km/h → scale x0.85,
density 0.35; 40 → x1.14, 0.48; 60 → x1.44, 0.61; 90 → x1.88, 0.81; 120 → x2.30, 1.00; and beyond
120 it holds at the ceiling rather than running away.
Particles are also **born bigger, expand faster and settle larger**: the growth curve is now
[birth 0.75 → 2.30 by 32% of life → 3.10 at death] against the old [0.30 → 1.85 linear], and
**life is 4.6 s, up from 3.2 s**. Base sprite 0.42 → 0.52 m.

**Tyre smoke now BUILDS under pressure and subsides slowly**, like a real tyre. It integrates
pressure rather than tracking it, so a long drift makes a column and a quick stab does not, and
lifting tapers instead of switching the smoke off. Measured: under sustained slip the column
reaches 0.39 after 1 s, 0.77 after 2 s and full at 2.6 s; once the pressure is off it falls to 0.60
after 2 s, 0.20 after 4 s and is gone by 6 s. The build-up drives SIZE (x0.75 with no build, x2.00
at a full column) and density, while instantaneous pressure drives opacity.

**Sizes are smoothed before they reach the shader.** `scale_min`/`scale_max` are uniforms the GPU
reads every frame, not values baked at spawn — writing them raw would resize every live particle at
once, the same class of bug as the earlier colour flicker. They ease over ~0.7 s so a change reads
as the cloud swelling.

**Not drive-tested — visual.** Knobs: `dust_size_start` / `dust_size_ceiling` / `dust_size_full`
for the speed ramp, `dust_density_start` / `_ceiling` for frequency, `smoke_build_time` (2.6 s) and
`smoke_decay_time` (5.0 s) for how fast the column comes and goes, and the `grow` arrays in
`LAYERS` for the per-particle expansion.

## 2026-08-14 (particles rebuilt on research)

**Particle system rebuilt as a data-driven layer table, after the first attempt looked wrong.**
Symptoms this closes: *"the plumes are in the middle and move to each side the moment I touch
steering"*, *"they look identical, like a weird oblong shape"*, *"wrong colour"*, *"the single
streak on gravel starts at any speed"*.

**The identical-shape bug, which is worth remembering.** A `CPUParticles3D` has ONE mesh with ONE
texture, so every particle in a system draws the SAME sprite. The previous "5 variants" only varied
between emitters, not between particles — so a 60-particle plume was 60 copies of one shape, which
is exactly what read as a single oblong blob. The fix is the standard flipbook route: a **2x2 atlas**
with `billboard_mode = BILLBOARD_PARTICLES`, `particles_anim_h/v_frames = 2`, and per-emitter
`anim_offset_min/max = 0/1` with `anim_speed = 0`, so each particle picks a random static frame.
Verified: the 4 frames differ in coverage 0.097–0.194 (2x) with distinct centroids.
**Sprites are now clusters of overlapping circles** (max of soft circular falloffs, merged into one
lumpy silhouette), because that is what a dust or smoke puff actually looks like.
**Born small, swelling, fading to nothing:** `scale_amount_curve` takes dust 0.30 → 1.85 over its
life while `color_ramp` alpha ends at 0. Ending on alpha 0 is documented as the single biggest
factor in whether a particle effect reads as believable.
**Emission is from a small BOX** at each contact patch rather than a point, so a cloud has body.
**Soft particles:** `proximity_fade` fades the sprite where it cuts the ground instead of showing a
hard intersection line.

**No more centre streak.** The plume was ONE car-level emitter offset along the velocity vector, so
it sat in the middle and swung sideways the instant the velocity direction changed under steering.
All three layers are now per-wheel, born at the contact patch, and left in world space — the plume
forms behind the car because the car drives away from it, not because it is placed there.

**Dust now needs SPEED and SLIP, multiplied — not added.** The old version added a rolling term, so
it trailed a plume at walking pace. The speed gate takes whichever is larger, road speed or slip
speed, so a spinout still raises dust while a crawl cannot. Measured: crawling 0.00, cruising
90 km/h gripping 0.00, 90 km/h light slide 0.42, 90 km/h big drift 0.94, 40 km/h big drift 0.22,
standing burnout 0.67.

**Colour.** Particles are UNSHADED again but tinted by the sun's current colour and energy. Shaded
billboards are lit through a camera-facing normal, so their brightness changed as the camera swung
— that was the "wrong colour". Tinting keeps them in step with the time of day without the artefact.
Base colour still comes from `ground_color()`, which includes the wear line's dark tint.

**Smoke is deliberately much less than dust**, as asked: alpha ceiling 0.30 against dust's 0.44,
scaled by a further `smoke_scale` 0.55, smaller (0.30 m vs 0.42 m) and shorter-lived (2.4 s vs 3.2 s).

**Structure.** Layers are now declared in a `LAYERS` dictionary — amount, life, size, gravity,
growth curve, alpha ceiling, spread, damping, emission box, render order — and `_build_layer()`
turns a declaration into four per-wheel emitters. Adding water spray, snow or mud is a dictionary
entry, not new code. **Not drive-tested — visual.**

## 2026-08-14

**Particle system rebuilt as THREE layers, plus two rendering artefacts fixed.**
Symptoms this closes: *"the smoke flickers in brightness when braking"*, *"smoke fades in and out
of the tyre tracks"*, *"the particles don't match the colour of the dirt tracks"*, *"the worn line
doesn't darken with the ground at dusk"*.

**Three layers, because they are three phenomena and not one effect at three sizes.**
1. **SMOKE** on hard surfaces — white-grey burnt rubber, from drifts and hard stops.
2. **PLUME** on loose surfaces — the big billowing cloud a rally car drags behind it. Driven by
   SPEED, not just slip: a tyre shears loose material simply by rolling over it, which is why a
   gravel car trails a cloud down a straight at constant throttle. Measured: 0.16 at 29 km/h
   cruising with zero slip, 0.49 at 90 km/h, rising to 0.87 at 90 km/h with half slip. Born
   `plume_back` (2.4 m) behind the car, big (0.85 m), slow, long-lived (2.8 s).
3. **GRIT** on loose surfaces — small stones and sand thrown ballistically from the contact patch.
   Heavy (gravity −19), short-lived (0.55 s), tight 26° fan, no air damping. Needs slip: cruising
   throws a plume and no grit.

**Flicker fix — the cause was mine and it is worth remembering.** `CPUParticles3D.color` is a
UNIFORM over the whole system, not a per-particle value set at spawn. The code wrote it every
physics frame from a raw intensity, so every live particle was re-tinted at once — and under
braking the load pumps through the bump stops at a few Hz, which showed up as the entire cloud
pulsing in brightness. The driving signal now goes through an **envelope follower with fast attack
(0.18 s) and slow release (1.60 s)**: it swells the instant a slide starts but rides over the
troughs instead of dipping into each one. Measured on a 4 Hz oscillating input: raw swings 0.64
peak-to-peak, smoothed swings **0.13 — 80% of the flicker removed**, sitting at 0.87–1.00 rather
than tracking down to 0.36. Grit gets its own short release (0.14 s) because stones are discrete:
they stop when the slip stops, and a lingering trickle of gravel looks wrong.

**Sorting fix.** Smoke drifting over a skid mark could flip behind it and back, because transparent
surfaces are sorted per object. Explicit `render_priority` now pins the order: marks (−1) under
grit (0), plume (1) and smoke (2).

**Colour match.** Dust sampled `stage._surface_color()` — the BASE terrain — but `wear.gd` paints
the driven line toward a dark worn brown at up to 0.84 alpha, and the car spends its life on
exactly that line, so the dust was far too pale for the ground it came off. `ground_color()` now
recovers the wear fraction from the grip the wear node reports versus the stage's base grip
(`wn = (g_worn/g_base − 1) / wear_grip`) and applies the same tint the overlay does — no new
plumbing, and it stays correct if wear.gd's tuning changes.

**The wear line's own rendering issue: it was UNSHADED** while the terrain beneath it is lit. It
kept its noon brightness through the whole time-of-day cycle, so it read as a glowing stripe at
dusk and night instead of darkening with the ground it is painted on. Now `SHADING_MODE_PER_PIXEL`,
as are the particles, so all three stay in the same light.

**Not drive-tested — visual.** First knobs if it is wrong: `plume_speed_ref` (28 m/s for a full
rolling plume), `slip_ref` (6 m/s), `smoke_power_ref` (45 kW), and `release` if any flicker remains.

## 2026-08-13 (evening, later)

**Tyre smoke on hard stops, and particles that look like dust instead of flying squares.**
Symptoms this fixes: *"stamping on the brakes on tarmac produces no smoke"*, *"the particles look
like squares flying"*, *"dust puffs around the car instead of trailing behind it"*.
**Smoke had one cause and needed two.** It gated on M7 tyre temperature alone, so a panic stop
made none — the tread had not had time to heat up, which is precisely when a real tyre smokes
most. Smoke now takes whichever route is stronger: THERMAL (a tyre worked hot over a long drift)
or POWER — friction power at the contact patch, P = mu.Fz.v_slip, which a locked wheel dumps into
the tread instantly. Measured: a hard stop on cold tyres (60 C, 5 kN, 25 m/s of slip) now reads
**1.00 where the temperature-only gate read 0.00**; a cold lock-up at 30 km/h reads 0.68; threshold
braking with small slip reads a faint 0.07; cruising stays at 0.02. Colour is white-grey (0.90,
0.90, 0.92) burnt rubber.
**Particles** now use procedurally generated soft puff sprites — 5 variants, each with its own
lobed silhouette and internal mottling from its own seed, generated in code like everything else
(no image assets). Each particle also gets a random start rotation, its own spin, a wide scale
spread (0.35–1.7), randomised lifetime and air damping, and a gradient that fades it in and
dissolves it rather than blinking it out. Verified: ~145 of 256 sampled pixels per sprite are
partial alpha, where a flat square would be 0. Dust is smaller (0.20 m) and there is more of it
(44 per wheel), which is what reads as dust rather than debris.
**Dust now trails.** Material is thrown BACKWARD along travel (`dust_trail` 0.65 of the kick)
instead of straight up, so a plume streams behind the car rather than puffing around it.
**Still not drive-tested** — visual, so only driving can judge it. `slip_ref` (6 m/s for full
intensity) and `smoke_power_ref` (45 kW) are the first knobs to reach for if it is too eager or
too shy.

## 2026-08-13 (evening)

**M11 dust, smoke and skid marks — now driven by physics instead of a threshold.** New
`scripts/effects.gd`, self-contained; the old inline code in `world.gd` is gone.
Symptoms this fixes, in driving words: *"sliding sideways on gravel throws no dust"*, *"dust
looks identical on grass and on the gravel loop"*, *"tyre smoke on tarmac whenever a wheel
spins, even stone cold"*, *"skid marks vanish mid-corner"*.
The old test was `w.slip > 0.35` — slip RATIO only — so it saw wheelspin and lock-ups and was
blind to everything else. Effects now scale with **contact-patch slip velocity** (m/s of rubber
actually sliding, combining slip ratio AND slip angle) times **load**, so a lightly loaded wheel
throws less. Measured on synthetic cases: a pure sideways slide at 25 km/h reads 12.0 m/s of slip
and full intensity where the old test emitted **nothing**; a big slide on an unloaded wheel drops
to 0.20 intensity where the old test emitted at full; a blip at a standstill drops to 0.19 (a
puff, not a plume); gripping at 108 km/h stays at 0.00.
**Smoke is thermal, not merely frictional** — it gates on M7's per-tyre temperature, starting at
110 °C and reaching full at 165 °C (optimum is 85 °C), so a cold lock-up puffs and a long drift
billows. **Dust takes its colour from the ground it came from** via `stage._surface_color()`, so
the gravel loop throws dusty tan and the grass verge throws olive — no per-surface colour
constants. **Marks** moved from 600 individual nodes to one MultiMesh with per-instance alpha and
a 14 s fade, so the pool wrapping thins the oldest mark out instead of making it disappear.
*Owed follow-up: the new `@export`s (slip_ref, smoke_temp, mark_fade, …) have no tuning-panel rows
or HELP lines yet — `tuning_panel.gd` was held by the B2 session at the time. Add them when it is
free, per the convention.* **Not yet drive-tested — this is a visual change and only driving can
judge it.**

## 2026-08-13 (later — gravel lateral peak to 16 deg, and four sliders renamed)

**`peak_alpha_gravel` 14 -> 16 deg** (user's call, after the "feels good" verdict). Widens the
self-correcting window on gravel: the car stays on the RISING side of the lateral curve to 16 deg
of slip instead of 14, which is where a slide still pulls itself straight. Still inside realistic
gravel numbers.

**"Couldn't find the peak slip angle gravel slider" — four sliders were named almost identically.**
The panel sorts A-Z, and there were FOUR rows beginning "Peak slip", landing adjacent: "Peak slip
angle gravel/tarmac" (LATERAL, degrees of slip angle) and "Peak slip gravel/tarmac" (LONGITUDINAL,
% slip ratio). Two pairs governing completely different axes, distinguished only by the word
"angle" buried mid-label. Renamed so the axis is the first thing you read and the four still group
together:
`Grip peak LAT gravel` / `Grip peak LAT tarmac` (degrees) and `Grip peak LONG gravel` /
`Grip peak LONG tarmac` (% slip). The HELP lines now open with **TYRE, LATERAL (cornering)** or
**TYRE, LONGITUDINAL (drive/brake)** for the same reason. Audit after: 86 rows, no duplicate
labels, no row missing help, no orphaned help.
*Convention reinforced: when two tunables differ only by which AXIS they act on, the axis belongs
at the FRONT of the label, not buried in it.*

## 2026-08-13 (slide fix — new lever + a latent bug found)

**`_mf_peak_u` was silently clamping, putting the force peak in the wrong place.** Latent bug, no
symptom until now. The solve bisects over a hard-coded `[0, 60]` bracket, but the peak parameter
grows fast as the Pacejka shape factor C falls: C 1.65 -> ~4, 1.40 -> ~20, **1.20 -> ~73, 1.10 ->
~181**. Anything below C ~1.3 hit the ceiling, so the derived B came out too small and the force
peaked LATER than the exported angle asked for — measured 17.3 deg at C 1.20 and **42.3 deg at
C 1.10**, against a requested 14. It never bit before because Cx (1.65) and Cy (1.40) both sit
inside the bracket; it would have bitten the moment anyone lowered a shape factor. The bracket is
now derived from C instead of fixed, and the peak holds at 14.0 deg at every C tested.

**New lever for "the car lets go too easily once sideways": `cy_gravel`.** The lateral curve's
post-peak SHAPE is now a surface property, like its peak location already was. `Cy` is the tarmac
shape, `cy_gravel` the gravel one, both on the Tab panel, and `_lat_shape()` returns (B, C) per
wheel so the two stay consistent. **Default `cy_gravel` = 1.40 = identical to the previous car**,
verified — it is new tuning surface, not a feel change.
What it buys, measured as the RESTORING SLOPE per degree past the peak (negative = sliding more
gives less grip, so the slide amplifies itself): C 1.40 gives -0.0006 to -0.0011/deg, C 1.20 about
halves that to -0.0005/-0.0006, and C 1.10 nearly removes it at -0.0002/-0.0001. The peak stays
at 14 deg throughout, so this forgives an overshoot WITHOUT making the tyre unrealistically sticky.
**Framing that matters for tuning:** the dominant term is still `peak_alpha_gravel`, because it
decides where the strongly self-correcting region ENDS — the old By=10 car had roughly +0.006/deg
of restoring gradient still pulling at 25 deg, where the B4 car has -0.0009. `cy_gravel` shapes
what happens beyond the peak; `peak_alpha_gravel` decides where beyond starts.

## 2026-08-13 (B4 diagnosis — RESOLVED, see the entry above)

**"Much easier to lose control of the slide", "maintaining a good entry has got harder" after B4.**
**RESOLVED 2026-08-13 — re-drive verdict "feels good", on the UNCHANGED B4 defaults** (9/14 deg
peaks, `sigma_lat` 0.55, `cy_gravel` 1.40). The fix was the `cy_gravel` lever plus the
`_mf_peak_u` bracket bug above; the user did not need to move a slider in the end, and noted they
may tune again later. **If it comes back: `peak_alpha_gravel` first (it decides where the
self-correcting region ends), then `cy_gravel` (it shapes what happens past the peak).**
Measured cause: **the old fixed
`By = 10` put the lateral force peak at 114.8 degrees of slip angle**, i.e. beyond ANY angle a car
can reach. Every slip angle you could actually drive was on the RISING side of the curve, so grip
kept increasing the further you slid — at 40 deg you still had 0.988 of peak and climbing. The
tyre never let go, and a slide was always self-correcting.
B4's derived `By` moved the peak to **14 deg on gravel and 9 deg on tarmac** (realistic; real tyres
peak at 6–10 deg on tarmac). Past those angles the curve FALLS. So normal cornering moved from the
rising side to the falling side, and that flips the sign of the feedback: on the rising side more
slip gives more restoring force (self-correcting), on the falling side more slip gives less
(self-amplifying). **The magnitude of the drop is tiny — 0.989 of peak at 30 deg on gravel — so
this is not about losing grip, it is about losing the SLOPE that used to catch the car for you.**
Post-peak the curve settles at 0.809 of peak (set by `Cy` 1.40 via sin(Cy*pi/2)).
Secondary contributor: relaxation length adds ~28 ms of lag at 20 m/s before the correction
arrives (`sigma_lat` 0.55 m).
Levers, all on the Tab panel: `peak_alpha_gravel` / `peak_alpha_tarmac` (widen the stable window)
and `sigma_lat` (shorten the lag). If those are not enough the code option is a surface-dependent
`Cy` — a flatter curve on gravel, which forgives past the peak WITHOUT moving the peak.

## 2026-08-13 (B4 + B5)

**B4 — the car takes a set instead of darting.** Symptom this addresses: *"steering feels darty"*,
*"the car changes direction instantly"*, *"a Scandinavian flick can't be timed"*, and *"gravel and
tarmac break away the same way"*. Three changes.
**Relaxation length** (`sigma_lat`, 0.55 m): a tyre must ROLL about sigma metres before its lateral
force builds, so the force now follows a relaxed slip angle (`w.alpha_rel`) rather than the
instantaneous one. Expressed per distance rolled, not per second — measured 63% of a step reached
after **0.533 m at 8 m/s and 0.500 m at 30 m/s**, i.e. the same distance at very different speeds,
which is the proof it is a tyre property and not a frame-rate or speed artefact.
**Surface-derived `By`**: the fixed `By = 10` is gone. Lateral stiffness now derives from where
each surface peaks — `peak_alpha_tarmac` 9 deg, `peak_alpha_gravel` 14 deg — exactly as `Bx`
already did longitudinally. Measured peaks land on 9.0 and 14.0 deg exactly. Gravel now slides
deeper and more progressively before letting go; that gap IS the surface difference.
**CoM height** is an export (`com_height`, still -0.45) so raising it toward -0.30 is a slider A/B
rather than a code edit.
Stability checked on the STRAIGHT drag strip (the asphalt ring is curved, and testing there first
gave a false 0.544 rad/s "weave" that was just the road): peak yaw **0.000 rad/s at both 1 m/s and
250 km/h** — no shimmy, no weave.
`hs_blowoff` baked to **0.45** (user's call after the B2 drive).

**B5 — prune found nothing to prune, which is the point.** Every retired system had already been
cleaned up by the phase that retired it: `_t_drive`, `torque_rise_time`/`torque_fall_time` (A1),
`lsd_lock` (A3), `rear_grip_cut` and `brake_force` (A5), `spring_k`/`damper_c`/`arb_front`/
`arb_rear` (B1) and the interim single `zeta` (B2) are all absent from the code — the only
surviving mentions are comments explaining what was removed and why. Tuning panel audited: **83
spec rows, 83 HELP entries, zero rows missing help and zero orphaned entries.** The two M1-only
rows (`engine_power`, `launch_boost`) are deliberately kept — the panel skips any row whose
property the loaded car lacks, which is what lets one panel serve both vehicles.
`docs/ROADMAP.md` updated: M15 marked done, and the Tier-3 torque-delivery entry now carries an
explicit **"do not resurrect `_t_drive`"** warning, since that entry still describes a system A1
replaced and a future session reading it cold would otherwise rebuild it.

## 2026-08-13 (later still)

**B2 CLOSED — drive verdict: "feels good".** Asymmetric digressive damper accepted.

**Suspension travel cut from 500 mm to 320 mm — the "vertical budget" was never the problem.**
Symptom this closes: *"all four corners bottom out on the rally loop"*, *"suspension bottoming
going uphill at 100 km/h"*, and the instinct that follows it — *"the car needs more travel"* /
*"raise the ride height"*. It does not. Real gravel WRC cars run **250-300 mm of TOTAL wheel
travel**; this car had 500 mm, i.e. **373 mm of BUMP travel alone — more than a real rally car's
entire stroke — and it still pegged 100%**. Travel was never the constraint, and the ride-height
lever taken earlier (0.45 → 0.50) made it worse, not better. Ground clearance had reached 538 mm
against a real gravel car's ~300 mm.
Measured on the rally loop at ~100 km/h, 500 mm vs 320 mm: peak travel 100% in both, 4/4 corners
pegged in both, frames on the stops **50 → 177**, and — the counter-intuitive part — **peak Fz
28.8 kN → 23.1 kN**. Less travel produced LOWER peak loads, because the spring keeps building
force over the whole stroke: at full compression it made 12.1 kN of spring force at 500 mm
against 7.7 kN at 320 mm. The inflated travel was manufacturing its own load spikes.
Static sag is unchanged at 127 mm (springs untouched, B1 is drive-verified), so sag is now 40% of
total travel and bump travel is 193 mm; body clearance 358 mm.
**What to expect, and what NOT to diagnose as a bug:** the car now rides its bump stops often
(177 frames vs 50). That is correct — a real rally car on rough gravel is on the stops constantly.
It is also exactly why the stop wants to become **hydraulic** (velocity-sensitive, dissipating
energy as heat) instead of the current pure displacement spring, which stores the impact and
hands it straight back. That is the outstanding B3 revision, and it is now the ONLY remaining
suspect for bottoming harshness: B2 was tested and disproven as the fix (it cut peak load 23% but
slightly increased stop contact), and travel is ruled out by the numbers above.

## 2026-08-13 (later)

**B1 CLOSED — drive verdict: "feels good".** The derived suspension setup is accepted, and the
verdict covers the 5 cm ride height and the `chassis_mass` slider fix as well, since both landed
before the drive. B2 is now unblocked.

**Tuning panel: A–Z ordering and a live explanation banner.** The B1 drive surfaced that
`roll_gradient_target` was unintelligible — and the cause was structural, not that one label: the
panel was ~76 sliders in one flat list, in source order, with no explanation of any of them
anywhere in the game. Every control now carries a one-line explanation, shown in a fixed banner
under the title on hover (and as the native tooltip), and the list is sorted alphabetically so a
control can be found by name. Each explanation opens with the system it belongs to — ENGINE,
DIFF, SUSPENSION, TYRE — because alphabetical order scatters related knobs and the tag is what
carries the grouping. Coverage is verified: 76 of 76 sliders have help, with no orphaned entries.
*Convention added: a phase that adds a tunable adds its HELP line in the same commit.*

## 2026-08-13

**Drag strip extended to 4 km, with markers and barriers.** `strip_x1` now derives from a new
`strip_len` (4000 m) instead of being hand-set, so the strip re-marks itself if the length
changes. Distance posts every 100 m down both shoulders as a single MultiMesh (taller and orange
on each kilometre), a billboard call-out per kilometre, and a W-beam guard-rail arc round the far
lip of the runoff pad — 46 collision panels, 183 posts, beam top 0.75 m. `_guard_rail(polyline)`
lays panels and posts along any polyline and is reusable for new areas. *Note for top-speed runs:
at 259 km/h you need ~174 m to stop but there are only 91 m from the 4 km mark to the rail, so be
on the brakes by the 3.9 km post — or raise `runoff_r`.*

**B3 travel budget resolved — the car is jacked up 5 cm.** `rest_length` and `max_travel` 0.45 →
0.50, settling the item B3 left open. Ride frequencies deliberately untouched: stiffening them
would walk back the softness B1 exists to provide. Spring rates derive from corner mass and ride
frequency rather than ride height, so static sag in metres is unchanged — what changed is the room
above it. Measured: no corner bottoms at rest, and the bump stop now engages from 0.40 m instead
of 0.36 m, about **+4 cm of free bump travel per corner, +15% total**. Costs ~5 cm of CoM height
and so ~16% more roll moment, so **B1's roll couple wants a re-check on the next drive**.

**Fixed: the car-weight slider desynced the body from its own suspension.** `mass = chassis_mass`
is assigned once in `_ready()`, and the Tab panel's "Car weight" row drove the RigidBody's `mass`
only — so `chassis_mass`, the single authority for corner masses, roll gradient, the tyre load
reference (`_mu_load`) and rolling resistance, stayed at 1250 whatever the slider read. The row now
drives `chassis_mass`, and `_derive_setup` keeps the body's `mass` following it, so a live weight
edit re-rates the whole car. Only reachable by moving the slider to an extreme, which is why a
stress test found it and normal driving never would.

**Stress-test findings (user drove every slider to its goes-faster extreme).** None of these are
defects; they characterise the model's edges. Recorded in full in `docs/ROADMAP.md`.
- **Top speed is a numeric clamp, not a force balance.** 490 km/h is the wheel-spin clamp
  (±400 rad/s × 0.34 m = 489.6 km/h), with the valve-float ceiling (1.35 × redline through 6th)
  landing within half a km/h of it by coincidence. `top_speed_kmh()` knows about neither, so the
  speedo it graduates can under-read by >100 km/h at extreme settings.
- **The ~1 km stop from 490 km/h is correct physics.** Probed and swept: `mu_long` 0.9 → 856 m /
  1.13 g, 1.6 → 589 m / 1.65 g, 2.6 → 433 m / 2.22 g. With `drag_k` slidered down to 0.05 the aero
  term falls from ~13 kN to ~0.7 kN, so nothing but the tyres slows the car. An earlier attribution
  blaming the weight slider was wrong and has been corrected in the roadmap.
- **The car pogos above ~400 km/h, and it is underdamping — not aero.** Coasting with no input,
  suspension load collapses below 15% of static weight on 0% of frames at 299 km/h, 4% at
  468 km/h and 34–45% at 489.6 km/h. With `drag_k` at 0.0 it is unchanged (drag is a central force
  with no vertical component and no downforce model exists); with `zeta` 1.2 it drops to 3%, and
  2.5 to 0%. **This is B2's target and its headless success metric** — do not "fix" it by raising
  `zeta`, which would undo B1's compliance.
- **Nothing has ceiling behaviour.** Engine torque holds flat above redline instead of collapsing;
  tyre temperature reaches 128–299 °C against an 85 °C optimum with no upper bound. The model is
  well-behaved inside its envelope and simply extrapolates outside it.

**Planning.** Arc D (`docs/PLAN-stages-ground-map.md`) planned: the ground map and real
point-to-point stages, built on Arc C1's roughness field. **Settled decision: new maps go in a NEW
area — the existing circuits, centre patch and 4 km strip stay untouched as the calibration bed**,
because every baseline the project has is expressed in their terms. C1's execution prompt written.

## 2026-08-12

- **Fixed the real top-speed limiter:** Godot's default linear damping (COMBINE mode) was capping
  the car around 130 km/h. The 3rd-gear-redline ~140 reading was a separate red herring.
- **Speedo scales to the car's real top speed**, circular see-through dial.
- **A real engine thermal model** plus a cluster restyle; bottom-right outside-view cluster with
  warning telltales for the exterior cameras.
- **Camera:** right-stick look-around, click to glance behind.

## 2026-08-11

- **B1 — derived suspension setup.** `spring_k`/`damper_c`/`arb_*` are gone; springs come from
  ride frequency (1.4/1.6 Hz), dampers from `zeta` 0.65, bars from a target roll gradient and front
  roll couple, re-derived each tick so live edits and drive-mode CoM shifts both re-rate the car.
  First drive exposed the inside driven wheel overheating: the bars were sized only to reach the
  roll-gradient target, so they solved to zero and the springs' own distribution set the balance
  (43.4% front against a 55% setting). `_derive_setup` now enforces the couple first. **Still
  awaiting its drive verdict.**
- **B3 — bump stops, brought forward ahead of B2** because B1 testing bottomed. Progressive cubic
  stop over the last 20% of travel, sized off each corner's own static load; `w.bottomed` is now
  available to M7 as a clean hard-hit puncture trigger (not yet wired).
- **A4 and A5 closed, both drive-verified.** A5's first attempt was rejected as "way too strong"
  and reworked so sliding tyres take their force direction from the slip velocity.
- Cabin work: analog tacho and speedo dials, restyle, binnacle clipping fixed.
- Plan: Arc C added (surface roughness, self-aligning torque, wheel input, FFB), then C1 inserted
  ahead of the FFB phases.

## 2026-08-09 – 2026-08-10

- **A3 differentials drive-verified**; diff presets `[1]/[2]/[3]` marked a permanent keeper.
- **A4 shift model + launch and stability assists**, including a money-shift guard; stability
  assist later fixed for cutting power through ordinary corners.
- **DualShock 4 support** in an Assetto-Corsa-style rally layout — analog pedals live.
- Plan: the reusable headless input-probe harness pattern recorded in §0.

## 2026-08-04 and earlier

Initial repository snapshot: **M0–M10 complete plus the drivetrain arc through Phase A3.** That
covers the procedural stage (three concentric circuits, drag strip, deformable centre patch), the
combined-slip Pacejka tyre model with load sensitivity, the two-inertia engine and clutch driveline,
selectable differentials, tyre temperature/wear/punctures, the damage model, pace notes over OS TTS,
time-trial ghosts with sector splits, surface wear, and the live tuning panel. See the milestone
history in `docs/ROADMAP.md` for the detail behind each.
