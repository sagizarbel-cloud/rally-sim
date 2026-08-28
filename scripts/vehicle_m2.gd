extends RigidBody3D
class_name VehicleM2
## M2 - Pacejka tires + slip-ratio drivetrain + a REAL engine & clutch (Phase A1).
##
## TWO-INERTIA DRIVELINE:
##   The engine is its own rotating state (_omega_e):  I_e * dw/dt = T_comb - T_fric(w) - T_clutch.
##   Combustion torque follows the throttle through a small intake lag (intake_tau); motoring
##   friction T_fric(w) = c0 + c1*w is fit through engine_brake_idle / engine_brake_redline, so
##   engine braking GROWS with rpm. An idle controller injects up to WOT-at-idle torque to hold
##   idle_rpm - the engine free-revs in N, bogs when lugged, and can stall (manual clutch,
##   anti-stall off).
##   The clutch carries up to T_cap = engagement * clutch_margin * peak_torque. While slipping
##   the torque is Coulomb-like (tanh of the speed difference, Karnopp-style band); when the
##   speeds converge and the through-torque fits inside capacity it LOCKS, and the engine
##   follows the driven-wheel average kinematically - the proven pre-A1 path, reflected engine
##   inertia and all. Gears: -1 = R, 0 = N, 1..6 forward (Q/E through N).
##   Per wheel, drive torque -> slip ratio -> Magic Formula force (semi-implicit spin ODE,
##   sub-stepped); selectable per-axle differentials (A3: open / viscous / Salisbury
##   clutch-pack / locked) couple each axle pair, plus an AWD centre coupling.
##
## Grounded in: Pacejka (tires); Gillespie / Beckman (drivetrain); Bataus et al. (real-time
## clutch models with stick-slip); Vehicle Physics Pro docs (engine / clutch / idle design).

# --- Chassis / suspension ---
@export var chassis_mass := 1250.0
@export var body_size := Vector3(1.8, 0.55, 4.2)
@export var wheel_radius := 0.34
# B3 open item, settled 2026-08-13 (user's call): jacked up 5 cm, gravel-car style, to buy back the
# bump travel B1's softer springs spent on sag (7.7 -> 12.7 cm of static compression, on a loop that
# was already pegging all four corners at 100% travel at 100 km/h). The alternative was stiffening
# ride_freq_*, which would have walked back the softness B1 exists to provide. The cost is ~5 cm of
# CoM height and so ~16% more roll moment - re-check the roll couple, and expect C1's roughness and
# any Arc D crests/jumps to spend this travel again.
# Suspension travel, set to REAL gravel-rally figures (2026-08-13). Gravel WRC cars run
# 250-300 mm of TOTAL wheel travel; this was 500 mm, which left 373 mm of bump travel alone -
# more than a real rally car's entire stroke - and it was still pegging 100% on the rally loop,
# which is what proved travel was never the constraint. rest_length also sets ride height here
# (body origin sits rest_length + wheel_radius - sag above the contact), so 500 mm was giving
# ~54 cm of ground clearance against a real gravel car's ~30 cm. 320 mm is the top of the real
# range, keeping a little margin because this terrain's input may be harsher than a real road.
# EXPECT the bump stops to be in play regularly now: on a rough stage a real rally car uses them
# constantly, which is precisely why the stop wants to be hydraulic (dissipative) rather than a
# spring that hands the energy back - see the B3 revision in docs/PLAN-drivetrain-suspension.md.
@export var rest_length := 0.32
# B1: the suspension is DERIVED, not dialled in. Springs come from a target ride frequency per
# axle (k = m_corner * (2*pi*f)^2), dampers from a target damping ratio (c = 2*zeta*sqrt(k*m)),
# and the anti-roll bars from a target roll gradient - so the handles are the numbers a race
# engineer actually sets, and the corner masses re-derive themselves when the drive mode shifts
# the CoM. Gravel cars live at the soft end: 1.2-1.6 Hz, with the rear ~10-20% higher than the
# front so the car settles flat after a bump (flat ride). Race damping baseline is zeta 0.65-0.70;
# the pre-B1 constants worked out at ~1.8 Hz and zeta 1.13, i.e. stiff AND overdamped.
@export var ride_freq_front := 1.4          # Hz
@export var ride_freq_rear := 1.6           # Hz
# B2: a real damper is neither symmetric nor linear, and both departures matter.
# ASYMMETRY - rebound is firmer than bump. On compression the damper should get out of the way so
# the wheel can follow the ground; on extension it must pull the wheel back down WITHOUT levering
# the body up after it, so rebound carries the higher ratio. Real gravel practice is explicitly
# "soft in compression, firm in rebound".
# DIGRESSIVE KNEE - below the knee velocity the damper works at full rate, which is where it earns
# its keep: body roll, pitch and the set of the car in a corner all happen at low damper speed.
# Above the knee the valve blows off and the incremental rate collapses, so a square-edged rock or
# a washboard ridge passes through instead of spiking the load straight into the chassis. Without
# this, the only way to get body control is a damper that also makes rough ground unbearable.
@export var zeta_bump := 0.55               # damping ratio in compression
@export var zeta_rebound := 0.85            # damping ratio in extension (firmer, as on a real car)
@export var knee_speed := 0.08              # m/s of damper velocity where the valve starts to blow off
@export var hs_blowoff := 0.45              # incremental rate above the knee, as a fraction of below it
@export var max_travel := 0.32              # matches rest_length (the geometric maximum)
# Anti-roll bars are sized from a target ROLL GRADIENT (degrees of body roll per g of lateral
# acceleration) and a front roll-couple split, rather than picked in N/m. A bar can only ADD roll
# stiffness, so if the springs alone are already stiffer than the target the bars correctly come
# out at zero - soften the ride frequencies to roll more. Stiffer FRONT share biases toward
# understeer, stiffer REAR toward oversteer, through the load-sensitive tyre grip.
@export var roll_gradient_target := 4.5     # deg of roll per g
@export var roll_couple_front := 0.55       # fraction of total roll stiffness carried at the front
# B3: bottoming is an EVENT with a ramp, not a silent clamp. Over the last `bumpstop_zone` of
# travel a progressive (cubic) rubber stop comes in, sized off the corner's OWN static load so it
# scales with the car: at full engagement it adds `bumpstop_g` times that corner's static weight.
# This replaces both the old hard travel clamp and B1's interim Fz cap - loads are now bounded by
# something physical. `w.bottomed` is set while a stop is engaged (M7 can use it as the clean
# hard-hit puncture trigger the roadmap asked for).
@export var bumpstop_zone := 0.20           # fraction of max_travel the stop occupies
@export var bumpstop_g := 3.0                # extra load at full engagement, in g of static corner load
# Chosen from a sweep on the rally loop at 100 km/h. The stop trades peak load against how long a
# corner spends collapsed, and it does so steeply: 0g = 26.5 kN peak / 235 frames on the stops,
# 3g = 35.7 kN / 188, 6g = 44.9 kN / 194, 10g = 57.1 kN / 160. Past ~3g the loads climb far faster
# than the bottoming falls, which is the "crashy" the plan warns against - so 3g it is.
@export var com_height := -0.45              # B4: CoM height (m, body frame). Higher = more honest
											# roll and load transfer, tamed by real ARBs/dampers.
@export var camber_deg := 1.5                   # static negative camber (visual + a small grip cue)
# C1: the roughness field (scripts/roughness.gd) offsets the suspension raycast's measured ground
# distance, so texture the collision mesh cannot resolve still reaches the springs/dampers/bump
# stop/Fz/grip/tyre heat downstream of it, for free. This is the ONE gain that turns it off - the
# A/B that proves what the phase bought.
@export var roughness_gain := 1.0
# C1 REVISION: let the damper see the road. A damper reacts to RELATIVE velocity across itself, and
# with no unsprung mass the wheel follows the ground exactly - so the ground's own vertical velocity
# (local slope x ground speed) belongs in the damper velocity alongside the body's. Without it the
# roughness field can only push through the SPRING, which measured as a ~12% load wobble and was
# reported as unfeelable. ON by default; the toggle is the A/B that isolates this term.
@export var damper_reads_road := true
# Individual term amplitudes, mirrored onto the car (not left on the Roughness node) purely so the
# Tab panel - which only ever reads/writes `vehicle` properties - can reach them live. Synced into
# roughness_field once per tick, before the raycast pass. Defaults are the C1.1 physically-derived
# starting points; the drive test is expected to move them, same as B1's ride-frequency numbers.
# D3: SHAKEDOWN stage parameters. They live here only because the Tab panel binds vehicle
# properties; StageArea watches them and REGENERATES the stage when they settle. Changing these
# rebuilds terrain, so it is debounced rather than applied per slider tick.
@export var stage_seed := 20260828.0     # STAGE: whole-stage seed. Same seed = same stage, exactly.
@export var stage_sinuosity := 0.55      # STAGE: 0 = direct, 1 = as twisty as the design speed allows
@export var stage_elevation := 0.6       # STAGE: 0 = valley floor, 1 = over the ridges
@export var stage_design_speed := 30.0   # STAGE: km/h. Sets the minimum corner radius. HIGHER =
                                         # STRAIGHTER, because R = V^2/(127(e+f)).
@export var tyre_audio_surface := true   # AUDIO A/B: tyre audio takes its surface from the ground
										 # map (ON) or from the old grip threshold (OFF). Lives on
										 # the car only because the Tab panel binds vehicle props;
										 # sound.gd reads it. See CHANGELOG 2026-08-28.
@export var road_class_gravel := 128.0   # ISO 8608 Gd(n0), rally loop broadband "grain"
@export var road_class_tarmac := 4.0     # ISO 8608 Gd(n0), asphalt broadband "grain"
@export var washboard_amp := 0.02        # m, gravel corner/braking-zone corrugation depth
@export var joint_amp := 0.006           # m, tarmac expansion-joint bump height
@export var patch_amp := 0.012           # m, tarmac patch-repair height

# --- Appearance ---
@export var livery_color := Color(0.16, 0.36, 0.82)
@export var accent_color := Color(0.96, 0.86, 0.12)

# --- Tire (Pacejka Magic Formula) ---
@export var mu_long := 0.9                   # realistic loose-gravel grip (was an arcade 1.7)
@export var mu_lat := 0.8
@export var load_sensitivity := 0.15         # grip coefficient falls as load rises (real tire behaviour)

# --- M7 tyre thermal + wear + puncture model (per wheel; folds into the Magic-Formula mu) ---
@export var tyres_enabled := true            # master toggle for the temp/wear/puncture model
@export var ambient_temp := 20.0             # cold tyre / air temperature (C)
@export var optimal_temp := 85.0             # peak-grip tyre temperature (C)
@export var temp_grip_window := 45.0         # C above optimal over which grip falls to overheat_grip
@export var cold_grip := 0.95                # grip multiplier when stone cold (gentle - cold tyres shouldn't strand you, esp. on grass)
@export var overheat_grip := 0.85            # grip multiplier when fully overheated (gentler - overheating shouldn't gut dirt grip)
@export var tyre_heat_rate := 0.00016        # C gained per watt of friction power per second (lowered - dirt slides were overheating tyres too fast)
@export var tyre_cool_rate := 0.05           # cooling toward ambient (1/s, scaled up by airflow/speed)
@export var tyre_wear_rate := 0.002          # wear per unit tyre-work per second (hotter wears faster) - lowered: tyres last longer
@export var worn_grip := 0.70                # grip multiplier at fully worn
@export var puncture_grip := 0.35            # grip multiplier when punctured
@export var puncture_flat := 0.62            # how much a punctured tyre visually squashes (deflated look)
@export var puncture_shake := 2500.0         # vertical jitter force (N) at a punctured wheel - feels like bumps
@export var engine_optimal_temp := 95.0      # engine's happy operating temperature (C) - for the component HUD
# Engine thermal model: a real heat balance, C*dT/dt = Q_in - Q_out, not a rate toward a target.
# Q_in is the share of the engine's OWN output that ends up in the coolant rather than at the
# wheels, so idling barely warms it and full throttle cooks it. Q_out is a radiator that a
# THERMOSTAT keeps shut until the engine is warm - which is what makes warm-up take a minute and
# then hold a steady temperature almost regardless of load, exactly like a real car. (The old
# model added a flat 16 C/s of load-scaled heat against cooling proportional to temperature; that
# solved to an equilibrium ABOVE the 135 C ceiling, so it pinned at maximum within seconds.)
@export var engine_heat_capacity := 40000.0  # J/K: iron block + head + coolant mass
@export var coolant_heat_frac := 0.85        # waste heat into the coolant per unit of brake power
@export var thermostat_temp := 88.0          # C: below this the radiator is bypassed (fast warm-up)
@export var radiator_k := 1150.0             # W/K of radiator capacity at rest, scaled by airflow
# Sized so the progression means something: cruising and hard driving both sit at the thermostat
# (~90 C, no lamp), sustained full throttle at speed settles ~112 C (amber - you are working it),
# and full throttle with no airflow runs away to the ceiling (red - you are abusing it).

# --- M8 damage model: hard impacts degrade the car (power / grip / a steering pull); repaired on respawn ---
@export var impact_threshold := 45.0         # horizontal decel (m/s^2) above which a hit counts as a crash (braking/cornering stay below)
@export var impact_scale := 250.0            # decel over the threshold that equals a full-severity hit
@export var damage_gain := 0.30              # damage added by one full-severity impact (0..1)
@export var damage_power_loss := 0.45        # fraction of engine power lost at full damage
@export var damage_grip_loss := 0.20         # fraction of tyre grip lost at full damage
@export var damage_steer_pull := 0.22        # steering bias (fraction of full lock) at full damage - the car pulls to one side
@export var impact_punctures := false        # OFF by default: the Fz spike is unreliable (anti-roll bars inflate it past 20000, so respawn landings punctured). Wear-blowout punctures still apply.
@export var puncture_load := 30000.0         # Fz spike (N) that punctures a tyre WHEN impact_punctures is on (post-ARB Fz can reach ~40000)
# Longitudinal slip curve: the physical handle is WHERE grip peaks, not the raw Pacejka B.
# A tarmac tyre peaks at low slip (~12-15%); gravel peaks much later (~25-30%). The old fixed
# Bx=10 put the peak at 40% slip on EVERY surface, so reaching full drive force REQUIRED huge
# wheelspin. Bx is now derived from these peak locations and blended by surface grip.
@export var peak_slip_tarmac := 0.14         # slip ratio at peak longitudinal grip on asphalt
@export var peak_slip_gravel := 0.28         # slip ratio at peak longitudinal grip on dirt/grass
@export var Cx := 1.65
@export var Ex := 0.97
# B4: the lateral stiffness is DERIVED from where each surface peaks, exactly as Bx already is
# longitudinally. A tarmac tyre reaches peak lateral force at a small slip angle and lets go
# sharply; gravel peaks much later and slides progressively - that difference IS the "lean on it"
# gravel feel, and a single fixed By could never express it.
@export var peak_alpha_tarmac := 9.0        # deg of slip angle at peak lateral grip on asphalt
@export var peak_alpha_gravel := 16.0       # deg of slip angle at peak lateral grip on dirt/gravel
# B4: relaxation length - a tyre has to ROLL about sigma metres before its lateral force builds.
# Without it the car is darty: force appears the instant the wheel is steered, so there is no
# beat between turning in and the car taking a set, and a flick cannot be timed. Longitudinal
# already has natural lag through the wheel-spin ODE; this is the missing lateral half.
@export var sigma_lat := 0.55               # m, relaxation length (~1.6x wheel radius)
# C2 SELF-ALIGNING TORQUE - the steering signal, and the half of "force feedback" that is real
# physics rather than hardware. What a driver feels through the wheel is not "the car": it is the
# torque the front tyres exert about their own steering axis. Lateral force does not act at the
# contact centre, it acts BEHIND it by the pneumatic trail (the contact patch loads up
# asymmetrically, rearward-biased), and caster geometry adds a fixed mechanical trail on top:
#   Mz = Fy * (t_pneumatic + t_mechanical),  rack torque = sum(Mz) / steer_ratio
# THE POINT IS THE COLLAPSE, not the magnitude. As slip angle approaches the tyre's peak the
# contact patch slides at the rear and the pneumatic trail shrinks toward zero, so the wheel goes
# LIGHT just before the front washes out. That lightening arrives BEFORE the grip actually goes
# away, which makes it the single most informative cue a driver gets - more useful than raw force.
# A signal that only rises with cornering load carries no warning at all.
@export var trail_pneumatic := 0.03         # m, trail at zero slip (collapses toward 0 at the peak)
@export var trail_mechanical := 0.02        # m, fixed trail from caster geometry
@export var steer_ratio := 15.0             # steering ratio (wheel:road-wheel), divides wheel torque into rack torque
@export var sat_gain := 1.0                 # output scaling for the reported signal (0 = off)
# C2 REVISION: a steering system cannot transmit a one-tick impulse to the driver's hands. The
# column, rack and the driver's arms all have rotational inertia, so an 8 ms load spike is a tiny
# ANGULAR IMPULSE, not a jolt - measured 2026-08-27, the raw per-tick moment jumps >3 N.m on 23% of
# ticks on the rally loop, and 99.9% of those coincide with an Fz step over 1 kN as the tyre rides
# C2's zero-load floor and slams off it (never leaving the ground: contact loss explains only 0.2%).
# The load steps themselves are real and are NOT suppressed here - only the reported signal is
# filtered, by the mechanical low-pass a real steering system already is. A first-order lag passes
# steady cornering torque untouched and kills impulses, which is exactly the wanted behaviour.
@export var steer_filter_tau := 0.04        # s, steering-system response time (0 = raw, unfiltered)
# The Pacejka SHAPE factor: how sharply the lateral curve falls AFTER its peak. The curve settles
# at sin(C*pi/2) of peak at large slip - C 1.40 -> 0.81, C 1.20 -> 0.95 - so a lower C is a flatter,
# more forgiving tyre that keeps working when you overshoot the peak. Loose surfaces behave that
# way in reality: the gravel layer itself shears, which spreads the peak out instead of letting go
# cleanly. Splitting it per surface is what lets gravel forgive a slide WITHOUT moving the peak
# (which is what `peak_alpha_*` does) and without touching tarmac's sharper breakaway.
@export var Cy := 1.4                       # lateral curve shape on TARMAC
@export var cy_gravel := 1.4                # lateral curve shape on GRAVEL (lower = more forgiving
											# past the peak). Default matches Cy = today's car.
@export var Ey := 0.97
@export var roll_resist := 0.015

# --- Engine (A1: a real rotating inertia - it revs, bogs and stalls on its own dynamics) ---
@export var idle_rpm := 1000.0
@export var redline_rpm := 7200.0
@export var peak_torque := 500.0          # N*m
@export var peak_torque_rpm := 4300.0
@export var idle_torque_frac := 0.45      # WOT torque at idle rpm as a fraction of peak (an engine can't breathe at 1000 rpm)
@export var intake_tau := 0.07            # s: intake/manifold first-order lag between pedal and combustion torque
# Motoring friction T_fric(w) = c0 + c1*w is FIT through these two physical anchors - mechanical
# friction + pumping losses grow with rpm, so engine braking is emergent, not a constant.
# Defaults sit at the COMPETITION end of the band (high compression, aggressive closed-throttle
# pumping): a road 2.0 motors ~15/55, this unit ~25/90 - user found 55 barely felt in 3rd.
@export var engine_brake_idle := 25.0     # N*m motoring drag at idle
@export var engine_brake_redline := 90.0  # N*m motoring drag at redline
# Clutch (A1): capacity scales with engagement. Auto mode schedules engagement from rpm so a
# launch slips the clutch around bite_rpm and self-balances like a driver's foot.
@export var clutch_margin := 1.4          # clutch torque capacity as a multiple of peak engine torque
@export var bite_rpm := 1800.0            # auto-clutch is fully fed in by this rpm (slips below it to launch)
@export var anti_stall := true            # training wheel (default ON): dips the clutch as rpm falls toward stall
@export var manual_clutch := false        # LEFT SHIFT = clutch pedal (held = disengaged); stalling becomes possible
# A2: on a downshift the auto-clutch dips while a throttle blip spins the engine to the
# COMPUTED post-shift target (wheel speed through the new gear) - heel-toe, automated.
@export var auto_blip := true
# A4: a shift is an EVENT, not a teleport. shift_time is the whole manoeuvre: the auto-clutch
# dips, the dogs take the new ratio at the middle of the dip (so the plates are already open
# when it bites - the A2 heel-toe ordering), then the clutch feeds back in, blipping on a
# downshift. In manual-clutch mode the box still takes shift_time but the pedal is the driver's.
@export var shift_time := 0.18
# Money-shift guard: refuse an engagement whose COMPUTED post-shift engine speed would be past
# redline - the wheels are the boss once the plates are back in, so a 5th->2nd grab (or dropping
# into 1st at speed) would spin the crank to pieces. OFF = the overrev is allowed and costs
# mechanical damage through the existing M8 accumulator.
@export var overrev_guard := true
# --- A4 assists. Both default OFF: raw physics stays the tested baseline (anti-stall is the
# only assist that ships on). ---
# Launch assist: at a standstill in 1st it holds the engine at the COMPUTED peak-slip launch rpm
# and slips the clutch to keep the driven wheels at the surface's peak-grip slip ratio. It is
# the automation of manual clutch+throttle technique, not a separate physics path.
@export var launch_assist := false
# Stability assist (ESC): reference yaw rate from the bicycle model, corrected with a dab of
# outer-front brake. Both the wheelbase and the understeer gradient are read off the car.
@export var stability_assist := false
@export var stability_gain := 4000.0      # N*m of corrective brake torque per rad/s of excess yaw
@export var stability_margin := 0.20      # rad/s of yaw allowed BEYOND the bicycle-model reference

# --- Gearbox / AWD ---
@export var gear_ratios := [3.4, 2.25, 1.65, 1.3, 1.05, 0.86]
@export var reverse_ratio := 3.6
@export var final_drive := 3.9
@export var driveline_eff := 0.9
@export var torque_split := 0.6              # AWD centre diff: fraction of drive to the REAR (rally rear-bias)

# --- Slip-ratio drivetrain (dynamic: per-wheel spin + differential) ---
@export var wheel_inertia := 1.4             # kg*m^2 per wheel (tyre + rim)
@export var engine_inertia := 0.18           # kg*m^2 crank/driveline inertia, reflected through the gearing
@export var slip_ref_speed := 2.0            # m/s floor for the slip-ratio denominator (low-speed stability)
# --- A3 differentials: selectable per-axle type + a centre coupling for AWD ---
# Types: 0 = OPEN (tiny parasitic friction), 1 = VISCOUS (today's model: N*m per rad/s of
# inter-wheel speed difference), 2 = CLUTCH-PACK (Salisbury: lock capacity = preload +
# ramp * |axle input torque|, with separate POWER / COAST ramps - AC setup language),
# 3 = LOCKED (a clutch-pack with effectively infinite preload; one code path).
@export var front_diff_type: int = 1
@export var rear_diff_type: int = 1
@export var front_visc := 90.0               # viscous: N*m per rad/s (0 = open)
@export var rear_visc := 90.0
@export var front_preload := 60.0            # clutch-pack: N*m of always-there lock
@export var rear_preload := 60.0
@export var front_power_ramp := 0.35         # clutch-pack: lock per N*m of DRIVE torque (0..1)
@export var rear_power_ramp := 0.45
@export var front_coast_ramp := 0.20         # clutch-pack: lock per N*m of OVERRUN torque (0..1)
@export var rear_coast_ramp := 0.30
# Centre (AWD only): torque_split stays the epicyclic base split; this adds the speed-sensing
# element - torque migrates toward the slower axle when front/rear overspeed each other.
# 0/0 = today's fully-uncoupled feel (the phase starts neutral).
@export var centre_coupling := 0.0           # N*m per rad/s of front-rear average speed difference
@export var centre_preload := 0.0            # N*m of clutch preload across the centre
@export var brake_torque := 2600.0           # N*m max brake torque per wheel
@export var drive_substeps := 3              # sub-steps for the stiff wheel-spin ODE (120 Hz x 3 = 360 Hz driveline, same as old 60 x 6)
# weight bias toward the driven axle (m, forward = -Z): FWD carries weight forward (front grip),
# RWD carries it rearward (rear grip). AWD stays 50/50.
@export var fwd_bias := 0.4                  # FWD: metres the CoM shifts toward the front
@export var rwd_bias := 0.4                  # RWD: metres the CoM shifts toward the rear

# --- Traction control: OPTIONAL driver aid, default OFF (Tab panel toggle). Trims drive torque
# toward a target driven-wheel slip ratio. Layered ON TOP of the tyre/drivetrain model - the car
# must (and does) behave with it off; this is a rally-spec convenience, not a crutch.
@export var tc_enabled := false
@export var tc_slip_target := 0.35           # driven slip ratio TC allows before trimming torque
@export var tc_strength := 8.0               # torque trim rate (1/s per unit of slip error)

# --- Brakes ---
# The handbrake is its own line, not a multiple of the footbrake: a cable/hydraulic lever acts on
# the rear calipers alone. Default matches the pre-A5 effective torque (brake_torque x 1.0), so the
# lever feels exactly as it did - only the name is now honest. (A5 also retired `brake_force`, an
# unused M1 leftover, and `rear_grip_cut`, the magic-number lateral-grip hack - locked rears now
# lose grip through the friction ellipse, which is what a locked tyre actually does.)
@export var handbrake_torque := 2600.0       # N*m applied to each REAR wheel by the lever
# Rally hydraulic handbrakes disengage the centre diff so the rears can lock without dragging the
# front axle (and the whole drivetrain) with them - the reason an AWD car can rotate on the lever.
@export var handbrake_opens_centre := true
# Sliding tyres take their force DIRECTION from the slip velocity once past the friction ellipse
# (see the gross-sliding block in the force pass). Physically this should always be on; it is an
# export so it can be A/B'd against the old behaviour in one drive.
@export var slide_friction := true

# --- Steering / aero ---
@export var max_steer_deg := 34.0
@export var steer_rate := 2.6                # keyboard steering ramps in at this rate (1/s) - not instant 0/1
@export var steer_fast_rate := 6.0           # faster ramp while holding , or . (the < > keys)
@export var steer_return_rate := 4.5
@export var steer_analog_rate := 12.0        # gamepad stick: near-direct mapping (the stick's own motion smooths it)         # centering speed when no steer key is held
@export var steer_speed_falloff := 0.35

# --- Virtual pedals (input shaping): a binary key ramps like a real foot; an analog trigger bypasses it ---
@export var throttle_rise_time := 0.18       # s for the throttle pedal to travel 0->1 on a held key
@export var throttle_fall_time := 0.08       # s to lift off
@export var brake_rise_time := 0.12          # s for the brake pedal to press 0->1
@export var brake_fall_time := 0.08          # s to release
@export var drag_k := 0.7                # aero drag (lower = higher top speed / usable tall gears)
@export var shift_light_frac := 0.90     # fraction of redline where the cabin shift light starts flashing

var spawn_transform := Transform3D(Basis(), Vector3(0, 1.4, 0))

var _gear := 1                      # -1 = reverse, 0 = neutral, 1..6 forward (A1 remap)
var _engine_rpm := 1000.0
var _omega_e := 1000.0 * TAU / 60.0 # A1: engine angular velocity (rad/s) - THE engine state
var _t_comb := 0.0                  # A1: combustion torque after the intake lag (N*m)
var _clutch := 0.0                  # A1: clutch engagement 0 = open .. 1 = fully engaged
var _clutch_locked := false         # A1: true = engine follows the wheels kinematically (no slip)
var _stalled := false               # A1: engine dead; restart via [I], clutch-hold or bump-start
var _restart_t := 0.0               # A1: seconds the clutch has been held while stalled (starter timer)
var _dead_t := 0.0                  # A1: seconds the crank has been below the firing floor
var _blip_t := 0.0                  # A2: seconds left of the current downshift rev-match blip
var _ign_grace := 0.0               # A2: anti-stall grace after an [I] restart (the driver's reflex)
var _shift_t := 0.0                 # A4: seconds left of the current shift manoeuvre
var _shift_to := 1                  # A4: the gear the box is moving into
var _shift_pending := false         # A4: true until the ratio actually swaps (at mid-dip)
var _shift_down := false            # A4: this shift is a downshift (blip when it engages)
var _launch := false                # A4: launch assist is live (arms at rest, drops out once hooked up)
var _esc := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])   # A4: per-wheel stability-assist brake torque (N*m)
var _tc_scale := 1.0                # traction-control torque trim (1.0 = no trim)
var _engine_temp := 20.0            # M7: engine temperature (C) for the component HUD
var _damage := 0.0                  # M8: chassis damage 0 = pristine .. 1 = wrecked
var _pull_dir := 0.0                # M8: steering-pull direction from the last big lateral impact
var _prev_vel := Vector3.ZERO       # M8: last frame's velocity, for impact detection
var _steer := 0.0                 # smoothed steering (-1..1); keyboard ramps toward the key target
var _throttle_pedal := 0.0        # virtual throttle pedal (0..1), shaped from the binary key
var _brake_pedal := 0.0           # virtual brake pedal (0..1)
var _steer_wheel: Node3D          # cockpit steering wheel (spins with steering input)
var _rev_segs: Array = []         # cabin rev-bar segments: {mat, col}
var _shift_mat: StandardMaterial3D   # cabin shift-light material (flashes near the shift point)
var _cluster: Node3D              # the gauge cluster (dashboard.gd); the rev bar mounts on it
# B1: derived suspension rates, recomputed each tick so live slider edits and drive-mode CoM
# shifts both take effect immediately (see _derive_setup)
var _k_front := 24000.0
var _k_rear := 24000.0
var _ccrit_front := 5500.0        # 2*sqrt(k*m): the CRITICAL damping coefficient per corner.
var _ccrit_rear := 5500.0         # B2 scales it by zeta_bump / zeta_rebound at force time.
var _arb_f := 0.0
var _arb_r := 0.0
var _mc_front := 312.5            # derived static corner masses (kg), for the bump stops
var _mc_rear := 312.5
var _roll_grad := 0.0             # roll gradient the derived setup actually achieves (deg/g)
var _flash := 0.0                 # shift-light blink phase
var _drive_mode := 0              # 0 = AWD, 1 = RWD, 2 = FWD (cycle with T)
var _livery_mat: StandardMaterial3D
var _flare_mat: StandardMaterial3D
var surface_source               # set by world.gd; supplies grip_at(x,z) so asphalt grips > dirt > grass
var roughness_field               # set by world.gd; supplies sample_enveloped(x,z,heading) (C1)
var _sat_moment := 0.0            # C2: summed front-wheel Mz about the steering axis (N*m at the wheels)
var _sat_filt := 0.0              # C2: _sat_moment through the steering system's own inertia lag
const MODE_NAMES := ["AWD", "RWD", "FWD"]
const MODE_COLORS := [Color(0.16, 0.36, 0.82), Color(0.78, 0.13, 0.12), Color(0.16, 0.55, 0.26)]
# A1 clutch numerics (smoothing/actuation widths, not feel tunables - feel lives in the exports)
const CLUTCH_BAND := 8.0        # rad/s: Karnopp-style smoothing width of the slipping-clutch torque
const CLUTCH_LOCK_BAND := 12.0  # rad/s: speed window inside which a capable clutch locks up
const CLUTCH_IN_RATE := 12.0    # 1/s: engagement travel speed (auto feed-in / a dumped pedal ~80 ms)
const CLUTCH_OUT_RATE := 25.0   # 1/s: disengage travel speed (a foot stabs the clutch in faster)
# A2 auto-blip numerics: the rev TARGET is computed live (wheel speed through the new gear);
# these only bound the manoeuvre.
const BLIP_TIME := 0.4          # s: cap on one blip (give up and re-engage if the target is unreachable)
const BLIP_BAND := 40.0         # rad/s: throttle feathers off across this band as the target is reached
# A3 differential numerics (Karnopp smoothing widths, not feel tunables)
const DIFF_BAND := 1.0          # rad/s: smoothing width of a diff clutch's Coulomb transfer torque
const DIFF_OPEN_FRICTION := 5.0 # N*m: parasitic spider-gear friction of an OPEN diff
const DIFF_LOCKED_CAP := 10000.0 # N*m: "infinite" preload that implements LOCKED via the clutch path
# A5: how far past the friction ellipse a tyre must be before its force direction is fully handed
# over to the slip velocity (blend width in units of ellipse utilisation, not a feel tunable).
const SLIDE_BAND := 0.5
# B4's relaxation is deliberately per-DISTANCE (see below), which means it can barely move while
# the car is nearly stopped - so a slip angle built up during a slide (which can sit past the
# tyre's peak, 60-85 deg is common at gross slide) is still whatever it was tens of frames ago,
# even once the car's true geometry has gone back to nearly straight. The relaxed force is real
# physics while the tyre is actually rolling; it stops meaning anything once the tyre barely is.
const LOW_SPEED_LAT_FLOOR := 1.2   # m/s: wheel ground speed below which lateral (slip-angle) force
									# fades to zero, so a stale relaxed angle cannot keep shoving the
									# car sideways after it has essentially stopped
const VM_BAND := 0.4           # m/s: the gross-sliding direction blend fades out over this width as
								# the tyre's contact-patch slip speed nears zero, rather than the old
								# hard cut at 0.2 that produced a force/torque snap right at the
								# terminal instant of a slide (see the gross-sliding block below)
# A4 launch-assist numerics: the rpm the assist holds is COMPUTED (see _launch_setup); this is
# only the proportional band its throttle controller closes over, as a fraction of that rpm.
const LAUNCH_RPM_BAND := 0.08
# A3 evaluation presets ([1]/[2]/[3]): three points spanning the diff character range, so the
# difference can be felt corner-to-corner instead of reconstructed from single slider drags.
# Drive mode ([T]) is deliberately NOT part of a preset - the two axes stay independent, so
# any preset can be tried in AWD / RWD / FWD (the centre entries only bite in AWD).
const DIFF_PRESET_KEYS := ["diff_preset_1", "diff_preset_2", "diff_preset_3"]
const DIFF_PRESETS := [
	# [1] OPEN: no lock anywhere. The reference for what a diff DOES - the unloaded inside
	# wheel takes the torque and spins, so a hairpin exit washes wide.
	{"name": "OPEN",
		"front_diff_type": 0, "rear_diff_type": 0,
		"front_visc": 0.0, "rear_visc": 0.0,
		"front_preload": 0.0, "rear_preload": 0.0,
		"front_power_ramp": 0.0, "rear_power_ramp": 0.0,
		"front_coast_ramp": 0.0, "rear_coast_ramp": 0.0,
		"centre_coupling": 0.0, "centre_preload": 0.0},
	# [2] VISCOUS: speed-sensing lock only - this is the pre-A3 car, the familiar baseline.
	{"name": "VISCOUS",
		"front_diff_type": 1, "rear_diff_type": 1,
		"front_visc": 90.0, "rear_visc": 90.0,
		"front_preload": 0.0, "rear_preload": 0.0,
		"front_power_ramp": 0.0, "rear_power_ramp": 0.0,
		"front_coast_ramp": 0.0, "rear_coast_ramp": 0.0,
		"centre_coupling": 0.0, "centre_preload": 0.0},
	# [3] RALLY: torque-sensing Salisbury plates + a coupled centre - a gravel car's setup.
	# Rear locks hard on power (traction, throttle-steering) and part-opens on coast; the front
	# runs a LOW power ramp on purpose (front lock fights the steering) but real coast lock for
	# entry stability. Centre coupling migrates torque to whichever axle still has grip.
	{"name": "RALLY",
		"front_diff_type": 2, "rear_diff_type": 2,
		"front_visc": 0.0, "rear_visc": 0.0,
		"front_preload": 60.0, "rear_preload": 120.0,
		"front_power_ramp": 0.25, "rear_power_ramp": 0.70,
		"front_coast_ramp": 0.35, "rear_coast_ramp": 0.35,
		"centre_coupling": 120.0, "centre_preload": 60.0},
]

class Wheel:
	var pos: Vector3
	var steer: bool
	var drive: bool
	var vis: MeshInstance3D
	var contact := false
	var contact_point := Vector3.ZERO   # world-space tire contact (for terrain deformation / tracks)
	var contact_normal := Vector3.UP
	var Fz := 0.0
	var kappa := 0.0
	var slip_angle := 0.0               # instantaneous (steady-state) slip angle
	var alpha_rel := 0.0                # B4: RELAXED slip angle - what the tyre force actually follows
	var slip := 0.0                     # slip ratio magnitude (for terrain dig / dust / tracks)
	var util := 0.0
	var spin := 0.0                     # accumulated visual roll angle
	var omega := 0.0                    # wheel angular velocity (rad/s) - the drivetrain state
	var comp := 0.0                     # suspension compression (m) - for the anti-roll bars
	var bottomed := false               # B3: a bump stop is engaged this frame (M7 puncture trigger)
	var temp := 20.0                    # M7: tyre core temperature (C)
	var tyre_wear := 0.0                # M7: wear 0 = new .. 1 = worn out
	var punctured := false              # M7: blown / flat -> big grip loss
	var tyre_grip := 1.0                # M7: temp * wear * puncture grip multiplier (folds into mu)

var _wheels: Array[Wheel] = []

func _ready() -> void:
	mass = chassis_mass
	gravity_scale = 1.0         # real gravity; air time is controlled by the (subtle) jump geometry
	# Godot's project-wide default_linear_damp (0.1) is ADDED to the body's own value in COMBINE
	# mode, applying mass*damp*v of resistance - 2138 N at 62 km/h against an aero drag of 205 N,
	# and it grows only LINEARLY with speed so it never stops mattering. This car models its own
	# aero (drag_k) and rolling resistance, so that generic damping was pure double-counting: it
	# capped the car near 130 km/h and made the tall gears feel powerless, because in 6th the
	# engine cannot out-push it. Replace it rather than combine, and let the vehicle's own
	# longitudinal model be the only thing slowing the car down.
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	can_sleep = false
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, com_height, 0)
	collision_layer = 2
	collision_mask = 1 | 4
	var pm := PhysicsMaterial.new(); pm.friction = 0.3
	physics_material_override = pm
	_build_body()
	_build_wheels()
	respawn()
	_apply_mode()               # the car now casts a real (sun/directional) shadow again

func _damper_force(vel: float, c_crit: float) -> float:
	# B2: piecewise-linear in damper velocity, built from four physical parameters.
	# Direction picks the damping ratio (bump vs rebound); the knee splits the curve into a stiff
	# low-speed region that controls the body and a soft high-speed region that swallows impacts.
	# Setting zeta_bump == zeta_rebound and hs_blowoff == 1.0 reproduces B1's linear damper exactly,
	# which is the A/B that proves what this phase bought.
	var z: float = zeta_bump if vel >= 0.0 else zeta_rebound
	var c := z * c_crit
	var a := absf(vel)
	var knee := maxf(knee_speed, 0.001)
	var f: float = c * a if a <= knee else c * knee + c * clampf(hs_blowoff, 0.0, 1.0) * (a - knee)
	return f * signf(vel)

func _derive_setup() -> void:
	# B1: turn the three physical targets into the rates the suspension pass actually uses.
	# Corner masses follow the CoM, INCLUDING the per-drive-mode z-shift, so switching to FWD
	# genuinely loads the front axle and re-rates its springs rather than just moving the CoM.
	var g := 9.81
	var zf: float = _wheels[0].pos.z
	# chassis_mass is the one authority for how heavy the car is: corner masses, the roll gradient,
	# the tyre load reference (_mu_load) and rolling resistance all derive from it, so the physics
	# body has to follow it rather than drift (a live slider edit re-rates the whole car).
	if not is_equal_approx(mass, chassis_mass):
		mass = chassis_mass
	var zr: float = _wheels[2].pos.z
	var com_z := _com_bias()
	var la := absf(com_z - zf)                    # CoM -> front axle
	var lb := absf(zr - com_z)                    # CoM -> rear axle
	var wb := maxf(la + lb, 0.01)                 # wheelbase
	# each axle carries the share proportional to the OPPOSITE lever arm; halve for one corner
	var m_cf := chassis_mass * (lb / wb) * 0.5
	var m_cr := chassis_mass * (la / wb) * 0.5
	var wf := TAU * maxf(ride_freq_front, 0.1)
	var wr := TAU * maxf(ride_freq_rear, 0.1)
	_mc_front = m_cf
	_mc_rear = m_cr
	_k_front = m_cf * wf * wf
	_k_rear = m_cr * wr * wr
	# critical damping per corner; the damping RATIOS are applied per-direction in _damper_force
	_ccrit_front = 2.0 * sqrt(maxf(_k_front * m_cf, 0.0))
	_ccrit_rear = 2.0 * sqrt(maxf(_k_rear * m_cr, 0.0))
	# CoM height above the CONTACT plane at static ride height - the lever the roll moment acts on
	var comp_f := m_cf * g / maxf(_k_front, 1.0)
	var comp_r := m_cr * g / maxf(_k_rear, 1.0)
	var ground_y := _wheels[0].pos.y - (rest_length + wheel_radius) + (comp_f + comp_r) * 0.5
	var h := maxf(center_of_mass.y - ground_y, 0.05)
	var track := maxf(absf(_wheels[0].pos.x - _wheels[1].pos.x), 0.01)
	# roll moment per g, and the total roll stiffness that meets the target gradient
	var m_per_g := chassis_mass * g * h
	var k_need := m_per_g / maxf(deg_to_rad(roll_gradient_target), 0.0001)
	# springs already resist roll: two at +/- track/2 give k*track^2/2 of roll stiffness each axle
	var k_sf := _k_front * track * track * 0.5
	var k_sr := _k_rear * track * track * 0.5
	# ROLL COUPLE FIRST. This is the balance handle, and it decides which end's INSIDE wheel goes
	# light in a corner - which on the driven axle is the difference between a tyre that works and
	# one that spins itself hot. Flat-ride tuning puts the stiffer spring at the REAR, so the
	# springs alone hand the rear a bigger share of the load transfer; sizing the bars only to hit
	# the roll-gradient target left this uncontrolled (measured 43% front in AWD and 34% in RWD
	# against a 55% setting, cooking the inside rear). A bar can only ADD stiffness, so the axle
	# that is short of its share gets the bar.
	var rcf := clampf(roll_couple_front, 0.05, 0.95)
	var b_f := 0.0
	var b_r := 0.0
	if k_sf * (1.0 - rcf) < k_sr * rcf:
		b_f = rcf * k_sr / (1.0 - rcf) - k_sf      # front is short of its share
	else:
		b_r = (1.0 - rcf) * k_sf / rcf - k_sr      # rear is
	# only once the balance is right does the roll GRADIENT get a say: if the car is still softer
	# in roll than the target, stiffen both ends in the ratio that preserves the couple.
	var k_tot := k_sf + b_f + k_sr + b_r
	if k_tot < k_need:
		var extra := k_need - k_tot
		b_f += extra * rcf
		b_r += extra * (1.0 - rcf)
	_arb_f = maxf(b_f, 0.0) / (track * track)
	_arb_r = maxf(b_r, 0.0) / (track * track)
	_roll_grad = rad_to_deg(m_per_g / maxf(k_sf + k_sr + (_arb_f + _arb_r) * track * track, 1.0))

func _com_bias() -> float:
	if _drive_mode == 1: return rwd_bias      # RWD: weight rearward
	if _drive_mode == 2: return -fwd_bias     # FWD: weight forward
	return 0.0                                # AWD: centred

func _apply_arb(i: int, j: int, k: float) -> void:
	# move vertical load toward the more-compressed (outer) wheel to resist roll; the extra load
	# polarisation lowers that axle's grip via load sensitivity -> stiffer front = understeer, etc.
	var a: Wheel = _wheels[i]
	var b: Wheel = _wheels[j]
	if not (a.contact and b.contact):
		return
	var t := clampf(k * (a.comp - b.comp), -a.Fz, b.Fz)   # never push either wheel below zero load
	a.Fz = a.Fz + t
	b.Fz = b.Fz - t

func _apply_mode() -> void:
	center_of_mass = Vector3(0, com_height, _com_bias())   # shift weight toward the driven axle
	if _livery_mat != null:
		_livery_mat.albedo_color = MODE_COLORS[_drive_mode]
	if _flare_mat != null:
		_flare_mat.albedo_color = MODE_COLORS[_drive_mode].darkened(0.28)

func _rev_color(t: float) -> Color:
	if t < 0.5: return Color(0.15, 0.9, 0.15)      # green
	if t < 0.78: return Color(0.95, 0.82, 0.1)     # yellow
	return Color(0.95, 0.12, 0.1)                  # red (redline zone)

func _build_revbar() -> void:
	# shift-light strip across the TOP of the gauge cluster's screen, like the LED bar on a real
	# racing display: segments light green->yellow->red with rpm, plus a flashing shift light at
	# the end. Mounted ON the cluster (dashboard.gd), so it inherits the pod's position and tilt
	# and can never drift into the dials - one thing to move, not two.
	var host: Node3D = _cluster if _cluster != null else self
	var n := 14
	var seg_w := 0.015
	var gap := 0.0035
	var total := n * seg_w + (n - 1) * gap
	var y := 0.062         # just inside the top edge of the screen
	var z := 0.007         # a hair proud of the screen face
	var x0 := -total * 0.5
	for i in range(n):
		var col := _rev_color(float(i) / float(n - 1))
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = col.darkened(0.8)         # dim when unlit
		var seg := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = Vector3(seg_w, 0.019, 0.004)
		seg.mesh = bm
		seg.material_override = m
		seg.position = Vector3(x0 + i * (seg_w + gap) + seg_w * 0.5, y, z)
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		host.add_child(seg)
		_rev_segs.append({"mat": m, "col": col})
	# shift light: a red disc at the end of the strip, flashes near the shift point
	_shift_mat = StandardMaterial3D.new()
	_shift_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shift_mat.albedo_color = Color(0.2, 0.0, 0.0)
	var light := MeshInstance3D.new()
	var cyl := CylinderMesh.new(); cyl.top_radius = 0.010; cyl.bottom_radius = 0.010; cyl.height = 0.004
	light.mesh = cyl
	light.material_override = _shift_mat
	light.position = Vector3(total * 0.5 + 0.015, y, z)
	light.rotation_degrees = Vector3(90, 0, 0)     # flat face toward the driver
	light.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host.add_child(light)

func _build_cluster() -> void:
	# in-cabin gauge cluster (analog tacho + speedo + numeric gear) - see scripts/dashboard.gd.
	# It reads the car through get_engine(), so it needs no wiring beyond this reference.
	var dash: Node3D = load("res://scripts/dashboard.gd").new()
	dash.name = "GaugeCluster"
	dash.car = self
	add_child(dash)
	_cluster = dash

func _build_body() -> void:
	# Physics collision stays a single box; all the detail below is cosmetic (forward = -Z).
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new(); box.size = body_size
	col.shape = box; add_child(col)
	_build_shell()
	_build_cockpit()
	_build_cluster()
	_build_revbar()
	# NOTE: no in-cabin 3D mirror quad -- a ViewportTexture renders black on a 3D surface on Metal.
	# The functional rear-view is drawn as a 2D SubViewportContainer overlay in world.gd instead.

func _mat(c: Color, emissive := false, metallic := 0.0, rough := 0.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metallic
	m.roughness = rough
	if emissive:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = 1.7
	return m

func _glass_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.08, 0.12, 0.16, 0.18)     # light tint, see-through from cockpit
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.metallic = 0.5
	m.roughness = 0.08
	return m

func _part(size: Vector3, pos: Vector3, mat: StandardMaterial3D, rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	if rot_deg != Vector3.ZERO:
		mi.rotation_degrees = rot_deg
	add_child(mi)
	return mi

func _cyl(radius: float, height: float, pos: Vector3, mat: StandardMaterial3D, rot_deg := Vector3.ZERO, sides := 16) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius; cm.bottom_radius = radius; cm.height = height; cm.radial_segments = sides
	mi.mesh = cm
	mi.material_override = mat
	mi.position = pos
	if rot_deg != Vector3.ZERO:
		mi.rotation_degrees = rot_deg
	add_child(mi)
	return mi

func _build_shell() -> void:
	# Stylised '97 Impreza WRC (interim procedural model). Cabin stays hollow so the cockpit
	# camera sees out. Metallic paint + rounder fenders + detail parts. Forward = -Z.
	var paint := _mat(livery_color, false, 0.5, 0.28)          # metallic WR Blue
	_livery_mat = paint                                       # shared by body parts -> recolour per drive mode
	var flare := _mat(livery_color.darkened(0.28), false, 0.4, 0.4)
	_flare_mat = flare
	var dark := _mat(Color(0.05, 0.05, 0.06), false, 0.25, 0.5)
	var chrome := _mat(Color(0.72, 0.73, 0.78), false, 0.9, 0.16)
	var glass := _glass_mat()
	var yellow := _mat(accent_color, false, 0.3, 0.35)
	var red := _mat(Color(0.85, 0.06, 0.04), true)
	var headl := _mat(Color(0.9, 0.95, 1.0), true)
	var fog := _mat(Color(0.95, 0.96, 0.9), true)
	# body tub + sloped hood + intercooler scoop
	_part(Vector3(1.7, 0.46, 4.1), Vector3(0, 0.05, 0), paint)
	_part(Vector3(1.56, 0.11, 1.32), Vector3(0, 0.3, -1.32), paint, Vector3(-4, 0, 0))
	_part(Vector3(0.5, 0.1, 0.46), Vector3(0, 0.4, -1.22), dark)
	_part(Vector3(0.4, 0.05, 0.3), Vector3(0, 0.45, -1.16), _mat(Color(0.01, 0.01, 0.01)))
	_part(Vector3(1.58, 0.11, 1.0), Vector3(0, 0.4, 1.5), paint)          # trunk deck
	# hollow cabin: thin doors + seam + floor
	for sx in [-0.81, 0.81]:
		_part(Vector3(0.06, 0.3, 1.8), Vector3(float(sx), 0.44, 0.12), paint)
		_part(Vector3(0.065, 0.02, 1.7), Vector3(float(sx), 0.5, 0.12), dark)
	_part(Vector3(1.5, 0.05, 1.9), Vector3(0, 0.3, 0.12), dark)
	# flat roof; the rear section kicks UP slightly toward the back so it clears the rear seats
	_part(Vector3(1.4, 0.1, 1.2), Vector3(0, 0.98, -0.05), paint)                        # main roof (flat)
	_part(Vector3(1.36, 0.09, 0.55), Vector3(0, 1.0, 0.68), paint, Vector3(-12, 0, 0))   # rear roof slopes up
	# glazing
	_part(Vector3(1.44, 0.72, 0.05), Vector3(0, 0.68, -0.58), glass, Vector3(32, 0, 0))   # windshield (taller)
	_part(Vector3(1.34, 0.8, 0.05), Vector3(0, 0.73, 0.88), glass, Vector3(-47, 0, 0))     # big rear windshield revealed
	for sx in [-0.79, 0.79]:
		_part(Vector3(0.04, 0.42, 0.6), Vector3(float(sx), 0.69, -0.25), glass)
		_part(Vector3(0.04, 0.42, 0.5), Vector3(float(sx), 0.69, 0.5), glass)
	# pillars A/B/C (taller, reaching the higher roofline)
	for sx in [-0.75, 0.75]:
		_part(Vector3(0.08, 0.74, 0.08), Vector3(float(sx), 0.63, -0.5), paint, Vector3(32, 0, 0))
		_part(Vector3(0.07, 0.52, 0.07), Vector3(float(sx), 0.67, 0.16), paint)
		_part(Vector3(0.08, 0.72, 0.08), Vector3(float(sx), 0.64, 0.82), paint, Vector3(-44, 0, 0))
	# door mirrors
	for sx in [-0.84, 0.84]:
		_part(Vector3(0.06, 0.03, 0.1), Vector3(float(sx), 0.6, -0.34), dark)
		_part(Vector3(0.11, 0.08, 0.05), Vector3(float(sx) * 1.08, 0.62, -0.31), paint)
	# bumpers + splitter
	_part(Vector3(1.74, 0.34, 0.3), Vector3(0, 0.02, -2.0), dark)
	_part(Vector3(1.86, 0.05, 0.36), Vector3(0, -0.18, -2.06), dark)
	_part(Vector3(1.74, 0.34, 0.28), Vector3(0, 0.04, 2.0), dark)
	# lights: headlights + round driving lights + taillights
	_part(Vector3(0.36, 0.15, 0.05), Vector3(-0.55, 0.26, -2.0), headl)
	_part(Vector3(0.36, 0.15, 0.05), Vector3(0.55, 0.26, -2.0), headl)
	for lx in [-0.4, -0.14, 0.14, 0.4]:
		_cyl(0.075, 0.05, Vector3(float(lx), 0.02, -2.08), fog, Vector3(90, 0, 0), 12)
	_part(Vector3(0.34, 0.15, 0.05), Vector3(-0.58, 0.24, 2.03), red)
	_part(Vector3(0.34, 0.15, 0.05), Vector3(0.58, 0.24, 2.03), red)
	# twin exhaust
	_cyl(0.05, 0.16, Vector3(-0.4, -0.14, 2.1), chrome, Vector3(90, 0, 0), 12)
	_cyl(0.05, 0.16, Vector3(-0.24, -0.14, 2.1), chrome, Vector3(90, 0, 0), 12)
	# rounded fender flares (block + angled top over each wheel)
	for fx in [-0.85, 0.85]:
		for fz in [-1.35, 1.35]:
			_part(Vector3(0.28, 0.24, 0.92), Vector3(float(fx), 0.03, float(fz)), flare)
			_part(Vector3(0.22, 0.12, 0.96), Vector3(float(fx) * 1.03, 0.2, float(fz)), flare, Vector3(0, 0, -34.0 * signf(fx)))
	# rear wing on struts, yellow endplates
	_part(Vector3(0.06, 0.3, 0.06), Vector3(-0.52, 0.6, 1.74), dark)
	_part(Vector3(0.06, 0.3, 0.06), Vector3(0.52, 0.6, 1.74), dark)
	_part(Vector3(1.58, 0.05, 0.42), Vector3(0, 0.76, 1.8), dark)
	_part(Vector3(0.04, 0.16, 0.42), Vector3(-0.81, 0.72, 1.8), yellow)
	_part(Vector3(0.04, 0.16, 0.42), Vector3(0.81, 0.72, 1.8), yellow)
	# 555-style yellow lower stripe
	for sx in [-0.87, 0.87]:
		_part(Vector3(0.03, 0.11, 2.7), Vector3(float(sx), 0.14, 0.1), yellow)

func _build_cockpit() -> void:
	# Driver on the LEFT (-x) for now. Low dash so the view clears it.
	var dash := _mat(Color(0.04, 0.04, 0.05), false, 0.0, 0.95)
	_part(Vector3(1.5, 0.14, 0.44), Vector3(0, 0.47, -0.42), dash, Vector3(12, 0, 0))
	# binnacle bump the gauge cluster stands on. It has to stay BEHIND the cluster's own pod
	# (dashboard.gd, tilted -24 deg at z -0.205) - at its old size its top-front edge came
	# through the screen face. If the cluster ever moves, re-check this box against it.
	_part(Vector3(0.34, 0.10, 0.16), Vector3(-0.35, 0.515, -0.33), _mat(Color(0.02, 0.02, 0.03)), Vector3(16, 0, 0))
	# seats: driver (blue bucket, left) + co-driver (right)
	_part(Vector3(0.42, 0.5, 0.2), Vector3(-0.35, 0.44, 0.55), _mat(Color(0.1, 0.2, 0.5)))
	_part(Vector3(0.42, 0.5, 0.2), Vector3(0.35, 0.44, 0.55), _mat(Color(0.12, 0.12, 0.14)))
	# roll cage up at the roofline (frames the view, doesn't cross it)
	var cage := _mat(Color(0.82, 0.82, 0.86), false, 0.6, 0.3)
	_part(Vector3(0.05, 0.05, 1.8), Vector3(-0.74, 0.8, 0.2), cage)
	_part(Vector3(0.05, 0.05, 1.8), Vector3(0.74, 0.8, 0.2), cage)
	_part(Vector3(1.44, 0.05, 0.05), Vector3(0, 0.8, 0.72), cage)   # rear hoop only (out of forward view)
	# --- steering wheel (LHD for now), spins with steering input ---
	var column := Node3D.new()
	column.position = Vector3(-0.35, 0.46, 0.02)
	column.rotation_degrees = Vector3(-26, 0, 0)      # tilt back toward the driver
	add_child(column)
	_steer_wheel = Node3D.new()
	column.add_child(_steer_wheel)
	var rim := MeshInstance3D.new()
	var torus := TorusMesh.new(); torus.inner_radius = 0.115; torus.outer_radius = 0.145
	rim.mesh = torus
	rim.rotation_degrees = Vector3(90, 0, 0)          # stand the ring up to face the driver
	rim.material_override = _mat(Color(0.03, 0.03, 0.03), false, 0.1, 0.5)
	_steer_wheel.add_child(rim)
	var spoke := _mat(Color(0.06, 0.06, 0.07), false, 0.3, 0.4)
	var hbar := MeshInstance3D.new()
	var hb := BoxMesh.new(); hb.size = Vector3(0.27, 0.025, 0.02); hbar.mesh = hb
	hbar.material_override = spoke; _steer_wheel.add_child(hbar)
	var lbar := MeshInstance3D.new()
	var lb := BoxMesh.new(); lb.size = Vector3(0.025, 0.13, 0.02); lbar.mesh = lb
	lbar.position = Vector3(0, -0.065, 0); lbar.material_override = spoke; _steer_wheel.add_child(lbar)
	var hub := MeshInstance3D.new()
	var hbx := BoxMesh.new(); hbx.size = Vector3(0.08, 0.08, 0.06); hub.mesh = hbx
	hub.material_override = _mat(accent_color); _steer_wheel.add_child(hub)

func _build_wheels() -> void:
	var defs := [
		[Vector3(-0.82, -0.1, -1.35), true,  true],
		[Vector3( 0.82, -0.1, -1.35), true,  true],
		[Vector3(-0.82, -0.1,  1.35), false, true],
		[Vector3( 0.82, -0.1,  1.35), false, true],
	]
	for d in defs:
		var w := Wheel.new()
		w.pos = d[0]; w.steer = d[1]; w.drive = d[2]
		var vis := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = wheel_radius; cyl.bottom_radius = wheel_radius; cyl.height = 0.26; cyl.radial_segments = 24
		vis.mesh = cyl
		var tire := StandardMaterial3D.new(); tire.albedo_color = Color(0.05, 0.05, 0.06); tire.roughness = 0.9
		vis.material_override = tire
		var gold := _mat(Color(0.85, 0.68, 0.22), false, 0.85, 0.25)              # iconic gold rim
		# dark backing disc + 5 gold spokes + centre cap = spoked rally wheel
		var back := MeshInstance3D.new()
		var bc := CylinderMesh.new(); bc.top_radius = 0.2; bc.bottom_radius = 0.2; bc.height = 0.27; bc.radial_segments = 24
		back.mesh = bc; back.material_override = _mat(Color(0.1, 0.1, 0.11), false, 0.3, 0.5)
		vis.add_child(back)
		for s in range(5):
			var a := float(s) * TAU / 5.0
			var sp := MeshInstance3D.new()
			var sbm := BoxMesh.new(); sbm.size = Vector3(0.16, 0.28, 0.04)
			sp.mesh = sbm; sp.material_override = gold
			sp.position = Vector3(cos(a) * 0.095, 0.0, sin(a) * 0.095)
			sp.rotation.y = -a
			vis.add_child(sp)
		var cap := MeshInstance3D.new()
		var cc := CylinderMesh.new(); cc.top_radius = 0.05; cc.bottom_radius = 0.05; cc.height = 0.29; cc.radial_segments = 12
		cap.mesh = cc; cap.material_override = gold
		vis.add_child(cap)
		add_child(vis); w.vis = vis
		_wheels.append(w)

func _mu_load(mu0: float, Fz: float) -> float:
	# tire grip coefficient drops as vertical load rises (load sensitivity) -> the total grip
	# gained from weight transfer is less than linear, which sharpens the limit and rewards balance.
	var fz_ref := chassis_mass * 9.81 * 0.25
	return mu0 * clampf(1.0 - load_sensitivity * (Fz / maxf(fz_ref, 1.0) - 1.0), 0.55, 1.15)

func _mf(slip: float, B: float, C: float, E: float, D: float) -> float:
	var bs := B * slip
	return D * sin(C * atan(bs - E * (bs - atan(bs))))

func _mf_slope(slip: float, B: float, C: float, E: float, D: float) -> float:
	# analytic dF/dslip of _mf - used to linearise the tyre in the wheel-spin ODE (implicit term)
	var u := B * slip
	var phi := (1.0 - E) * u + E * atan(u)
	var dphi := (1.0 - E) + E / (1.0 + u * u)
	return D * cos(C * atan(phi)) * C / (1.0 + phi * phi) * dphi * B

func _mf_peak_u(C: float, E: float) -> float:
	# solve for u = B*slip where _mf peaks (C*atan(phi(u)) = pi/2), so B can be DERIVED from a
	# desired peak-slip location instead of hand-tuning it: B = u_star / peak_slip
	var target := tan(PI / (2.0 * maxf(C, 1.01)))
	var lo := 0.0
	# The bracket has to SCALE WITH C: u* grows fast as C falls (C 1.65 -> ~4, 1.40 -> ~20,
	# 1.20 -> ~73, 1.10 -> ~181), and a fixed upper bound silently clamps the solve, which puts
	# the derived B - and therefore the force peak - in the wrong place with nothing to show for
	# it. For large u the equation is dominated by the linear term, so (target - E*pi/2)/(1-E) is
	# a close analytic estimate of where the root sits; bracket generously above it.
	var hi := 60.0
	if E < 0.999:
		hi = maxf(hi, (target - E * PI * 0.5) / (1.0 - E) * 1.5 + 20.0)
	for _i in range(40):
		var mid := 0.5 * (lo + hi)
		if (1.0 - E) * mid + E * atan(mid) < target:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)

func _update_tyre(w: Wheel, Fx: float, Fy: float, v_long: float, v_lat: float, dt: float) -> void:
	if not tyres_enabled:
		w.tyre_grip = 1.0
		w.bottomed = false
		return
	# heat = friction power dissipated at the contact (force x sliding speed), both axes
	var slide_long := absf(w.omega * wheel_radius - v_long)
	var power := absf(Fx) * slide_long + absf(Fy) * absf(v_lat)
	w.temp += tyre_heat_rate * power * dt
	# cooling toward ambient, faster with airflow (speed)
	var airflow := 1.0 + linear_velocity.length() / 30.0
	w.temp += (ambient_temp - w.temp) * tyre_cool_rate * airflow * dt
	# wear from tyre work, accelerated when overheated
	var work := absf(w.slip) + absf(w.slip_angle)
	var hot := 1.0 + maxf(0.0, (w.temp - optimal_temp) / 50.0)
	w.tyre_wear = clampf(w.tyre_wear + tyre_wear_rate * work * hot * dt, 0.0, 1.0)
	# puncture: blowout when fully worn; optional hard-hit puncture (off by default - Fz is ARB-inflated)
	if w.tyre_wear >= 1.0 or (impact_punctures and w.Fz >= puncture_load):
		w.punctured = true
	# resulting grip multiplier (used by next frame's mu)
	w.tyre_grip = puncture_grip if w.punctured else _temp_grip(w.temp) * _wear_grip(w.tyre_wear)

func _temp_grip(temp: float) -> float:
	# grip peaks at optimal_temp; rises from cold_grip when cold, falls to overheat_grip when hot
	if temp <= optimal_temp:
		var t := clampf((temp - ambient_temp) / maxf(optimal_temp - ambient_temp, 1.0), 0.0, 1.0)
		return lerpf(cold_grip, 1.0, t)
	var h := clampf((temp - optimal_temp) / maxf(temp_grip_window, 1.0), 0.0, 1.0)
	return lerpf(1.0, overheat_grip, h)

func _wear_grip(wear: float) -> float:
	return lerpf(1.0, worn_grip, clampf(wear, 0.0, 1.0))

func _engine_torque(rpm: float) -> float:
	# torque curve: peaks at peak_torque_rpm, tapers off both sides (power band).
	# Below the peak the intake can't fill the cylinders, so the curve is anchored to
	# idle_torque_frac at idle rpm - the old fixed parabola made 68% of peak at 1000 rpm,
	# which is why standstill launches dumped near-full torque before the engine even revved.
	if rpm < idle_rpm * 0.5:
		return 0.0
	var x := clampf(rpm, 0.0, redline_rpm) / peak_torque_rpm
	var shape: float
	if x < 1.0:
		var x_idle := idle_rpm / peak_torque_rpm
		var k_low := (1.0 - idle_torque_frac) / maxf((1.0 - x_idle) * (1.0 - x_idle), 0.0001)
		shape = clampf(1.0 - k_low * (1.0 - x) * (1.0 - x), idle_torque_frac, 1.0)
	else:
		shape = clampf(1.0 - 0.55 * (x - 1.0) * (x - 1.0), 0.35, 1.0)
	return peak_torque * shape

func top_speed_kmh() -> float:
	# The speed the car can ACTUALLY reach: where the top gear's drive force is finally balanced
	# by aero drag plus rolling resistance. Not the same thing as redline in top gear, which is
	# only what the GEARING would allow - a car is drag-limited long before that unless it is
	# very overpowered, and the motoring friction (engine_brake_*) eats into the drive force too.
	# Used to graduate the speedometers, so the dial matches what the car can do.
	var gr: float = float(gear_ratios[gear_ratios.size() - 1]) * final_drive
	if gr <= 0.01:
		return 0.0
	var w_idle := idle_rpm * TAU / 60.0
	var w_red := redline_rpm * TAU / 60.0
	var c1 := (engine_brake_redline - engine_brake_idle) / maxf(w_red - w_idle, 1.0)
	var c0 := engine_brake_idle - c1 * w_idle
	var f_roll := roll_resist * chassis_mass * 9.81
	# March DOWN from redline-in-top-gear and take the first speed the car can still pull. Going
	# the other way does not work: in top gear at walking pace the engine is below idle and makes
	# no torque at all, so an upward sweep quits on its first step and reports zero.
	var v := w_red * maxf(wheel_radius, 0.01) / gr
	while v > 1.0:
		var w_e: float = v / maxf(wheel_radius, 0.01) * gr
		var t_net: float = _engine_torque(w_e * 60.0 / TAU) - maxf(c0 + c1 * w_e, 0.0)
		var f_drive: float = t_net * gr * driveline_eff / maxf(wheel_radius, 0.01)
		if f_drive >= drag_k * v * v + f_roll:
			return v * 3.6
		v -= 0.5
	return 0.0

func _rpm_for_torque(t_need: float) -> float:
	# invert _engine_torque on its LOW branch: the lowest rpm that can actually deliver t_need.
	# (Past peak_torque_rpm there is no more torque to find, so it saturates there.)
	var s := clampf(t_need / maxf(peak_torque, 1.0), 0.0, 1.0)
	if s <= idle_torque_frac:
		return idle_rpm
	var x_idle := idle_rpm / maxf(peak_torque_rpm, 1.0)
	var k_low := (1.0 - idle_torque_frac) / maxf((1.0 - x_idle) * (1.0 - x_idle), 0.0001)
	var x := 1.0 - sqrt(maxf(1.0 - s, 0.0) / k_low)
	return clampf(x * peak_torque_rpm, idle_rpm, peak_torque_rpm)

func _driven_avg(split: float) -> Vector2:
	# (signed average spin of the torque-receiving wheels, how many they are) - the gearbox's
	# wheel-side speed, and the divisor the slipping clutch's slope is shared across
	var s := 0.0
	var n := 0.0
	for w in _wheels:
		var sh: float = (1.0 - split) if w.steer else split
		if sh > 0.001:
			s += w.omega
			n += 1.0
	return Vector2(s / maxf(n, 1.0), n)

func _launch_setup(split: float, ratio: float, t_fric: float) -> Vector2:
	# A4 launch assist targets, BOTH derived: (target driven-wheel slip ratio, launch rpm).
	# The slip target is the surface's peak-grip slip under the driven wheels - the same
	# tarmac/gravel blend that derives the Pacejka Bx, so "launch at peak slip" means exactly
	# that. The launch rpm is then the engine speed that can hold the wheels there WITHOUT sagging:
	# the grip-limited wheel torque (the Magic Formula's D at that peak) reflected up through the
	# gearing, carrying the same design margin the clutch itself is sized with (clutch_margin -
	# at the bare minimum-torque rpm the engine has zero reserve, so the first bite of load drags
	# the revs down and the launch bogs), plus the engine's own motoring drag, inverted through
	# the torque curve. Grippier surface -> more torque to hold -> higher launch rpm, saturating
	# at peak_torque_rpm because past the peak there is no more torque to find.
	var sr := 0.0
	var t_wheel := 0.0
	var n := 0.0
	for w in _wheels:
		var sh: float = (1.0 - split) if w.steer else split
		if sh <= 0.001:
			continue
		n += 1.0
		var sg := 1.0
		if w.contact and surface_source != null:
			sg = surface_source.grip_at(w.contact_point.x, w.contact_point.z)
		sr += lerpf(peak_slip_gravel, peak_slip_tarmac, clampf((sg - 1.15) / 0.25, 0.0, 1.0))
		var mux := _mu_load(mu_long, w.Fz) * sg * w.tyre_grip * (1.0 - damage_grip_loss * _damage)
		t_wheel += mux * w.Fz * wheel_radius
	var t_need := clutch_margin * t_wheel / maxf(absf(ratio) * driveline_eff, 0.001) + t_fric
	return Vector2(maxf(sr / maxf(n, 1.0), 0.02), _rpm_for_torque(t_need))

func _lat_shape(w: Wheel) -> Vector2:
	# (By, Cy) for the surface under this wheel. Both blend on the same grip factor the longitudinal
	# Bx uses, so the lateral curve's peak LOCATION and its post-peak SHAPE are surface properties
	# together. B is derived from the blended peak ANGLE using the blended C, so the peak lands on
	# peak_alpha_* whatever the shape factor is - the two knobs stay independent.
	var sg := 1.0
	if w.contact and surface_source != null:
		sg = surface_source.grip_at(w.contact_point.x, w.contact_point.z)
	var t := clampf((sg - 1.15) / 0.25, 0.0, 1.0)
	var c := lerpf(cy_gravel, Cy, t)
	var a := lerpf(peak_alpha_gravel, peak_alpha_tarmac, t)
	return Vector2(_mf_peak_u(c, Ey) / maxf(deg_to_rad(a), 0.01), c)

func _peak_alpha_rad(lat: Vector2) -> float:
	# C2: the slip angle where THIS wheel's lateral curve actually peaks, recovered from the same
	# (By, Cy) the force itself uses. Inverting _lat_shape's own derivation rather than re-reading
	# peak_alpha_* means the trail collapse follows the surface blend for free and can never drift
	# out of step with where the grip peak really is - including when a slider moves mid-drive.
	return _mf_peak_u(lat.y, Ey) / maxf(lat.x, 0.01)

func _understeer_gradient() -> float:
	# K_us [s^2/m] for the bicycle-model reference yaw rate psi_dot = v*delta / (L + K_us*v^2):
	# axle load over axle cornering stiffness, front minus rear. The stiffness is the tyre
	# model's OWN slope at zero slip angle (Ca = dFy/dalpha|0 = D*C*B), so the reference bends
	# with load transfer, load sensitivity and the drive-mode CoM bias instead of being a number.
	var wf := 0.0
	var wr := 0.0
	var cf := 0.0
	var cr := 0.0
	for w in _wheels:
		var fz: float = maxf(w.Fz, 1.0)
		var ls: Vector2 = _lat_shape(w)
		var ca: float = _mu_load(mu_lat, fz) * fz * ls.y * ls.x
		if w.steer:
			wf += fz
			cf += ca
		else:
			wr += fz
			cr += ca
	return (wf / maxf(cf, 1.0) - wr / maxf(cr, 1.0)) / 9.81

func apply_diff_preset(i: int) -> void:
	# A3 evaluation: stamp one preset's values over the diff exports (see DIFF_PRESETS)
	if i < 0 or i >= DIFF_PRESETS.size():
		return
	var p: Dictionary = DIFF_PRESETS[i]
	for k in p:
		if k != "name":
			set(k, p[k])

func diff_preset_index() -> int:
	# which preset the CURRENT values match (-1 = none), so nothing can claim a preset the
	# user has since tuned away from with the Tab sliders
	for i in range(DIFF_PRESETS.size()):
		var p: Dictionary = DIFF_PRESETS[i]
		var same := true
		for k in p:
			if k == "name":
				continue
			if not is_equal_approx(float(get(k)), float(p[k])):
				same = false
				break
		if same:
			return i
	return -1

func diff_preset_name() -> String:
	var i := diff_preset_index()
	if i < 0:
		return "CUSTOM"
	return "[%d]%s" % [i + 1, str(DIFF_PRESETS[i]["name"])]

func _diff_transfer(dtype: int, dw: float, t_axle: float, power: bool, visc: float, pre_nm: float, p_ramp: float, c_ramp: float, imp: float) -> Vector2:
	# A3: one axle differential. Returns (transfer torque, d/d(omega) slope for the implicit update).
	# dw = left omega - right omega; positive transfer takes torque FROM the faster left wheel.
	# VISCOUS is linear in dw; OPEN / CLUTCH-PACK / LOCKED are Coulomb capacities pushed through a
	# tanh Karnopp band (same pattern as the A1 engine clutch). The Salisbury capacity grows with
	# |axle input torque| through the POWER or COAST ramp - selected by the sign of the ENGINE-side
	# torque (t_gb), so reverse-gear drive still counts as power (the plan's reverse-sign risk).
	# imp (N*m per rad/s) caps everything at the ONE-SUBSTEP equalising impulse: friction can stop
	# relative motion but never reverse it - without this, a saturated tanh has zero slope, the
	# update turns explicit, and a LOCKED diff chatters +/-20 rad/s at the substep frequency.
	var lim := absf(dw) * imp
	if dtype == 1:
		return Vector2(clampf(visc * dw, -lim, lim), visc)
	var cap := DIFF_OPEN_FRICTION
	if dtype == 2:
		cap = pre_nm + (p_ramp if power else c_ramp) * absf(t_axle)
	elif dtype == 3:
		cap = DIFF_LOCKED_CAP
	cap = minf(cap, lim)
	var th := tanh(dw / DIFF_BAND)
	return Vector2(cap * th, cap * (1.0 - th * th) / DIFF_BAND)

func _physics_process(delta: float) -> void:

	if Input.is_action_just_pressed("reset"):
		respawn(); return
	center_of_mass = Vector3(0, com_height, _com_bias())   # re-applied so live tuning takes effect
	_derive_setup()                                  # B1: rates follow the targets + the live CoM

	# virtual pedals: shape the binary key like a real foot; an analog trigger (if a pad ever works) bypasses it
	var throttle_key := Input.get_action_strength("throttle")
	var brake_key := Input.get_action_strength("brake")
	var analog_pedals := false
	var jpads := Input.get_connected_joypads()
	if jpads.size() > 0:
		if Input.get_joy_axis(jpads[0], JOY_AXIS_TRIGGER_RIGHT) > 0.05 or Input.get_joy_axis(jpads[0], JOY_AXIS_TRIGGER_LEFT) > 0.05:
			analog_pedals = true
	if analog_pedals:
		_throttle_pedal = throttle_key
		_brake_pedal = brake_key
	else:
		var t_up: float = throttle_rise_time if throttle_key > _throttle_pedal else throttle_fall_time
		_throttle_pedal = move_toward(_throttle_pedal, throttle_key, delta / maxf(t_up, 0.001))
		var b_up: float = brake_rise_time if brake_key > _brake_pedal else brake_fall_time
		_brake_pedal = move_toward(_brake_pedal, brake_key, delta / maxf(b_up, 0.001))
	var throttle := _throttle_pedal
	var brake := _brake_pedal
	var handbrake := Input.get_action_strength("handbrake")   # raw - it's a lever, not a pedal
	if Input.is_action_just_pressed("puncture_test"):     # [P] debug: puncture the next intact tyre (R resets)
		for w in _wheels:
			if not w.punctured:
				w.punctured = true
				break

	# M8: impact damage - a crash-level HORIZONTAL deceleration (braking/cornering/landings stay below)
	var dvel := linear_velocity - _prev_vel
	var haccel := Vector2(dvel.x, dvel.z).length() / maxf(delta, 0.001)
	if haccel > impact_threshold and _prev_vel.length() > 2.0:
		var sev := clampf((haccel - impact_threshold) / impact_scale, 0.0, 1.0)
		_damage = clampf(_damage + sev * damage_gain, 0.0, 1.0)
		var local_dv := global_transform.basis.inverse() * dvel     # which side took the hit -> pull that way
		if absf(local_dv.x) > 1.0:
			_pull_dir = signf(local_dv.x)
	# steering target from keys or the gamepad's left stick
	var steer_target := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	# a deflected analog stick maps near-directly (the stick's own motion IS the smoothing); the keyboard
	# keeps its progressive ramp so binary 0/1 keys don't snap to full lock.
	var stick_x := 0.0
	var pads := Input.get_connected_joypads()
	if pads.size() > 0:
		stick_x = Input.get_joy_axis(pads[0], JOY_AXIS_LEFT_X)
	if absf(stick_x) > 0.12:
		_steer = move_toward(_steer, steer_target, steer_analog_rate * delta)
	else:
		# keyboard: faster ramp holding , / . OR the letter+matching-arrow combo (A+Left, D+Right)
		var mod_fast := Input.is_physical_key_pressed(KEY_COMMA) or Input.is_physical_key_pressed(KEY_PERIOD)
		var combo_left := Input.is_physical_key_pressed(KEY_A) and Input.is_physical_key_pressed(KEY_LEFT)
		var combo_right := Input.is_physical_key_pressed(KEY_D) and Input.is_physical_key_pressed(KEY_RIGHT)
		var steer_fast := mod_fast or (steer_target > 0.0 and combo_left) or (steer_target < 0.0 and combo_right)
		var srate := steer_return_rate if is_zero_approx(steer_target) else (steer_fast_rate if steer_fast else steer_rate)
		_steer = move_toward(_steer, steer_target, srate * delta)
	var steer_in := clampf(_steer + _pull_dir * _damage * damage_steer_pull, -1.0, 1.0)   # M8: damage pulls the car
	var speed := linear_velocity.length()
	var steer_reduce := 1.0 - clampf(speed / 45.0, 0.0, 1.0) * steer_speed_falloff
	var steer_angle := deg_to_rad(max_steer_deg) * steer_in * steer_reduce
	if _steer_wheel != null:
		_steer_wheel.rotation.z = steer_in * 2.4     # cosmetic: spin the cockpit wheel
	# cabin rev bar: light segments up to the current rpm; shift light flashes near the shift point
	if not _rev_segs.is_empty():
		var frac := clampf(_engine_rpm / maxf(redline_rpm, 1.0), 0.0, 1.0)
		var lit := int(round(frac * float(_rev_segs.size())))
		for i in range(_rev_segs.size()):
			var sm = _rev_segs[i]
			sm["mat"].albedo_color = sm["col"] if i < lit else sm["col"].darkened(0.45)   # unlit stays visibly coloured
			sm["mat"].emission_energy_multiplier = 2.5 if i < lit else 0.0
	if _shift_mat != null:
		_flash += delta
		var need := _engine_rpm >= redline_rpm * shift_light_frac and _gear > 0 and _gear < gear_ratios.size()
		var on := need and fmod(_flash, 0.18) < 0.09
		_shift_mat.emission_energy_multiplier = 5.0 if on else 0.0
		_shift_mat.albedo_color = Color(0.9, 0.0, 0.0) if on else Color(0.2, 0.0, 0.0)
	var space := get_world_3d().direct_space_state
	var up := global_transform.basis.y

	# C1: push the car's own (Tab-tunable) roughness amplitudes into the field once per tick,
	# before it gets sampled below - the car is the single source of truth the panel can reach.
	if roughness_field != null:
		roughness_field.road_class_gravel = road_class_gravel
		roughness_field.road_class_tarmac = road_class_tarmac
		roughness_field.washboard_amp = washboard_amp
		roughness_field.joint_amp = joint_amp
		roughness_field.patch_amp = patch_amp

	# --- suspension + tire-frame pass ---
	# HORIZONTAL ground speed, never linear_velocity.length(): the vertical component would inflate
	# both the swept footprint and the road-velocity term on every crest and landing.
	var hspeed := Vector2(linear_velocity.x, linear_velocity.z).length()
	var info := {}
	for w in _wheels:
		var mount_world := global_transform * w.pos
		var q := PhysicsRayQueryParameters3D.create(mount_world, mount_world - up * (rest_length + wheel_radius))
		q.exclude = [get_rid()]; q.collision_mask = 1
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			w.contact = false; w.Fz = 0.0; w.util = 0.0
			var tb := Basis(Vector3(0, 0, 1), PI * 0.5)
			if w.steer: tb = Basis(Vector3.UP, steer_angle) * tb
			w.vis.global_transform = Transform3D(global_transform.basis * tb, mount_world - up * rest_length)
			continue
		w.contact = true
		var hit_pos: Vector3 = hit.position
		var n: Vector3 = hit.normal
		w.contact_normal = n
		# C1.3: shorten/lengthen the measured ground distance by the enveloped roughness field
		# instead of adding a force - everything downstream (spring, damper, B3's bump stop, Fz,
		# load-sensitive grip, weight transfer, tyre heat/wear) inherits it for free and correctly.
		# Offset contact_point the same way so dust/marks/terrain dig/audio stay consistent (C1.3).
		var rough_rate := 0.0                # d(ground height)/dt under this wheel, m/s
		if roughness_field != null and roughness_gain != 0.0:
			var fwd0 := -global_transform.basis.z
			if w.steer:
				fwd0 = fwd0.rotated(up, steer_angle)
			# footprint spans the strip the tyre sweeps this tick, so the field is filtered at the
			# rate it is actually sampled (see roughness.gd sample_profile)
			var prof: Vector2 = roughness_field.sample_profile(
				hit_pos.x, hit_pos.z, Vector2(fwd0.x, fwd0.z), hspeed * delta)
			hit_pos += up * (prof.x * roughness_gain)
			# The road's OWN vertical velocity: local slope times ground speed. A damper responds to
			# RELATIVE velocity between body and wheel, and with no unsprung mass the wheel follows
			# the ground exactly - so a wheel crossing corrugations sees large damper velocities even
			# with the body dead still. Leaving this out (as C1 originally did) meant roughness could
			# only ever produce a SPRING force change, which is why the field measured as a ~12% load
			# wobble and could not be felt. Harmless before C1 because smooth ground has no d/dt.
			if damper_reads_road:
				rough_rate = prof.y * hspeed * roughness_gain
		w.contact_point = hit_pos
		var compression := clampf((rest_length + wheel_radius) - mount_world.distance_to(hit_pos), 0.0, max_travel)
		var contact_off := hit_pos - global_position
		var pv := linear_velocity + angular_velocity.cross(contact_off)
		# compression rate = body falling toward the ground PLUS the ground rising toward the body
		var comp_vel := clampf(-pv.dot(up) + rough_rate, -3.0, 3.0)
		var kw: float = _k_front if w.steer else _k_rear
		var ccw: float = _ccrit_front if w.steer else _ccrit_rear
		var Fz := maxf(kw * compression + _damper_force(comp_vel, ccw), 0.0)
		# B3: progressive bump stop over the last of the travel - firm, ramped, and bounded by the
		# corner's own static load rather than by a flat clamp that distorted every big hit
		w.bottomed = false
		var zone := max_travel * clampf(bumpstop_zone, 0.02, 0.9)
		var into := compression - (max_travel - zone)
		if into > 0.0:
			var x := clampf(into / zone, 0.0, 1.0)
			var mc: float = _mc_front if w.steer else _mc_rear
			Fz += bumpstop_g * mc * 9.81 * x * x * x
			w.bottomed = true
		w.Fz = Fz
		w.comp = compression                              # deferred: anti-roll bars adjust Fz, applied below
		var fwd := -global_transform.basis.z
		if w.steer: fwd = fwd.rotated(up, steer_angle)
		fwd = (fwd - n * fwd.dot(n)).normalized()
		var right := n.cross(fwd).normalized()
		info[w] = {"fwd": fwd, "right": right, "off": contact_off, "hit": hit_pos,
			"v_long": pv.dot(fwd), "v_lat": pv.dot(right)}

	# anti-roll bars transfer load across each axle, then apply the roll-balanced vertical load
	_apply_arb(0, 1, _arb_f)         # front pair (wheels FL, FR)
	_apply_arb(2, 3, _arb_r)         # rear pair (wheels RL, RR)
	for w in _wheels:
		if w.contact:
			apply_force(w.contact_normal * w.Fz, info[w]["off"])

	# drive mode: AWD uses torque_split, RWD forces all-rear, FWD forces all-front
	if Input.is_action_just_pressed("drive_mode"):
		_drive_mode = (_drive_mode + 1) % 3
		_apply_mode()
	# [1]/[2]/[3] (or the pad's touchpad click to cycle): swap the whole differential setup
	# mid-drive for back-to-back comparison on the same corner
	for pi in range(DIFF_PRESET_KEYS.size()):
		if Input.is_action_just_pressed(DIFF_PRESET_KEYS[pi]):
			apply_diff_preset(pi)
	if Input.is_action_just_pressed("diff_preset_next"):
		apply_diff_preset((diff_preset_index() + 1) % DIFF_PRESETS.size())   # CUSTOM (-1) -> [1]
	var eff_split := torque_split
	if _drive_mode == 1: eff_split = 1.0
	elif _drive_mode == 2: eff_split = 0.0

	# --- gearbox (manual: E up, Q down). A1: _gear -1 = reverse, 0 = NEUTRAL, 1..N = forward.
	# A4: the swap is no longer instant. A request starts a shift_time manoeuvre - the auto-clutch
	# dips (below), the dogs take the new ratio at the MIDDLE of the dip, then the plates feed back
	# in. The box is busy until the timer runs out, so a fresh request is ignored. ---
	var req := 0
	if Input.is_action_just_pressed("shift_up") and _gear < gear_ratios.size():
		req = 1
	if Input.is_action_just_pressed("shift_down") and _gear > -1:
		req = -1
	if req != 0 and _shift_t <= 0.0:
		var to_gear := _gear + req
		# money-shift guard: once the plates are back in the WHEELS set engine speed, so ask what
		# the crank would be doing on the new ratio. Catches the 5th->2nd grab and dropping N->1st
		# (or selecting R) at speed alike - it is the predicted rpm that decides, not the direction.
		var to_gr := 0.0
		if to_gear == -1:
			to_gr = reverse_ratio
		elif to_gear > 0:
			to_gr = gear_ratios[to_gear - 1]
		var rpm_after := absf(_driven_avg(eff_split).x) * to_gr * final_drive * 60.0 / TAU
		var over := (rpm_after - redline_rpm) / maxf(redline_rpm, 1.0)
		if over <= 0.0 or not overrev_guard:
			if over > 0.0:
				# allowed money shift: valve float and bearing abuse, scaled by how far past
				# redline the crank is thrown (a doubled redline = one full-severity hit)
				_damage = clampf(_damage + clampf(over, 0.0, 1.0) * damage_gain, 0.0, 1.0)
			_shift_t = maxf(shift_time, 0.001)
			_shift_to = to_gear
			_shift_pending = true
			_shift_down = req < 0
	if _shift_t > 0.0:
		_shift_t = maxf(_shift_t - delta, 0.0)
		if _shift_pending and _shift_t <= shift_time * 0.5:
			_gear = _shift_to               # mid-dip: the dogs engage the new ratio...
			_shift_pending = false
			# ...and the speed mismatch resolves through the plates instead of teleporting rpm for
			# free (A2). The blip revs the engine there smoothly; without it, the jolt is felt.
			_clutch_locked = false
			if _shift_down and auto_blip and not manual_clutch and _gear > 0 and speed > 3.0:
				# heel-toe event order: the foot is ALREADY down when the new ratio engages, so the
				# plates are open at the swap - otherwise their drag out-races the blip and the revs
				# get ground up through the wheels (the exact jolt the blip exists to avoid)
				_blip_t = BLIP_TIME
				_clutch = 0.0
	var reverse := _gear == -1
	var neutral := _gear == 0
	var gr := 0.0                    # engine:wheel gear ratio (0 in neutral = no coupling)
	if reverse:
		gr = reverse_ratio
	elif _gear > 0:
		gr = gear_ratios[_gear - 1]

	# motoring-friction line T_fric(w) = c0 + c1*w fit through the two physical anchor points
	var w_idle := idle_rpm * TAU / 60.0
	var w_red := redline_rpm * TAU / 60.0
	var w_stall := idle_rpm * 0.55 * TAU / 60.0     # where the anti-stall clamp is fully open, just
													# above the floor _engine_torque() stops firing at
	var fric_c1 := (engine_brake_redline - engine_brake_idle) / maxf(w_red - w_idle, 1.0)
	var fric_c0 := engine_brake_idle - fric_c1 * w_idle
	var ratio := gr * final_drive                        # engine:wheel ratio (0 in neutral)

	# --- clutch engagement (A1). Manual: LEFT SHIFT is the pedal (held = open). Auto: engagement
	# is scheduled from rpm - it feeds in between idle and bite_rpm, so a launch slips the clutch
	# and SELF-BALANCES (revs sink -> capacity sinks) the way a driver's foot does. Anti-stall
	# (and auto mode always) opens the clutch as rpm falls toward the stall floor (half idle,
	# where combustion dies - see _engine_torque).
	var rpm_pre := _omega_e * 60.0 / TAU
	_blip_t = maxf(_blip_t - delta, 0.0)
	_ign_grace = maxf(_ign_grace - delta, 0.0)
	# A4 launch assist: arms at a standstill in 1st on throttle. It hands back the moment the
	# driver brakes, lifts or changes gear - and, once rolling, as soon as the launch is over:
	# either the plates have stopped slipping or the wheels alone would already spin the crank
	# past the launch rpm (from there the assist would only be cutting a pedal the driver wants
	# open). Both are the physical end of a launch, not a cutout speed.
	var ls := Vector2.ZERO           # (target driven slip ratio, computed launch rpm)
	if launch_assist and not manual_clutch:
		ls = _launch_setup(eff_split, ratio, maxf(fric_c0 + fric_c1 * _omega_e, 0.0))
		var gb_rpm := absf(_driven_avg(eff_split).x * ratio) * 60.0 / TAU
		if not _launch and _gear == 1 and speed < 1.0 and throttle > 0.05 and brake < 0.05:
			_launch = true
		elif _launch and (_gear != 1 or throttle < 0.05 or brake > 0.05 \
				or (speed > slip_ref_speed and (_clutch_locked or gb_rpm >= ls.y))):
			_launch = false
	else:
		_launch = false
	var launch_sr := maxf(ls.x, 0.02)
	var launch_rpm := maxf(ls.y, idle_rpm)
	var c_target: float
	if manual_clutch:
		c_target = 1.0 - Input.get_action_strength("clutch")
	else:
		c_target = clampf((rpm_pre - idle_rpm) / maxf(bite_rpm - idle_rpm, 1.0), 0.0, 1.0)
		if _launch:
			# Launch assist adds ONE limit on top of the proven rpm schedule above: trim the plates
			# on measured wheelspin - fully home at or below the surface's peak-grip slip, fully
			# open at twice it, so the proportional band IS the target and there is no constant to
			# tune. The throttle governor (in the driveline loop) owns the revs, the trim owns the
			# torque; between them the driven wheels sit at peak slip, which is peak force.
			var kd := 0.0
			var kn := 0.0
			for w in _wheels:
				var shl: float = (1.0 - eff_split) if w.steer else eff_split
				if shl > 0.001:
					kd += absf(w.kappa)
					kn += 1.0
			# the plates also WAIT for the revs and then self-balance on them (A1's schedule with
			# its bite point computed instead of fixed): capacity arrives as the engine reaches the
			# launch rpm and eases off the moment loading it drags the revs back down.
			var revved := clampf((rpm_pre - idle_rpm) / maxf(launch_rpm - idle_rpm, 1.0), 0.0, 1.0)
			c_target = minf(revved, clampf(2.0 - (kd / maxf(kn, 1.0)) / launch_sr, 0.0, 1.0))
		if _blip_t > 0.0 or _shift_t > 0.0:
			c_target = 0.0           # A2 blip / A4 shift dip: plates open while the ratio changes
		elif handbrake > 0.0 and speed > slip_ref_speed:
			# A5: rally technique - clutch in while the lever is up, so the engine is not dragged
			# down by (or fighting) the locked rear axle. Below slip_ref_speed it is just a parking
			# brake and the anti-stall clamp already covers it; with manual_clutch ON it is the
			# driver's job, which is why this sits in the auto branch.
			c_target = 0.0
	if anti_stall or not manual_clutch or _ign_grace > 0.0:
		c_target = minf(c_target, clampf((rpm_pre - idle_rpm * 0.55) / (idle_rpm * 0.35), 0.0, 1.0))
	var c_rate := CLUTCH_OUT_RATE if c_target < _clutch else CLUTCH_IN_RATE
	_clutch = move_toward(_clutch, c_target, c_rate * delta)

	# --- A4 stability assist (ESC, default OFF). The reference is the bicycle model's yaw rate,
	# psi_dot = v*delta / (L + K_us*v^2), with BOTH terms read off the car: the wheelbase from the
	# wheel mounts and the understeer gradient from live axle load over the tyre model's own
	# cornering stiffness (_understeer_gradient). Yaw beyond that reference by more than
	# stability_margin is trimmed with a dab of brake on the OUTER FRONT wheel of the rotation -
	# fed through the same brake path the pedal uses, so it inherits that path's semi-implicit
	# treatment, and impulse-capped per substep below so it can never drive a wheel backwards. ---
	for ei in range(_esc.size()):
		_esc[ei] = 0.0
	var v_fwd := linear_velocity.dot(-global_transform.basis.z)
	if stability_assist and absf(v_fwd) > slip_ref_speed:
		var yaw := angular_velocity.dot(up)
		var wheelbase := absf(_wheels[2].pos.z - _wheels[0].pos.z)
		var yaw_ref := v_fwd * steer_angle / maxf(wheelbase + _understeer_gradient() * v_fwd * v_fwd, 0.5)
		# ...ceilinged at what the tyres can actually sustain, psi_dot_max = mu*g/v. The bicycle
		# term is the KINEMATIC (no-slip) yaw rate: with this car's near-neutral balance K_us is
		# ~0, so at road speeds it asks for a yaw rate no tyre could hold, and every real slide
		# still reads as "less than reference". The grip ceiling is what makes the reference mean
		# something, and it falls with speed and with the surface exactly as it should.
		var mu_sum := 0.0
		var mu_n := 0.0
		for w in _wheels:
			if not w.contact:
				continue
			var sgm := 1.0
			if surface_source != null:
				sgm = surface_source.grip_at(w.contact_point.x, w.contact_point.z)
			mu_sum += _mu_load(mu_lat, w.Fz) * sgm * w.tyre_grip
			mu_n += 1.0
		var yaw_cap := (mu_sum / maxf(mu_n, 1.0)) * 9.81 / maxf(absf(v_fwd), 1.0)
		yaw_ref = clampf(yaw_ref, -yaw_cap, yaw_cap)
		# the error is SIGNED - comparing magnitudes would let opposite lock raise the intervention
		# threshold, which is backwards: a slide is counter-steered, so the reference points the
		# other way and every bit of yaw in the slide direction is error, not allowance.
		var err := yaw - yaw_ref
		var excess := absf(err) - stability_margin
		# ...it only counts as OVERSTEER when the error runs the same way the car is actually
		# rotating (a cornering car normally yaws LESS than its reference - that is plain
		# understeer, and reading its opposite-signed error as excess had the assist braking
		# through every ordinary corner)...
		# ...and the aid stands down once the DRIVER is already correcting. Opposite lock works by
		# the front tyres' lateral force, whose moment arm about the CoM is the front-axle distance
		# (1.35 m) against the brake's half-track (0.82 m) - so braking a saturated outer front
		# during a counter-steer trades away more yaw authority than it adds, and measurably makes
		# the slide worse. Catch the rotation before opposite lock; get out of the way after.
		if excess > 0.0 and err * yaw > 0.0 and steer_angle * yaw >= 0.0:
			var oi := 1 if err > 0.0 else 0     # front wheel whose drag yaws the car back (+err = rotating left)
			var ow: Wheel = _wheels[oi]
			if ow.contact:
				# ceiling is the torque that would just LOCK this tyre: past it the wheel stops
				# rolling and the friction ellipse takes its lateral grip away - the opposite of
				# help. So the aid brakes up to the limit of the contact patch and no further.
				var sg := 1.0
				if surface_source != null:
					sg = surface_source.grip_at(ow.contact_point.x, ow.contact_point.z)
				var t_lock := _mu_load(mu_long, ow.Fz) * sg * ow.tyre_grip * ow.Fz * wheel_radius
				_esc[oi] = clampf(stability_gain * excess, 0.0, minf(t_lock, brake_torque))

	# --- TWO-INERTIA DRIVELINE (A1): the engine integrates its own spin; the clutch couples it
	# to the gearbox. Slipping: T_clutch = capacity * tanh(dw/band) drives the wheels while its
	# reaction loads the engine. Locked: the engine follows the driven-wheel average kinematically
	# (the proven pre-A1 path, reflected inertia included) until the through-torque exceeds
	# capacity. Every wheel still carries its own omega; slip ratio -> Magic Formula -> force;
	# selectable diffs couple each axle pair (A3); the stiff spin ODE stays sub-stepped + semi-implicit. ---
	var gsign := -1.0 if reverse else 1.0
	var dt_sub := delta / float(drive_substeps)
	# derive the Pacejka B per surface from the desired peak-slip locations (functions over constants)
	var u_star := _mf_peak_u(Cx, Ex)
	var bx_tarmac := u_star / maxf(peak_slip_tarmac, 0.02)
	var bx_gravel := u_star / maxf(peak_slip_gravel, 0.02)
	var t_cap := _clutch * clutch_margin * peak_torque   # torque the clutch plates can carry
	var fx_sum := {}
	for wj in _wheels:
		fx_sum[wj] = 0.0
	for _s in range(drive_substeps):
		# wheel-side coupling speed: signed average spin of the torque-receiving wheels
		var da := _driven_avg(eff_split)
		var wavg := da.x
		var dn := da.y
		var omega_gb := wavg * ratio * gsign     # engine-side speed of the gearbox input
		if neutral:
			_clutch_locked = false
		elif _clutch_locked:
			# locked: the engine IS the wheels through the gear. Test the follow BEFORE taking it -
			# written the other way round the crank was assigned first and only then found to be out
			# of range, so selecting reverse while still rolling forwards (omega_gb goes negative, the
			# crank clamps to zero) killed the engine in ONE tick: measured 2658 rpm -> 0.0 rpm.
			var w_follow := clampf(omega_gb, 0.0, w_red * 1.35)
			if absf(omega_gb - w_follow) > CLUTCH_LOCK_BAND:
				_clutch_locked = false           # the follow would hit a physical limit -> plates slip
			elif (anti_stall or not manual_clutch) and w_follow < w_stall:
				# A real anti-stall opens the plates rather than letting them drag the crank under its
				# firing speed, and that is the whole job. Without this the lock slaves the engine
				# straight to a stopped wheel - a wall, a kerb - and it is dead long before the
				# pedal-rate clutch can travel: measured 2517 rpm -> 31 rpm through a wall impact.
				_clutch_locked = false
			else:
				_omega_e = w_follow
		var rpm := _omega_e * 60.0 / TAU
		var rev_cut := clampf((redline_rpm - rpm) / 350.0, 0.0, 1.0)   # rev limiter
		# optional traction control: trim demand toward the slip target (uses last sub-step's slip)
		if tc_enabled:
			var worst := 0.0
			for wj in _wheels:
				var shx := (1.0 - eff_split) if wj.steer else eff_split
				if shx > 0.001 and wj.contact:
					worst = maxf(worst, absf(wj.kappa))
			_tc_scale = clampf(_tc_scale - tc_strength * (worst - tc_slip_target) * dt_sub, 0.1, 1.0)
		else:
			_tc_scale = 1.0
		# combustion torque: the driver's pedal, the idle controller, or the A2 rev-match blip -
		# whichever asks for more - through the intake lag. The blip chases the LIVE post-shift
		# target rpm (wheel speed through the new gear), feathering off across BLIP_BAND.
		var t_target := 0.0
		if not _stalled:
			var idle_thr := clampf((idle_rpm - rpm) / (idle_rpm * 0.15), 0.0, 1.0)
			# A4: while launching, the assist OWNS the pedal - it holds the COMPUTED launch rpm,
			# so unlike the idle/blip demands (which can only ask for more) it also cuts.
			var thr_cmd := throttle
			if _launch:
				thr_cmd = clampf((launch_rpm - rpm) / maxf(launch_rpm * LAUNCH_RPM_BAND, 1.0), 0.0, 1.0)
			var blip_thr := 0.0
			if _blip_t > 0.0:
				if _omega_e >= omega_gb:
					_blip_t = 0.0            # matched -> end the blip, the clutch feeds back in
				elif _clutch <= 0.15:
					# proper heel-toe order: only blip once the plates are OPEN, so the spin-up
					# torque never drags the wheels (the engine revs faster than the clutch moves)
					blip_thr = clampf((omega_gb - _omega_e) / BLIP_BAND, 0.0, 1.0)
			t_target = _engine_torque(rpm) * maxf(thr_cmd, maxf(idle_thr, blip_thr)) * rev_cut * (1.0 - damage_power_loss * _damage) * _tc_scale
		_t_comb += (t_target - _t_comb) * clampf(dt_sub / maxf(intake_tau, dt_sub), 0.0, 1.0)
		# motoring friction always opposes rotation (a dead engine still compresses and rubs)
		var t_fric := maxf(fric_c0 + fric_c1 * _omega_e, 0.0)
		var t_net := _t_comb - t_fric            # net crank torque
		var t_gb := 0.0                          # torque entering the gearbox (engine side)
		var dTc := 0.0                           # slipping-clutch torque slope (for the wheels' k_stiff)
		if neutral:
			_omega_e = clampf(_omega_e + t_net * dt_sub / engine_inertia, 0.0, w_red * 1.35)
		elif _clutch_locked:
			t_gb = t_net
			if absf(t_net) > t_cap:              # more than the plates can hold -> break loose
				_clutch_locked = false
		else:
			var dw := _omega_e - omega_gb
			var th := tanh(dw / CLUTCH_BAND)
			var t_clutch := t_cap * th
			_omega_e = clampf(_omega_e + (t_net - t_clutch) * dt_sub / engine_inertia, 0.0, w_red * 1.35)
			t_gb = t_clutch
			dTc = t_cap * (1.0 - th * th) / CLUTCH_BAND
			if absf(dw) < CLUTCH_LOCK_BAND and absf(t_net) <= t_cap and t_cap > 0.0:
				_clutch_locked = true            # speeds converged and the torque fits -> lock up
				_omega_e = clampf(omega_gb, 0.0, w_red * 1.35)
		var t_line := t_gb * ratio * driveline_eff * gsign    # total wheel-side driveline torque
		var t_front := t_line * (1.0 - eff_split)
		var t_rear := t_line * eff_split
		# A3 centre coupling (AWD only): on top of the epicyclic torque_split, a speed-sensing
		# element transfers torque toward the SLOWER axle when the axles overspeed each other -
		# front wheelspin on a loose exit migrates torque rearward (the AWD rally feel). It also
		# couples the axles in N (the transfer case doesn't care whether the engine is connected).
		# A5: while the lever is up the centre device is released, so the locked rears are not
		# fighting the front axle through the transfer case (see handbrake_opens_centre).
		var centre_open := handbrake_opens_centre and handbrake > 0.0
		var c_visc: float = 0.0 if centre_open else centre_coupling
		var c_pre: float = 0.0 if centre_open else centre_preload
		var k_centre := 0.0
		if _drive_mode == 0:
			var wf := (_wheels[0].omega + _wheels[1].omega) * 0.5
			var wr := (_wheels[2].omega + _wheels[3].omega) * 0.5
			var dwc := wf - wr
			var thc := tanh(dwc / DIFF_BAND)
			var t_c := c_pre * thc + c_visc * dwc
			# impulse cap, like the axle diffs: the coupling can equalise the axles within one
			# substep but never swing them past each other (kills saturated-Coulomb chatter)
			var c_lim := absf(dwc) * wheel_inertia / dt_sub
			t_c = clampf(t_c, -c_lim, c_lim)
			t_front -= t_c
			t_rear += t_c
			# each wheel sees a quarter of the coupling's slope (half per axle, half per wheel)
			k_centre = 0.25 * (c_visc + c_pre * (1.0 - thc * thc) / DIFF_BAND)
		# A3 axle differentials: per-axle transfer torque between the paired wheels (see _diff_transfer)
		var power_now := t_gb > 0.0
		var d_imp := wheel_inertia / (2.0 * dt_sub)   # one-substep pair-equalising impulse scale
		var dxf := _diff_transfer(front_diff_type, _wheels[0].omega - _wheels[1].omega, t_front, power_now, front_visc, front_preload, front_power_ramp, front_coast_ramp, d_imp)
		var dxr := _diff_transfer(rear_diff_type, _wheels[2].omega - _wheels[3].omega, t_rear, power_now, rear_visc, rear_preload, rear_power_ramp, rear_coast_ramp, d_imp)
		for i in range(_wheels.size()):
			var w: Wheel = _wheels[i]
			var Fz: float = w.Fz
			var vlong := 0.0
			if info.has(w):
				vlong = info[w]["v_long"]
			var sgrip := 1.0
			if w.contact and surface_source != null:
				sgrip = surface_source.grip_at(w.contact_point.x, w.contact_point.z)
			var mux := _mu_load(mu_long, Fz) * sgrip * w.tyre_grip * (1.0 - damage_grip_loss * _damage)
			# axle torque -> half per side, +/- the differential's transfer torque (A3): the
			# transfer flows from the faster wheel of the pair toward the slower one
			var t_axle := t_front if w.steer else t_rear
			var dx := dxf if w.steer else dxr
			var side := -1.0 if i % 2 == 0 else 1.0
			var t_wheel := t_axle * 0.5 + side * dx.x
			# longitudinal force from the slip ratio (0 while airborne); k_stiff collects how hard
			# the torques push BACK per rad/s so the update below can be semi-implicit
			var Fx := 0.0
			var k_stiff := dx.y
			if _drive_mode == 0:
				k_stiff += k_centre
			var sh2 := (1.0 - eff_split) if w.steer else eff_split
			if not neutral and not _clutch_locked and sh2 > 0.001:
				# the slipping clutch's torque falls as this wheel speeds up - fold that slope into
				# the semi-implicit update exactly like the LSD and tyre slopes
				k_stiff += dTc * ratio * ratio * driveline_eff * sh2 * 0.5 / maxf(dn, 1.0)
			if w.contact:
				var den := maxf(absf(vlong), slip_ref_speed)
				var sr := (w.omega * wheel_radius - vlong) / den
				w.kappa = sr
				# tarmac tyres peak at low slip, gravel much later: blend the derived B by surface grip
				var bxw := lerpf(bx_gravel, bx_tarmac, clampf((sgrip - 1.15) / 0.25, 0.0, 1.0))
				Fx = _mf(sr, bxw, Cx, Ex, mux * Fz)
				k_stiff += maxf(_mf_slope(sr, bxw, Cx, Ex, mux * Fz), 0.0) * wheel_radius * wheel_radius / den
			# brakes + rolling resistance oppose spin, smoothly -> 0 near omega=0 (no chatter/lock jitter)
			var dirf := clampf(w.omega * 2.0, -1.0, 1.0)
			var t_brk := brake_torque * brake
			if handbrake > 0.0 and not w.steer:
				t_brk += handbrake_torque * handbrake
			if _esc[i] > 0.0:
				# A4 stability assist: impulse-capped at the one-substep stopping impulse, so the
				# correction can arrest this wheel but never spin it backwards (the A3 pattern)
				t_brk += minf(_esc[i], absf(w.omega) * wheel_inertia / dt_sub)
			var t_resist := (t_brk + roll_resist * Fz * wheel_radius) * dirf
			if absf(w.omega) < 0.6:
				k_stiff += 2.0 * (t_brk + roll_resist * Fz * wheel_radius)    # slope of dirf near omega=0
			# with the clutch LOCKED the engine's reflected inertia loads the driven wheels (weighted
			# by torque share so the total is one engine, not two); while it slips, the engine is
			# decoupled - the clutch torque (and its k_stiff slope above) is the only link
			var i_eff := wheel_inertia
			if _clutch_locked and sh2 > 0.001:
				i_eff += engine_inertia * ratio * ratio * sh2 * 0.5
			# semi-implicit update: dividing by (I + dt*k_stiff) keeps the stiff low-speed spin ODE
			# stable for ANY tyre stiffness / wheel inertia (explicit Euler chattered on light wheels)
			w.omega = clampf(w.omega + (t_wheel - Fx * wheel_radius - t_resist) * dt_sub / (i_eff + dt_sub * k_stiff), -400.0, 400.0)
			fx_sum[w] += Fx
	_engine_rpm = _omega_e * 60.0 / TAU

	# stall & restart (A1). STALLED means the ENGINE IS NOT RUNNING - not that the settings gave it
	# permission to stop. Below the firing floor `_engine_torque()` returns zero and motoring
	# friction only drags the crank further down, so it is dead however it got there. The old test
	# also demanded `manual_clutch and not anti_stall`, so the DEFAULT car (auto clutch, anti-stall
	# ON) could sit at 0 rpm with this flag FALSE - and every restart route is behind the flag, so
	# [I], the starter and a bump start all did nothing and the car was stranded. Measured: engine
	# at 0.0 rpm, then [I], a 40 km/h bump start in gear and neutral+[I] each changed nothing.
	# The dwell is why it only happened "sometimes": combustion torque decays through the intake lag
	# rather than vanishing, so a crank flicked briefly under the floor can still pick itself up, and
	# usually does. Only once that residual charge is spent is the engine really out.
	if _engine_rpm >= idle_rpm * 0.5 or _ign_grace > 0.0:
		_dead_t = 0.0
	else:
		_dead_t += delta
		if _dead_t > intake_tau * 3.0:
			_stalled = true
	if _stalled:
		_t_comb = 0.0
	# [I] is the ignition key: it must work whenever the engine is not turning over, rather than
	# only when the stall flag happens to be set. That gate is what left the default car with no way
	# back at all, since without a clutch pedal there is nothing else the driver can reach.
	if Input.is_action_just_pressed("ignition") and (_stalled or _engine_rpm < idle_rpm * 0.5):
		_stalled = false                         # starter: fire straight back to idle...
		_omega_e = idle_rpm * TAU / 60.0
		_engine_rpm = idle_rpm
		_restart_t = 0.0
		_dead_t = 0.0
		_clutch = 0.0                            # ...with the driver's restart reflex: clutch stabbed
		_clutch_locked = false                   # in, plus a moment of anti-stall grace to get going
		_ign_grace = 1.2
	elif _stalled:
		if _clutch < 0.05 or neutral:
			# starter: clutch held (or neutral found) long enough. On an auto clutch the anti-stall
			# clamp is already holding the plates open here, so this IS the anti-stall recovery -
			# the car re-fires itself half a second after it dies instead of stranding the driver.
			_restart_t += delta
			if _restart_t > 0.5:
				_stalled = false
				_omega_e = idle_rpm * TAU / 60.0
				_engine_rpm = idle_rpm
				_restart_t = 0.0
				_dead_t = 0.0
		else:
			_restart_t = 0.0
			if _engine_rpm > idle_rpm * 0.6:     # spun fast enough by the wheels -> combustion catches
				_stalled = false
				_dead_t = 0.0

	# --- apply the averaged longitudinal + the lateral (slip-angle) force per contact wheel ---
	_sat_moment = 0.0                        # C2: re-summed from the front wheels below
	for w in _wheels:
		if not w.contact:
			continue
		var d = info[w]
		var fwd_v: Vector3 = d["fwd"]
		var right_v: Vector3 = d["right"]
		var off_v: Vector3 = d["off"]
		var hit_v: Vector3 = d["hit"]
		var v_long: float = d["v_long"]
		var v_lat: float = d["v_lat"]
		var Fz: float = w.Fz
		var sgrip := 1.0
		if surface_source != null:
			sgrip = surface_source.grip_at(w.contact_point.x, w.contact_point.z)
		var mux := _mu_load(mu_long, Fz) * sgrip * w.tyre_grip * (1.0 - damage_grip_loss * _damage)
		var muy := _mu_load(mu_lat, Fz) * sgrip * w.tyre_grip * (1.0 - damage_grip_loss * _damage)
		var Fx: float = fx_sum[w] / float(drive_substeps)
		# lateral: Pacejka on slip angle, OPPOSES slip (restoring)
		w.slip_angle = atan2(v_lat, maxf(absf(v_long), 1.0))
		# B4 relaxation: the tyre must ROLL sigma_lat metres before the force follows the steer.
		# Expressed per DISTANCE, not per time, so the lag is a property of the tyre rather than
		# of the frame rate or the speed: fast, the force arrives quickly; crawling, it barely
		# lags at all. v is floored at slip_ref_speed so it cannot oscillate at parking speed.
		var v_roll := maxf(absf(v_long), slip_ref_speed)
		w.alpha_rel += (w.slip_angle - w.alpha_rel) * clampf(v_roll / maxf(sigma_lat, 0.01) * delta, 0.0, 1.0)
		var lat: Vector2 = _lat_shape(w)
		# a tyre nearly at rest cannot sustain a slip-angle force regardless of what alpha_rel says -
		# it is a RATE quantity, and there is no rate left to give it meaning. Fades in over
		# LOW_SPEED_LAT_FLOOR so it only ever bites right at the end of a stop, never during a slide.
		var wheel_speed := sqrt(v_long * v_long + v_lat * v_lat)
		var lat_speed_gate := clampf(wheel_speed / LOW_SPEED_LAT_FLOOR, 0.0, 1.0)
		var Fy := -_mf(w.alpha_rel, lat.x, lat.y, Ey, muy * Fz) * lat_speed_gate
		# elliptical combined-slip limit
		var nx := Fx / (mux * Fz + 0.001)
		var ny := Fy / (muy * Fz + 0.001)
		var e := sqrt(nx * nx + ny * ny)
		if e > 1.0:
			Fx /= e
			Fy /= e
			# GROSS SLIDING (A5): a sliding tyre's friction opposes its SLIP VELOCITY. It does not
			# keep whatever Fx:Fy ratio two independently-evaluated Magic Formula curves happened to
			# produce - the ellipse only rescales that ratio, it never corrects it. The difference is
			# invisible until a wheel really lets go: at slip ratio -1 the longitudinal curve is
			# saturated while the lateral curve still reads a modest slip angle, so the ellipse hands
			# back a force far too lateral for a locked tyre. Measured on a locked rear at ~10 deg of
			# slip: 1740 N of lateral force where opposing the slip velocity gives ~460 N, i.e. it
			# kept nearly 4x the grip it should. THAT is what the old rear_grip_cut = 0.2 constant
			# was standing in for. Blending the direction toward the slip velocity is the physical
			# version, so a locked rear axle lets go on its own and the handbrake rotates the car
			# instead of merely scrubbing speed.
			if slide_friction and Fz > 1.0:
				var vsx := w.omega * wheel_radius - v_long     # contact-patch slip velocity,
				var vsy := -v_lat                              # signed like Fx / Fy above
				var vm := sqrt(vsx * vsx + vsy * vsy)
				# vm > 0 always in principle, but AT exactly zero the direction is undefined - guard the
				# division, not the blend. The blend weight below is what actually fades this term
				# out, smoothly, well before vm gets that small.
				if vm > 0.001:
					var dx := vsx / vm
					var dy := vsy / vm
					# the ellipse's own radius along that direction, so the tyre stays anisotropic
					var ex := dx / maxf(mux, 0.01)
					var ey := dy / maxf(muy, 0.01)
					var cap := Fz / maxf(sqrt(ex * ex + ey * ey), 0.001)
					var slide := clampf((e - 1.0) / SLIDE_BAND, 0.0, 1.0)
					# was `if vm > 0.2:` - a binary switch between this physical-direction force and
					# the raw ellipse-scaled one below. Measured jump AT that line, one physics tick
					# apart, on a braking slide: front-R went from (-2434, 1554) N to (-2043, 1971) N -
					# an 11 degree, ~400 N snap in the force actually applied to the chassis, and every
					# wheel takes its own such snap at its own moment as the slide runs out, so the car
					# gets several of these in quick succession right at the end. `vm_gate` fades the
					# SAME blend continuously to 0 as the patch stops sliding, instead of cutting it.
					var vm_gate := clampf(vm / VM_BAND, 0.0, 1.0)
					var blend := slide * vm_gate
					Fx = lerpf(Fx, cap * dx, blend)
					Fy = lerpf(Fy, cap * dy, blend)
		w.util = minf(e, 1.0)
		w.slip = clampf(absf((w.omega * wheel_radius - v_long) / maxf(absf(v_long), slip_ref_speed)), 0.0, 3.0)
		# C2: self-aligning torque, taken from the FINAL Fy - after the friction ellipse and after
		# A5's gross-sliding correction - so a tyre that has been trimmed by combined slip reports
		# the weaker steering signal it physically would. Steered wheels only; the rears generate
		# their own Mz but nothing carries it to the driver's hands.
		if w.steer:
			var a_pk := _peak_alpha_rad(lat)
			# Trail collapse uses the COSINE (Pacejka Mz) form, not a straight line to zero. Trail
			# comes from the contact patch loading up rearward-biased while it still ADHERES; it
			# holds near its static value at small slip and only falls away as the rear of the patch
			# begins to slide. A linear collapse instead starts bleeding weight from the very first
			# degree, which measured out with the torque peaking at 1.1 deg against a 9 deg grip
			# peak - the wheel would go light across the whole range and the lightening would carry
			# no information about where the limit actually is.
			var t_p := trail_pneumatic * cos(PI * 0.5 * clampf(absf(w.alpha_rel) / maxf(a_pk, 0.01), 0.0, 1.0))
			_sat_moment += Fy * (t_p + trail_mechanical)
		apply_force(fwd_v * Fx + right_v * Fy, off_v)
		_update_tyre(w, Fx, Fy, v_long, v_lat, delta)     # M7: heat / wear / puncture -> next frame's tyre_grip
		if w.punctured:                                    # flat tyre -> thump synced to wheel rotation (the flat spot hits once per rev)
			var sf := clampf(linear_velocity.length() / 6.0, 0.0, 1.5)
			var jit := sin(w.spin) * 0.8 + (randf() * 2.0 - 1.0) * 0.5
			apply_force(up * (jit * puncture_shake * sf), off_v)
		# visual: wheels roll at their ACTUAL omega, so real wheelspin now shows
		w.spin += w.omega * delta
		var cam_b := Basis(Vector3(0, 0, 1), deg_to_rad(camber_deg) * signf(w.pos.x))   # static negative camber
		var steer_b := Basis(Vector3.UP, steer_angle) if w.steer else Basis.IDENTITY
		var tip_b := Basis(Vector3(0, 0, 1), PI * 0.5)
		var roll_b := Basis(Vector3(1, 0, 0), w.spin)
		var wheel_b := global_transform.basis * (cam_b * steer_b * roll_b * tip_b)
		var center_h := wheel_radius
		if w.punctured:                                    # deflated: squash vertically (world Y) + sit lower on the rim
			wheel_b = Basis(Vector3(1, 0, 0), Vector3(0, puncture_flat, 0), Vector3(0, 0, 1)) * wheel_b
			center_h = wheel_radius * puncture_flat
		w.vis.global_transform = Transform3D(wheel_b, hit_v + up * center_h)

	# C2: advance the steering-system lag once per physics tick (exponential, so the time constant
	# means the same thing at any tick rate). tau = 0 hands back the raw per-tick moment for A/B.
	if steer_filter_tau > 0.0001:
		_sat_filt += (_sat_moment - _sat_filt) * (1.0 - exp(-delta / steer_filter_tau))
	else:
		_sat_filt = _sat_moment

	if speed > 0.1:
		apply_central_force(-linear_velocity.normalized() * drag_k * linear_velocity.length_squared())

	# M7: engine temperature (gauge for the component HUD) - heats with load, cools with airflow
	# heat INTO the coolant, from the engine's actual output: a motor making no torque makes
	# almost no heat, which is why idling warms up so slowly and sustained WOT runs hot
	var q_in := maxf(_t_comb, 0.0) * _omega_e * coolant_heat_frac
	# heat OUT: radiator area x airflow, gated by the thermostat. Shut cold (nothing leaves, so
	# the engine warms quickly to operating temperature), fully open a few degrees past it.
	var t_open := clampf((_engine_temp - thermostat_temp) / 7.0, 0.0, 1.0)
	var airflow := 1.0 + speed / 25.0
	var q_out := radiator_k * airflow * maxf(_engine_temp - ambient_temp, 0.0) * t_open
	_engine_temp += (q_in - q_out) / maxf(engine_heat_capacity, 1.0) * delta
	_engine_temp = clampf(_engine_temp, ambient_temp, 135.0)

	_prev_vel = linear_velocity     # M8: for next frame's impact detection

func respawn() -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = spawn_transform
	_gear = 1; _engine_rpm = idle_rpm; _engine_temp = ambient_temp
	_omega_e = idle_rpm * TAU / 60.0; _t_comb = 0.0; _tc_scale = 1.0            # A1: engine state
	_clutch = 0.0; _clutch_locked = false; _stalled = false; _restart_t = 0.0   # A1: clutch state
	_dead_t = 0.0                                                              # A1: stall dwell
	_blip_t = 0.0; _ign_grace = 0.0                                            # A2: blip + starter grace
	_shift_t = 0.0; _shift_to = 1; _shift_pending = false; _shift_down = false  # A4: shift manoeuvre
	_launch = false                                                            # A4: launch assist
	for i in range(_esc.size()):
		_esc[i] = 0.0                                                          # A4: stability assist
	_sat_moment = 0.0; _sat_filt = 0.0                                         # C2: steering signal
	_throttle_pedal = 0.0; _brake_pedal = 0.0   # Phase 0: virtual pedals
	_damage = 0.0; _pull_dir = 0.0; _prev_vel = Vector3.ZERO   # M8: repaired on respawn
	for w in _wheels:
		w.spin = 0.0
		w.omega = 0.0
		w.kappa = 0.0
		w.alpha_rel = 0.0
		w.temp = ambient_temp      # M7: fresh tyres on respawn
		w.tyre_wear = 0.0
		w.punctured = false
		w.tyre_grip = 1.0

func get_steer_torque() -> float:
	# C2: torque at the steering rack (N*m). Sign follows the lateral force, so it reverses with
	# steering direction and sits at ~0 straight-ahead and at a standstill (no slip angle, no Fy).
	# Divided at read time so steer_ratio / sat_gain slider edits are felt immediately.
	return _sat_filt / maxf(steer_ratio, 1.0) * sat_gain

func get_wheels() -> Array[Wheel]:
	return _wheels

func get_engine() -> Dictionary:
	# pedals are the SHAPED states physics actually uses (analog triggers bypass the shaping),
	# so a HUD reading them shows real pedal travel rather than the raw key/axis
	return {"rpm": _engine_rpm, "gear": _gear, "speed_kmh": linear_velocity.length() * 3.6, "mode": MODE_NAMES[_drive_mode], "temp": _engine_temp, "damage": _damage, "clutch": _clutch, "stalled": _stalled, "throttle": _throttle_pedal, "brake": _brake_pedal}
