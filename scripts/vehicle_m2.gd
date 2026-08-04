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
@export var rest_length := 0.45
@export var spring_k := 40000.0
@export var damper_c := 8000.0                  # more damping soaks up rut/berm bumps (less jumping)
@export var max_travel := 0.45
# anti-roll bars: transfer load across an axle to resist body roll. Stiffer FRONT bar biases toward
# understeer, stiffer REAR toward oversteer (via the load-sensitive tyre grip). N per m of travel diff.
@export var arb_front := 14000.0
@export var arb_rear := 10000.0
@export var camber_deg := 1.5                   # static negative camber (visual + a small grip cue)

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
@export var engine_heat_rate := 16.0         # C/s of heating at full load
@export var engine_cool_rate := 0.05         # cooling toward ambient (1/s, scaled by airflow)

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
@export var By := 10.0
@export var Cy := 1.4
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
@export var brake_force := 24000.0
@export var handbrake_strength := 1.0
@export var rear_grip_cut := 0.2

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
var _stalled := false               # A1: engine dead; restart via clutch-hold or bump-start
var _restart_t := 0.0               # A1: seconds the clutch has been held while stalled (starter timer)
var _blip_t := 0.0                  # A2: seconds left of the current downshift rev-match blip
var _ign_grace := 0.0               # A2: anti-stall grace after an [I] restart (the driver's reflex)
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
var _flash := 0.0                 # shift-light blink phase
var _drive_mode := 0              # 0 = AWD, 1 = RWD, 2 = FWD (cycle with T)
var _livery_mat: StandardMaterial3D
var _flare_mat: StandardMaterial3D
var surface_source               # set by world.gd; supplies grip_at(x,z) so asphalt grips > dirt > grass
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
	var slip_angle := 0.0
	var slip := 0.0                     # slip ratio magnitude (for terrain dig / dust / tracks)
	var util := 0.0
	var spin := 0.0                     # accumulated visual roll angle
	var omega := 0.0                    # wheel angular velocity (rad/s) - the drivetrain state
	var comp := 0.0                     # suspension compression (m) - for the anti-roll bars
	var temp := 20.0                    # M7: tyre core temperature (C)
	var tyre_wear := 0.0                # M7: wear 0 = new .. 1 = worn out
	var punctured := false              # M7: blown / flat -> big grip loss
	var tyre_grip := 1.0                # M7: temp * wear * puncture grip multiplier (folds into mu)

var _wheels: Array[Wheel] = []

func _ready() -> void:
	mass = chassis_mass
	gravity_scale = 1.0         # real gravity; air time is controlled by the (subtle) jump geometry
	can_sleep = false
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.45, 0)     # very low -> corner hard without tipping
	collision_layer = 2
	collision_mask = 1 | 4
	var pm := PhysicsMaterial.new(); pm.friction = 0.3
	physics_material_override = pm
	_build_body()
	_build_wheels()
	respawn()
	_apply_mode()               # the car now casts a real (sun/directional) shadow again

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
	center_of_mass = Vector3(0, -0.45, _com_bias())   # shift weight toward the driven axle
	if _livery_mat != null:
		_livery_mat.albedo_color = MODE_COLORS[_drive_mode]
	if _flare_mat != null:
		_flare_mat.albedo_color = MODE_COLORS[_drive_mode].darkened(0.28)

func _rev_color(t: float) -> Color:
	if t < 0.5: return Color(0.15, 0.9, 0.15)      # green
	if t < 0.78: return Color(0.95, 0.82, 0.1)     # yellow
	return Color(0.95, 0.12, 0.1)                  # red (redline zone)

func _build_revbar() -> void:
	# in-cabin rev bar on the dash: segments light green->yellow->red with rpm, + a flashing shift light
	var n := 14
	var seg_w := 0.02
	var gap := 0.005
	var total := n * seg_w + (n - 1) * gap
	var y := 0.57          # on the small binnacle box, close to the wheel
	var z := -0.19         # binnacle near face (toward the driver) -- much closer than the main dash
	var x0 := -0.35 - total * 0.5
	for i in range(n):
		var col := _rev_color(float(i) / float(n - 1))
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = col.darkened(0.8)         # dim when unlit
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = 0.0         # off until rpm lights it
		var seg := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = Vector3(seg_w, 0.042, 0.01)
		seg.mesh = bm
		seg.material_override = m
		seg.position = Vector3(x0 + i * (seg_w + gap) + seg_w * 0.5, y, z)
		seg.rotation_degrees = Vector3(48, 0, 0)   # stand it up on the binnacle face, toward the driver
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(seg)
		_rev_segs.append({"mat": m, "col": col})
	# shift light: a red disc above the bar, flashes near the shift point
	_shift_mat = StandardMaterial3D.new()
	_shift_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shift_mat.albedo_color = Color(0.2, 0.0, 0.0)
	_shift_mat.emission_enabled = true
	_shift_mat.emission = Color(1.0, 0.06, 0.06)
	_shift_mat.emission_energy_multiplier = 0.0
	var light := MeshInstance3D.new()
	var cyl := CylinderMesh.new(); cyl.top_radius = 0.019; cyl.bottom_radius = 0.019; cyl.height = 0.008
	light.mesh = cyl
	light.material_override = _shift_mat
	light.position = Vector3(-0.35, y + 0.05, z)
	light.rotation_degrees = Vector3(90, 0, 0)     # flat face toward the driver
	light.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(light)

func _build_body() -> void:
	# Physics collision stays a single box; all the detail below is cosmetic (forward = -Z).
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new(); box.size = body_size
	col.shape = box; add_child(col)
	_build_shell()
	_build_cockpit()
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
	_part(Vector3(0.4, 0.12, 0.18), Vector3(-0.35, 0.54, -0.3), _mat(Color(0.02, 0.02, 0.03)), Vector3(16, 0, 0))
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
	var hi := 60.0
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
	center_of_mass = Vector3(0, -0.45, _com_bias())   # re-applied so live bias tuning takes effect

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

	# --- suspension + tire-frame pass ---
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
		w.contact_point = hit_pos
		var n: Vector3 = hit.normal
		w.contact_normal = n
		var compression := clampf((rest_length + wheel_radius) - mount_world.distance_to(hit_pos), 0.0, max_travel)
		var contact_off := hit_pos - global_position
		var pv := linear_velocity + angular_velocity.cross(contact_off)
		var comp_vel := clampf(-pv.dot(up), -3.0, 3.0)
		var Fz := clampf(spring_k * compression + damper_c * comp_vel, 0.0, 20000.0)
		w.Fz = Fz
		w.comp = compression                              # deferred: anti-roll bars adjust Fz, applied below
		var fwd := -global_transform.basis.z
		if w.steer: fwd = fwd.rotated(up, steer_angle)
		fwd = (fwd - n * fwd.dot(n)).normalized()
		var right := n.cross(fwd).normalized()
		info[w] = {"fwd": fwd, "right": right, "off": contact_off, "hit": hit_pos,
			"v_long": pv.dot(fwd), "v_lat": pv.dot(right)}

	# anti-roll bars transfer load across each axle, then apply the roll-balanced vertical load
	_apply_arb(0, 1, arb_front)      # front pair (wheels FL, FR)
	_apply_arb(2, 3, arb_rear)       # rear pair (wheels RL, RR)
	for w in _wheels:
		if w.contact:
			apply_force(w.contact_normal * w.Fz, info[w]["off"])

	# --- gearbox (manual: E up, Q down). A1: _gear -1 = reverse, 0 = NEUTRAL, 1..N = forward ---
	var shifted := false
	var downshifted := false
	if Input.is_action_just_pressed("shift_up") and _gear < gear_ratios.size():
		_gear += 1
		shifted = true
	if Input.is_action_just_pressed("shift_down") and _gear > -1:
		_gear -= 1
		shifted = true
		downshifted = true
	var reverse := _gear == -1
	var neutral := _gear == 0
	var gr := 0.0                    # engine:wheel gear ratio (0 in neutral = no coupling)
	if reverse:
		gr = reverse_ratio
	elif _gear > 0:
		gr = gear_ratios[_gear - 1]
	if shifted:
		# A2: a ratio swap is a real speed mismatch - break the kinematic lock so the clutch
		# resolves it: engine drags to the new speed THROUGH the plates (the downshift jolt),
		# instead of teleporting rpm for free. The blip below revs it there smoothly instead.
		_clutch_locked = false
		if downshifted and auto_blip and not manual_clutch and _gear > 0 and linear_velocity.length() > 3.0:
			# heel-toe event order: the foot is ALREADY down when the new ratio engages, so the
			# plates are open at the swap - otherwise their drag out-races the blip and the revs
			# get ground up through the wheels (the exact jolt the blip exists to avoid)
			_blip_t = BLIP_TIME
			_clutch = 0.0

	# drive mode: AWD uses torque_split, RWD forces all-rear, FWD forces all-front
	if Input.is_action_just_pressed("drive_mode"):
		_drive_mode = (_drive_mode + 1) % 3
		_apply_mode()
	var eff_split := torque_split
	if _drive_mode == 1: eff_split = 1.0
	elif _drive_mode == 2: eff_split = 0.0

	# --- clutch engagement (A1). Manual: LEFT SHIFT is the pedal (held = open). Auto: engagement
	# is scheduled from rpm - it feeds in between idle and bite_rpm, so a launch slips the clutch
	# and SELF-BALANCES (revs sink -> capacity sinks) the way a driver's foot does. Anti-stall
	# (and auto mode always) opens the clutch as rpm falls toward the stall floor (half idle,
	# where combustion dies - see _engine_torque).
	var rpm_pre := _omega_e * 60.0 / TAU
	_blip_t = maxf(_blip_t - delta, 0.0)
	_ign_grace = maxf(_ign_grace - delta, 0.0)
	var c_target: float
	if manual_clutch:
		c_target = 1.0 - Input.get_action_strength("clutch")
	else:
		c_target = clampf((rpm_pre - idle_rpm) / maxf(bite_rpm - idle_rpm, 1.0), 0.0, 1.0)
		if _blip_t > 0.0:
			c_target = 0.0           # A2: hold the clutch in while the blip matches revs
	if anti_stall or not manual_clutch or _ign_grace > 0.0:
		c_target = minf(c_target, clampf((rpm_pre - idle_rpm * 0.55) / (idle_rpm * 0.35), 0.0, 1.0))
	var c_rate := CLUTCH_OUT_RATE if c_target < _clutch else CLUTCH_IN_RATE
	_clutch = move_toward(_clutch, c_target, c_rate * delta)

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
	# motoring-friction line T_fric(w) = c0 + c1*w fit through the two physical anchor points
	var w_idle := idle_rpm * TAU / 60.0
	var w_red := redline_rpm * TAU / 60.0
	var fric_c1 := (engine_brake_redline - engine_brake_idle) / maxf(w_red - w_idle, 1.0)
	var fric_c0 := engine_brake_idle - fric_c1 * w_idle
	var ratio := gr * final_drive                        # engine:wheel ratio (0 in neutral)
	var t_cap := _clutch * clutch_margin * peak_torque   # torque the clutch plates can carry
	var fx_sum := {}
	for wj in _wheels:
		fx_sum[wj] = 0.0
	for _s in range(drive_substeps):
		# wheel-side coupling speed: signed average spin of the torque-receiving wheels
		var dsum := 0.0
		var dn := 0.0
		for wj in _wheels:
			var sh := (1.0 - eff_split) if wj.steer else eff_split
			if sh > 0.001:
				dsum += wj.omega
				dn += 1.0
		var wavg := dsum / maxf(dn, 1.0)
		var omega_gb := wavg * ratio * gsign     # engine-side speed of the gearbox input
		if neutral:
			_clutch_locked = false
		elif _clutch_locked:
			# locked: the engine IS the wheels through the gear (never backwards, valve-float ceiling)
			_omega_e = clampf(omega_gb, 0.0, w_red * 1.35)
			if absf(omega_gb - _omega_e) > CLUTCH_LOCK_BAND:
				_clutch_locked = false           # the follow hit a physical limit -> plates must slip
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
			var blip_thr := 0.0
			if _blip_t > 0.0:
				if _omega_e >= omega_gb:
					_blip_t = 0.0            # matched -> end the blip, the clutch feeds back in
				elif _clutch <= 0.15:
					# proper heel-toe order: only blip once the plates are OPEN, so the spin-up
					# torque never drags the wheels (the engine revs faster than the clutch moves)
					blip_thr = clampf((omega_gb - _omega_e) / BLIP_BAND, 0.0, 1.0)
			t_target = _engine_torque(rpm) * maxf(throttle, maxf(idle_thr, blip_thr)) * rev_cut * (1.0 - damage_power_loss * _damage) * _tc_scale
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
		var k_centre := 0.0
		if _drive_mode == 0:
			var wf := (_wheels[0].omega + _wheels[1].omega) * 0.5
			var wr := (_wheels[2].omega + _wheels[3].omega) * 0.5
			var dwc := wf - wr
			var thc := tanh(dwc / DIFF_BAND)
			var t_c := centre_preload * thc + centre_coupling * dwc
			# impulse cap, like the axle diffs: the coupling can equalise the axles within one
			# substep but never swing them past each other (kills saturated-Coulomb chatter)
			var c_lim := absf(dwc) * wheel_inertia / dt_sub
			t_c = clampf(t_c, -c_lim, c_lim)
			t_front -= t_c
			t_rear += t_c
			# each wheel sees a quarter of the coupling's slope (half per axle, half per wheel)
			k_centre = 0.25 * (centre_coupling + centre_preload * (1.0 - thc * thc) / DIFF_BAND)
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
				t_brk += brake_torque * handbrake_strength
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

	# stall & restart (A1): only a LOADED engine can stall, and only with the safety nets off.
	# Restart: hold the clutch (or find N) ~0.5 s and the starter re-fires it at idle; or
	# bump-start by releasing the clutch in gear while rolling (the wheels spin it back to life).
	if not _stalled and manual_clutch and not anti_stall and not neutral and _clutch > 0.1 and _engine_rpm < idle_rpm * 0.5 and _ign_grace <= 0.0:
		_stalled = true
	if _stalled:
		_t_comb = 0.0
		if Input.is_action_just_pressed("ignition"):
			_stalled = false                     # [I] starter: fire straight back to idle...
			_omega_e = idle_rpm * TAU / 60.0
			_engine_rpm = idle_rpm
			_restart_t = 0.0
			_clutch = 0.0                        # ...with the driver's restart reflex: clutch stabbed
			_clutch_locked = false               # in, plus a moment of anti-stall grace to get going
			_ign_grace = 1.2
		elif _clutch < 0.05 or neutral:
			_restart_t += delta
			if _restart_t > 0.5:
				_stalled = false
				_omega_e = idle_rpm * TAU / 60.0
				_engine_rpm = idle_rpm
				_restart_t = 0.0
		else:
			_restart_t = 0.0
			if _engine_rpm > idle_rpm * 0.6:     # spun fast enough by the wheels -> combustion catches
				_stalled = false

	# --- apply the averaged longitudinal + the lateral (slip-angle) force per contact wheel ---
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
		var Fy := -_mf(w.slip_angle, By, Cy, Ey, muy * Fz)
		if handbrake > 0.0 and not w.steer:
			Fy *= rear_grip_cut
		# elliptical combined-slip limit
		var nx := Fx / (mux * Fz + 0.001)
		var ny := Fy / (muy * Fz + 0.001)
		var e := sqrt(nx * nx + ny * ny)
		if e > 1.0:
			Fx /= e
			Fy /= e
		w.util = minf(e, 1.0)
		w.slip = clampf(absf((w.omega * wheel_radius - v_long) / maxf(absf(v_long), slip_ref_speed)), 0.0, 3.0)
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

	if speed > 0.1:
		apply_central_force(-linear_velocity.normalized() * drag_k * linear_velocity.length_squared())

	# M7: engine temperature (gauge for the component HUD) - heats with load, cools with airflow
	var eload := clampf(_engine_rpm / maxf(redline_rpm, 1.0), 0.0, 1.2) * (0.35 + 0.65 * throttle)
	_engine_temp += engine_heat_rate * eload * delta
	_engine_temp -= engine_cool_rate * (_engine_temp - ambient_temp) * (1.0 + speed / 50.0) * delta
	_engine_temp = clampf(_engine_temp, ambient_temp, 135.0)

	_prev_vel = linear_velocity     # M8: for next frame's impact detection

func respawn() -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = spawn_transform
	_gear = 1; _engine_rpm = idle_rpm; _engine_temp = ambient_temp
	_omega_e = idle_rpm * TAU / 60.0; _t_comb = 0.0; _tc_scale = 1.0            # A1: engine state
	_clutch = 0.0; _clutch_locked = false; _stalled = false; _restart_t = 0.0   # A1: clutch state
	_blip_t = 0.0; _ign_grace = 0.0                                            # A2: blip + starter grace
	_throttle_pedal = 0.0; _brake_pedal = 0.0   # Phase 0: virtual pedals
	_damage = 0.0; _pull_dir = 0.0; _prev_vel = Vector3.ZERO   # M8: repaired on respawn
	for w in _wheels:
		w.spin = 0.0
		w.omega = 0.0
		w.kappa = 0.0
		w.temp = ambient_temp      # M7: fresh tyres on respawn
		w.tyre_wear = 0.0
		w.punctured = false
		w.tyre_grip = 1.0

func get_wheels() -> Array[Wheel]:
	return _wheels

func get_engine() -> Dictionary:
	return {"rpm": _engine_rpm, "gear": _gear, "speed_kmh": linear_velocity.length() * 3.6, "mode": MODE_NAMES[_drive_mode], "temp": _engine_temp, "damage": _damage, "clutch": _clutch, "stalled": _stalled}
