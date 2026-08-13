extends Node3D
class_name SurfaceEffects
## M11 - surface-aware dust, tyre smoke and skid marks, driven by the slip the physics already
## computes. Self-contained: it reads the car and the stage and owns all its own visuals, so
## nothing else has to know it exists.
##
## The point of this milestone is to make the TUNED PHYSICS VISIBLE. So nothing here is triggered
## by a magic threshold on "is the wheel spinning" - every effect is driven by a physical quantity
## that already exists in the model:
##
##   - CONTACT-PATCH SLIP VELOCITY (m/s) - how fast the rubber is actually sliding over the
##     ground, from the wheel's own slip ratio and slip angle. This covers wheelspin AND a
##     sideways slide with the same number, which the old `slip > 0.35` test could not.
##   - LOAD - a lightly-loaded wheel throws less material than a heavily-loaded one.
##   - TYRE TEMPERATURE - rubber smoke is thermal. A tyre does not smoke because it is sliding,
##     it smokes because sliding has made it hot enough, which is why a cold lock-up puffs and a
##     long drift billows. M7 already models per-tyre temperature, so smoke reads it.
##
## Surface ownership follows the M6 design call: DIRT throws dust and marks the wear line (that's
## wear.gd's job, not this node's); ASPHALT smokes and lays skid marks.

var car                              # untyped so get_wheels() resolves dynamically
var stage                            # RallyStage: grip_at() + _surface_color()

# --- what counts as "working the surface" -------------------------------------------------
@export var slip_ref := 6.0          # m/s of contact-patch slip for full-intensity effects
@export var slip_floor := 0.8        # m/s below which nothing is emitted at all (tyre is gripping)
@export var asphalt_grip := 1.2      # base grip above this = a hard surface: smoke + marks, no dust
# --- dust (loose surfaces) ----------------------------------------------------------------
@export var dust_amount := 44        # many small particles read as dust; few big ones read as debris
@export var dust_lifetime := 1.1     # s - dust hangs, it does not vanish
@export var dust_rise := 3.2         # m/s upward kick at full intensity
@export var dust_size := 0.20        # m - base particle size before per-particle scale variation
@export var dust_trail := 0.65       # how much of the kick goes BACKWARD along travel vs straight up
# --- tyre smoke (hard surfaces) -----------------------------------------------------------
# Smoke has TWO causes and needs both. A long drift smokes because the tread got hot (thermal),
# but a hard stop smokes instantly on cold tyres because a locked contact patch dumps enormous
# friction POWER in a fraction of a second. Gating on temperature alone missed the whole braking
# case - the tyre had not had time to heat up yet, which is exactly when you see the most smoke.
@export var smoke_temp := 110.0      # C at which the tread starts to smoke (M7 optimum is 85)
@export var smoke_full_temp := 165.0 # C at which heat alone smokes as hard as it ever will
@export var smoke_power_ref := 45000.0  # W of friction power at the patch for full smoke, cold
@export var smoke_amount := 40
@export var smoke_lifetime := 2.1    # s - smoke lingers much longer than dust
@export var smoke_size := 0.30       # m - starts small and swells, the way smoke does
@export var smoke_color := Color(0.90, 0.90, 0.92)   # white-grey burnt rubber over asphalt
# --- particle shape -----------------------------------------------------------------------
@export var blob_variants := 5       # distinct procedural puff sprites; emitters pick between them
# --- skid marks ---------------------------------------------------------------------------
@export var mark_pool := 900         # ring buffer of quads (one MultiMesh, one draw call)
@export var mark_fade := 14.0        # s for a mark to fade out - "longer-lasting" per M11
@export var mark_interval := 0.03    # s between marks laid by one wheel

var _dust: Array = []
var _smoke: Array = []
var _mm: MultiMesh
var _mark_next := 0
var _marks: Array = []               # active marks: {"i": index, "t": age, "a": peak alpha}
var _lay_accum := 0.0

var _blobs: Array[ImageTexture] = []

func _ready() -> void:
	for b in range(blob_variants):
		_blobs.append(_make_blob(1000 + b * 977))
	for i in range(4):
		_dust.append(_make_emitter(dust_amount, dust_lifetime, Color(0.56, 0.48, 0.34), -9.0, dust_size, i))
		_smoke.append(_make_emitter(smoke_amount, smoke_lifetime, smoke_color, -0.7, smoke_size, i + 2))
	_build_marks()

func _make_blob(seed_v: int) -> ImageTexture:
	# A procedural puff sprite: soft-edged, and IRREGULAR, so particles do not read as a cloud of
	# identical squares. Each variant gets its own lobed silhouette and internal mottling from its
	# own seed, so the set looks like different scraps of dust rather than one shape repeated.
	# Generated in code like everything else here - no image assets to ship or import.
	var n := 48
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var l1 := rng.randf_range(0.16, 0.40)          # two lobe harmonics dent the outline
	var l2 := rng.randf_range(0.08, 0.26)
	var p1 := rng.randf_range(0.0, TAU)
	var p2 := rng.randf_range(0.0, TAU)
	var k1 := float(rng.randi_range(2, 4))
	var k2 := float(rng.randi_range(5, 8))
	var m1 := rng.randf_range(0.0, TAU)            # and a mottle phase for the interior
	for y in range(n):
		for x in range(n):
			var dx := (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var dy := (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var r := sqrt(dx * dx + dy * dy)
			var th := atan2(dy, dx)
			var edge := 1.0 + l1 * sin(k1 * th + p1) + l2 * sin(k2 * th + p2)
			var a := clampf(1.0 - r / maxf(edge * 0.94, 0.05), 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)            # smoothstep: a soft shoulder, never a hard rim
			a *= 0.80 + 0.20 * sin(6.0 * th + m1 + 9.0 * r)   # wispy, uneven density
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)

func _make_emitter(amount: int, life: float, col: Color, gravity: float, size: float, variant: int) -> CPUParticles3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _blobs[variant % _blobs.size()]
	mesh.material = mat
	var p := CPUParticles3D.new()
	p.mesh = mesh
	p.emitting = false
	p.amount = amount
	p.lifetime = life
	p.lifetime_randomness = 0.45            # they must not all die on the same frame
	p.direction = Vector3.UP
	p.spread = 42.0
	p.gravity = Vector3(0, gravity, 0)      # dust settles back down; smoke is near-buoyant
	p.color = col
	p.scale_amount_min = 0.35               # a wide spread of sizes, so no two puffs match
	p.scale_amount_max = 1.7
	p.angle_min = -180.0                    # each sprite starts at its own rotation...
	p.angle_max = 180.0
	p.angular_velocity_min = -55.0          # ...and keeps turning, so the set never repeats
	p.angular_velocity_max = 55.0
	p.damping_min = 1.4                     # air drag: dust loses its kick fast and hangs
	p.damping_max = 3.2
	var ramp := Gradient.new()              # fade in, then dissolve - dust does not blink out
	ramp.set_color(0, Color(1, 1, 1, 0.0))
	ramp.set_color(1, Color(1, 1, 1, 0.0))
	ramp.add_point(0.12, Color(1, 1, 1, 1.0))
	ramp.add_point(0.45, Color(1, 1, 1, 0.85))
	p.color_ramp = ramp
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.local_coords = false                  # particles stay where they were born, not glued to the wheel
	add_child(p)
	return p

func _build_marks() -> void:
	# One MultiMesh instead of 900 nodes, with per-instance colour so each mark can fade on its
	# own. The old pool recycled quads with no fade, so a mark vanished mid-corner as the buffer
	# wrapped; fading means the oldest simply thins out.
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
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

func slip_speed(w, v: float) -> float:
	# How fast the rubber slides across the ground, in m/s: the longitudinal component from the
	# slip ratio and the lateral one from the slip angle, combined. This is the quantity that
	# actually tears material off a tyre, so it is what every effect here scales with.
	var long_slip: float = absf(float(w.kappa)) * maxf(v, 2.0)
	var lat_slip: float = absf(sin(float(w.slip_angle))) * v
	return sqrt(long_slip * long_slip + lat_slip * lat_slip)

func intensity(w, v: float, fz_ref: float) -> float:
	# 0..1 - slip velocity against the reference, scaled by how hard the wheel is pressed down.
	# A wheel in the air throws nothing however fast it spins.
	var s: float = slip_speed(w, v)
	if s < slip_floor:
		return 0.0
	var load: float = clampf(float(w.Fz) / maxf(fz_ref, 1.0), 0.0, 1.6)
	return clampf((s - slip_floor) / maxf(slip_ref - slip_floor, 0.1), 0.0, 1.0) * load

func smoke_frac(temp: float, fz: float, vslip: float, grip: float) -> float:
	# Two routes to smoke, and the effect takes whichever is stronger.
	#   THERMAL - a tyre that has been worked for a while is hot enough to smoke on its own.
	#   POWER   - friction power at the contact patch, P = mu.Fz.v_slip. A hard stop locks the
	#             wheels and dumps six figures of watts into the tread instantly, which is why a
	#             panic stop smokes on cold tyres. Temperature lags this by seconds; the smoke
	#             does not.
	var thermal := clampf((temp - smoke_temp) / maxf(smoke_full_temp - smoke_temp, 1.0), 0.0, 1.0)
	var power := clampf(grip * fz * vslip / maxf(smoke_power_ref, 1.0), 0.0, 1.0)
	return maxf(thermal, power)

func _physics_process(delta: float) -> void:
	_fade_marks(delta)
	if car == null or stage == null:
		return
	var wheels: Array = car.get_wheels()
	if wheels.is_empty():
		return
	var v: float = car.linear_velocity.length()
	var mass: float = 1250.0
	if car.get("chassis_mass") != null:
		mass = float(car.chassis_mass)
	var fz_ref: float = mass * 9.81 * 0.25
	_lay_accum += delta
	var lay := _lay_accum > mark_interval
	if lay:
		_lay_accum = 0.0
	var fwd: Vector3 = -car.global_transform.basis.z
	# Material is thrown BACKWARD relative to travel, then hangs where it was thrown - that is
	# what makes a dust plume trail behind the car instead of puffing straight up around it.
	var travel: Vector3 = car.linear_velocity
	var back: Vector3 = -travel.normalized() if travel.length() > 1.0 else Vector3.ZERO
	var kick: Vector3 = (Vector3.UP + back * dust_trail).normalized()
	for i in range(mini(wheels.size(), 4)):
		var w = wheels[i]
		if not w.contact:
			_dust[i].emitting = false
			_smoke[i].emitting = false
			continue
		var cp: Vector3 = w.contact_point
		var grip: float = stage.grip_at(cp.x, cp.z)
		var amt: float = intensity(w, v, fz_ref)
		var vs: float = slip_speed(w, v)
		if grip > asphalt_grip:
			_dust[i].emitting = false
			# smoke is gated on its own physics, not on `amt` - a locked wheel in a hard stop is
			# barely "slipping" by the intensity measure until the car is moving, yet it is the
			# single smokiest thing a tyre does
			var sf: float = smoke_frac(float(w.temp), float(w.Fz), vs, grip)
			_drive(_smoke[i], cp, sf, 1.5, smoke_color, kick)
			if lay and amt > 0.12:
				_lay_mark(cp, w.contact_normal, fwd, clampf(amt, 0.0, 1.0))
		else:
			_smoke[i].emitting = false
			# dust takes the colour of the ground it came from, so the gravel loop throws dusty
			# tan and the grass verge throws olive - one call, no per-surface constants
			var col := Color(0.56, 0.48, 0.34)
			if stage.has_method("_surface_color"):
				col = stage._surface_color(cp.x, cp.z)
			_drive(_dust[i], cp, amt, dust_rise, col.lightened(0.12), kick)

func _drive(p: CPUParticles3D, cp: Vector3, amt: float, rise: float, col: Color, kick: Vector3) -> void:
	if amt <= 0.01:
		p.emitting = false
		return
	p.global_position = cp + Vector3.UP * 0.08
	p.direction = kick if kick.length() > 0.01 else Vector3.UP
	p.initial_velocity_min = rise * 0.30 * amt
	p.initial_velocity_max = rise * amt
	p.scale_amount_min = 0.30 + 0.25 * amt        # a harder slip throws bigger clouds, not just more
	p.scale_amount_max = 0.9 + 1.3 * amt
	col.a = clampf(0.20 + 0.60 * amt, 0.0, 0.90)
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
