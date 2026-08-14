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

## 2026-08-13 (B4 diagnosis — NOT yet resolved)

**"Much easier to lose control of the slide", "maintaining a good entry has got harder" after B4.**
Diagnosed, not yet fixed — awaiting the user's choice of remedy. Measured cause: **the old fixed
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
