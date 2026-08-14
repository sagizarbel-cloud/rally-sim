extends Node3D
class_name SurfaceEffects
## M11 - surface effects in THREE layers, each with its own physical cause:
##
##   1. SMOKE (hard surfaces)  - white-grey burnt rubber, from drifts and hard stops.
##   2. PLUME (loose surfaces) - the big billowing cloud a rally car drags behind it on gravel.
##   3. GRIT  (loose surfaces) - the small stones and sand thrown ballistically from the tyre.
##
## They are separate because they are separate phenomena, not one effect at three sizes. A car
## cruising a gravel straight throws a PLUME and no grit (the tyre shears loose material just by
## rolling over it); a car spinning its wheels throws GRIT hard and adds to the plume; a car on
## tarmac throws neither and smokes instead.
##
## Everything is driven by quantities the physics already computes - contact-patch slip velocity,
## vertical load, tyre temperature, friction power - so the effects show the tuned model rather
## than decorating it.

var car                              # untyped so get_wheels() resolves dynamically
var stage                            # RallyStage: grip_at() + _surface_color()

# --- what counts as "working the surface" -------------------------------------------------
@export var slip_ref := 6.0          # m/s of contact-patch slip for full-intensity effects
@export var slip_floor := 0.8        # m/s below which a tyre is gripping and throws nothing
@export var asphalt_grip := 1.2      # base grip above this = a hard surface: smoke, no dust
# --- 1. tyre smoke (hard surfaces) --------------------------------------------------------
# Smoke has TWO causes and needs both. A long drift smokes because the tread got hot; a hard stop
# smokes instantly on COLD tyres because a locked patch dumps enormous friction power in a
# fraction of a second. Temperature lags that by seconds - the smoke does not.
@export var smoke_temp := 110.0      # C at which the tread starts to smoke (M7 optimum is 85)
@export var smoke_full_temp := 165.0 # C at which heat alone smokes as hard as it ever will
@export var smoke_power_ref := 45000.0  # W of friction power at the patch for full smoke, cold
@export var smoke_amount := 40
@export var smoke_lifetime := 2.1
@export var smoke_size := 0.30
@export var smoke_color := Color(0.90, 0.90, 0.92)   # white-grey burnt rubber
# --- 2. dust plume (loose surfaces) -------------------------------------------------------
# A gravel car trails a plume even in a straight line at constant throttle, because the tyre
# shears loose material simply by rolling over it - the rate scales with how much surface passes
# under the contact patch, i.e. with SPEED. Sliding adds to it but is not required.
@export var plume_amount := 60
@export var plume_lifetime := 2.8    # s - a plume hangs in the air long after the car has gone
@export var plume_size := 0.85       # m - big, soft, slow
@export var plume_speed_ref := 28.0  # m/s (~100 km/h) at which rolling alone makes a full plume
@export var plume_back := 2.4        # m behind the car's centre that the cloud is born
@export var plume_rise := 1.6        # m/s - barely buoyant; it billows rather than shoots
# --- 3. grit (loose surfaces) -------------------------------------------------------------
@export var grit_amount := 30
@export var grit_lifetime := 0.55    # s - stones are ballistic and land quickly
@export var grit_size := 0.055       # m - specks, not clods
@export var grit_speed := 9.0        # m/s thrown at full slip
@export var grit_gravity := -19.0    # heavy: they arc and fall, they do not float
# --- skid marks ---------------------------------------------------------------------------
@export var mark_pool := 900
@export var mark_fade := 14.0
@export var mark_interval := 0.03
# --- shared ---------------------------------------------------------------------------------
@export var blob_variants := 5       # distinct procedural puff sprites
@export var attack := 0.18           # s for an effect to swell up to a new intensity
@export var release := 1.60          # s for a CLOUD to die back down - long on purpose, see _smooth
@export var release_grit := 0.14     # s for GRIT: stones are discrete, they stop when the slip does
@export var shaded := true           # particles take the sun like the ground does (see _make_emitter)

var _smoke: Array = []
var _grit: Array = []
var _plume: CPUParticles3D
var _blobs: Array[ImageTexture] = []
var _mm: MultiMesh
var _mark_next := 0
var _marks: Array = []
var _lay_accum := 0.0
var _sm_smoke := [0.0, 0.0, 0.0, 0.0]     # smoothed intensities - see _smooth()
var _sm_grit := [0.0, 0.0, 0.0, 0.0]
var _sm_plume := 0.0

func _ready() -> void:
	for b in range(blob_variants):
		_blobs.append(_make_blob(1000 + b * 977))
	for i in range(4):
		_smoke.append(_make_emitter(smoke_amount, smoke_lifetime, smoke_color, -0.7, smoke_size, i + 2, 2))
		_grit.append(_make_emitter(grit_amount, grit_lifetime, Color(0.55, 0.47, 0.34), grit_gravity, grit_size, i, 0))
	_plume = _make_emitter(plume_amount, plume_lifetime, Color(0.56, 0.48, 0.34), -0.9, plume_size, 1, 1)
	_plume.spread = 30.0
	for g in _grit:
		g.spread = 26.0                    # stones fly in a tight fan, not a cloud
		g.damping_min = 0.0                # and they are ballistic: no air drag worth modelling
		g.damping_max = 0.4
		g.color_ramp = null                # no fade-in; a stone is there the instant it leaves
	_build_marks()

func _make_blob(seed_v: int) -> ImageTexture:
	# A procedural puff sprite: soft-edged and IRREGULAR, so particles do not read as a cloud of
	# identical squares. Each variant gets its own lobed silhouette and internal mottling from its
	# own seed. Generated in code like everything else here - no image assets.
	var n := 48
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var l1 := rng.randf_range(0.16, 0.40)
	var l2 := rng.randf_range(0.08, 0.26)
	var p1 := rng.randf_range(0.0, TAU)
	var p2 := rng.randf_range(0.0, TAU)
	var k1 := float(rng.randi_range(2, 4))
	var k2 := float(rng.randi_range(5, 8))
	var m1 := rng.randf_range(0.0, TAU)
	for y in range(n):
		for x in range(n):
			var dx := (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var dy := (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var r := sqrt(dx * dx + dy * dy)
			var th := atan2(dy, dx)
			var edge := 1.0 + l1 * sin(k1 * th + p1) + l2 * sin(k2 * th + p2)
			var a := clampf(1.0 - r / maxf(edge * 0.94, 0.05), 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)
			a *= 0.80 + 0.20 * sin(6.0 * th + m1 + 9.0 * r)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)

func _make_emitter(amount: int, life: float, col: Color, gravity: float, size: float, variant: int, prio: int) -> CPUParticles3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	# SHADED, not unshaded: the ground is lit by the sun and the time-of-day cycle, so unshaded
	# particles drift out of step with it - they stay bright at dusk and glow at night. Billboard
	# normals face the camera, which for soft dust reads fine and keeps it in the same light.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if shaded else BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _blobs[variant % _blobs.size()]
	# Transparent surfaces are sorted per object, so smoke drifting over a skid mark could flip
	# behind it and back. An explicit priority pins the order: marks (-1) under grit, plume, smoke.
	mat.render_priority = prio
	mesh.material = mat
	var p := CPUParticles3D.new()
	p.mesh = mesh
	p.emitting = false
	p.amount = amount
	p.lifetime = life
	p.lifetime_randomness = 0.45
	p.direction = Vector3.UP
	p.spread = 42.0
	p.gravity = Vector3(0, gravity, 0)
	p.color = col
	p.scale_amount_min = 0.35
	p.scale_amount_max = 1.7
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.angular_velocity_min = -55.0
	p.angular_velocity_max = 55.0
	p.damping_min = 1.4
	p.damping_max = 3.2
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0.0))
	ramp.set_color(1, Color(1, 1, 1, 0.0))
	ramp.add_point(0.12, Color(1, 1, 1, 1.0))
	ramp.add_point(0.45, Color(1, 1, 1, 0.85))
	p.color_ramp = ramp
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.local_coords = false
	add_child(p)
	return p

func _build_marks() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	var quad := PlaneMesh.new()
	quad.size = Vector2(0.26, 0.95)
	_mm.mesh = quad
	_mm.instance_count = mark_pool
	for i in range(mark_pool):
		_mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0, -1000.0, 0)))
		_mm.set_instance_color(i, Color(0, 0, 0, 0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if shaded else BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = -1              # always under the particles
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

# --- physical drivers ----------------------------------------------------------------------

func slip_speed(w, v: float) -> float:
	# How fast the rubber slides across the ground, m/s: the longitudinal component from the slip
	# ratio and the lateral one from the slip angle. This is what tears material off a tyre.
	var long_slip: float = absf(float(w.kappa)) * maxf(v, 2.0)
	var lat_slip: float = absf(sin(float(w.slip_angle))) * v
	return sqrt(long_slip * long_slip + lat_slip * lat_slip)

func intensity(w, v: float, fz_ref: float) -> float:
	var s: float = slip_speed(w, v)
	if s < slip_floor:
		return 0.0
	var load: float = clampf(float(w.Fz) / maxf(fz_ref, 1.0), 0.0, 1.6)
	return clampf((s - slip_floor) / maxf(slip_ref - slip_floor, 0.1), 0.0, 1.0) * load

func smoke_frac(temp: float, fz: float, vslip: float, grip: float) -> float:
	var thermal := clampf((temp - smoke_temp) / maxf(smoke_full_temp - smoke_temp, 1.0), 0.0, 1.0)
	var power := clampf(grip * fz * vslip / maxf(smoke_power_ref, 1.0), 0.0, 1.0)
	return maxf(thermal, power)

func plume_frac(v: float, slip_amt: float) -> float:
	# Rolling shears material out of a loose surface on its own, so speed alone raises a plume;
	# sliding throws more on top. This is why a gravel car trails a cloud down a straight.
	var roll := clampf(v / maxf(plume_speed_ref, 1.0), 0.0, 1.0)
	return clampf(0.55 * roll + 0.75 * slip_amt, 0.0, 1.0)

func _smooth(prev: float, target: float, dt: float, rel: float = -1.0) -> float:
	# The single most important line for how this LOOKS. CPUParticles3D.color is a uniform over
	# the whole system, not a per-particle value, so writing it from a raw per-frame intensity
	# re-tints every live particle at once - and under braking the load pumps through the bump
	# stops at a few Hz, which showed up as the whole cloud flickering in brightness. Smoothing
	# the driving signal (fast to swell, slower to fade, like a real cloud) removes it entirely.
	# Fast attack, SLOW release - an envelope follower, not a symmetric filter. The asymmetry is
	# the point: the cloud must swell the instant a slide starts (or it feels disconnected), but
	# must not dip on every trough of a few-Hz load oscillation. A symmetric filter fast enough to
	# attack well is fast enough to flicker; this one rides over the dips and only fades when the
	# slip has genuinely stopped. Grit passes a short release, because stones are discrete: they
	# stop the moment the wheel stops throwing them, and a lingering trickle of gravel looks wrong.
	var tau: float = attack if target > prev else (release if rel < 0.0 else rel)
	return move_toward(prev, target, dt / maxf(tau, 0.01))

func ground_color(x: float, z: float) -> Color:
	# The colour the player actually SEES at that spot - which is not the terrain's own colour
	# wherever the wear line has been painted over it. wear.gd tints the driven line toward a dark
	# worn brown, and the car spends its life on exactly that line, so sampling the base terrain
	# gave dust that was far too pale for the ground it came off. The wear fraction is recovered
	# from the grip the wear node reports versus the stage's base grip - no extra plumbing, and it
	# stays correct if wear.gd's tuning changes.
	var base := Color(0.56, 0.48, 0.34)
	if stage != null and stage.has_method("_surface_color"):
		base = stage._surface_color(x, z)
	var src = car.surface_source if car != null and car.get("surface_source") != null else null
	if src != null and src != stage and src.has_method("grip_at") and src.get("wear_grip") != null:
		var g0: float = stage.grip_at(x, z)
		var g1: float = src.grip_at(x, z)
		var wg: float = float(src.wear_grip)
		if g0 > 0.001 and absf(wg) > 0.001:
			var wn: float = clampf((g1 / g0 - 1.0) / wg, 0.0, 1.0)
			base = base.lerp(Color(0.08, 0.055, 0.04), clampf(wn * 1.05, 0.0, 0.84))
	return base

# --- per-frame ----------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_fade_marks(delta)
	if car == null or stage == null:
		return
	var wheels: Array = car.get_wheels()
	if wheels.is_empty():
		return
	var v: float = car.linear_velocity.length()
	var mass := 1250.0
	if car.get("chassis_mass") != null:
		mass = float(car.chassis_mass)
	var fz_ref: float = mass * 9.81 * 0.25
	_lay_accum += delta
	var lay := _lay_accum > mark_interval
	if lay:
		_lay_accum = 0.0
	var fwd: Vector3 = -car.global_transform.basis.z
	var travel: Vector3 = car.linear_velocity
	var back: Vector3 = -travel.normalized() if travel.length() > 1.0 else -fwd
	var kick: Vector3 = (Vector3.UP + back * 0.65).normalized()
	var loose_amt := 0.0
	var loose_col := Color(0.56, 0.48, 0.34)
	var loose_pos := Vector3.ZERO
	var loose_n := 0

	for i in range(mini(wheels.size(), 4)):
		var w = wheels[i]
		if not w.contact:
			_smoke[i].emitting = false
			_grit[i].emitting = false
			continue
		var cp: Vector3 = w.contact_point
		var grip: float = stage.grip_at(cp.x, cp.z)
		var amt: float = intensity(w, v, fz_ref)
		var vs: float = slip_speed(w, v)
		if grip > asphalt_grip:
			_grit[i].emitting = false
			# smoke is gated on its OWN physics, not on `amt`: a locked wheel in a hard stop is the
			# smokiest thing a tyre does, and it is barely "slipping" by the intensity measure
			var sf: float = smoke_frac(float(w.temp), float(w.Fz), vs, grip)
			_sm_smoke[i] = _smooth(_sm_smoke[i], sf, delta)
			_drive(_smoke[i], cp, _sm_smoke[i], 1.5, smoke_color, kick, 0.55)
			if lay and amt > 0.12:
				_lay_mark(cp, w.contact_normal, fwd, clampf(amt, 0.0, 1.0))
		else:
			_smoke[i].emitting = false
			var col := ground_color(cp.x, cp.z)
			_sm_grit[i] = _smooth(_sm_grit[i], amt, delta, release_grit)
			_drive(_grit[i], cp, _sm_grit[i], grit_speed, col.darkened(0.10), kick, 0.95)
			loose_amt = maxf(loose_amt, amt)
			loose_col = col
			loose_pos += cp
			loose_n += 1

	# the plume is a property of the CAR on a loose surface, not of any one wheel
	if loose_n > 0:
		var target: float = plume_frac(v, loose_amt)
		_sm_plume = _smooth(_sm_plume, target, delta)
		var origin: Vector3 = loose_pos / float(loose_n) + back * plume_back + Vector3.UP * 0.25
		_drive(_plume, origin, _sm_plume, plume_rise, loose_col.lightened(0.06), kick, 0.34)
	else:
		_sm_plume = _smooth(_sm_plume, 0.0, delta)
		_drive(_plume, _plume.global_position, _sm_plume, plume_rise, loose_col, kick, 0.34)

func _drive(p: CPUParticles3D, cp: Vector3, amt: float, rise: float, col: Color, kick: Vector3, alpha_max: float) -> void:
	if amt <= 0.01:
		p.emitting = false
		return
	p.global_position = cp
	p.direction = kick if kick.length() > 0.01 else Vector3.UP
	p.initial_velocity_min = rise * 0.30 * amt
	p.initial_velocity_max = rise * amt
	p.scale_amount_min = 0.30 + 0.25 * amt
	p.scale_amount_max = 0.9 + 1.3 * amt
	col.a = clampf(0.18 + (alpha_max - 0.18) * amt, 0.0, alpha_max)
	p.color = col
	p.emitting = true

func _lay_mark(pos: Vector3, nrm: Vector3, fwd: Vector3, amt: float) -> void:
	var y := nrm.normalized()
	var zc := fwd - y * fwd.dot(y)
	zc = zc.normalized() if zc.length() > 0.01 else Vector3.FORWARD
	var xc := y.cross(zc).normalized()
	zc = xc.cross(y).normalized()
	var idx := _mark_next
	_mark_next = (_mark_next + 1) % mark_pool
	_mm.set_instance_transform(idx, Transform3D(Basis(xc, y, zc), pos + y * 0.02))
	var a: float = clampf(0.30 + 0.45 * amt, 0.0, 0.85)
	_mm.set_instance_color(idx, Color(0.08, 0.06, 0.05, a))
	_marks.append({"i": idx, "t": 0.0, "a": a})

func _fade_marks(delta: float) -> void:
	if _mm == null:
		return
	var keep: Array = []
	for m in _marks:
		m["t"] += delta
		var k: float = 1.0 - m["t"] / maxf(mark_fade, 0.01)
		if k <= 0.0:
			_mm.set_instance_color(m["i"], Color(0, 0, 0, 0))
			continue
		_mm.set_instance_color(m["i"], Color(0.08, 0.06, 0.05, m["a"] * k))
		keep.append(m)
	_marks = keep
