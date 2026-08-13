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
@export var dust_amount := 24        # particles per wheel emitter
@export var dust_lifetime := 0.9     # s - dust hangs, it does not vanish
@export var dust_rise := 3.2         # m/s upward kick at full intensity
# --- tyre smoke (hard surfaces) -----------------------------------------------------------
@export var smoke_temp := 110.0      # C at which the tread starts to smoke (M7 optimum is 85)
@export var smoke_full_temp := 165.0 # C at which it smokes as hard as it ever will
@export var smoke_amount := 20
@export var smoke_lifetime := 1.6    # s - smoke lingers much longer than dust
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

func _ready() -> void:
	for i in range(4):
		_dust.append(_make_emitter(dust_amount, dust_lifetime, Color(0.56, 0.48, 0.34), -14.0, 0.30))
		_smoke.append(_make_emitter(smoke_amount, smoke_lifetime, Color(0.78, 0.78, 0.80), -1.2, 0.42))
	_build_marks()

func _make_emitter(amount: int, life: float, col: Color, gravity: float, size: float) -> CPUParticles3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	var p := CPUParticles3D.new()
	p.mesh = mesh
	p.emitting = false
	p.amount = amount
	p.lifetime = life
	p.direction = Vector3.UP
	p.spread = 55.0
	p.gravity = Vector3(0, gravity, 0)     # dust falls back; smoke is near-buoyant and drifts up
	p.color = col
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.5
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.local_coords = false                 # particles stay where they were born, not glued to the wheel
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

func smoke_frac(temp: float) -> float:
	# Rubber smokes because it is HOT, not merely because it is sliding.
	return clampf((temp - smoke_temp) / maxf(smoke_full_temp - smoke_temp, 1.0), 0.0, 1.0)

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
	for i in range(mini(wheels.size(), 4)):
		var w = wheels[i]
		if not w.contact:
			_dust[i].emitting = false
			_smoke[i].emitting = false
			continue
		var cp: Vector3 = w.contact_point
		var grip: float = stage.grip_at(cp.x, cp.z)
		var amt: float = intensity(w, v, fz_ref)
		if grip > asphalt_grip:
			_dust[i].emitting = false
			var sf: float = amt * smoke_frac(float(w.temp))
			_drive(_smoke[i], cp, sf, 1.6, Color(0.80, 0.80, 0.82))
			if lay and amt > 0.12:
				_lay_mark(cp, w.contact_normal, fwd, clampf(amt, 0.0, 1.0))
		else:
			_smoke[i].emitting = false
			# dust takes the colour of the ground it came from, so the gravel loop throws dusty
			# tan and the grass verge throws olive - one call, no per-surface constants
			var col := Color(0.56, 0.48, 0.34)
			if stage.has_method("_surface_color"):
				col = stage._surface_color(cp.x, cp.z)
			_drive(_dust[i], cp, amt, dust_rise, col.lightened(0.12))

func _drive(p: CPUParticles3D, cp: Vector3, amt: float, rise: float, col: Color) -> void:
	if amt <= 0.01:
		p.emitting = false
		return
	p.global_position = cp + Vector3.UP * 0.10
	p.initial_velocity_min = rise * 0.35 * amt
	p.initial_velocity_max = rise * amt
	p.scale_amount_max = 0.7 + 1.2 * amt
	col.a = clampf(0.25 + 0.65 * amt, 0.0, 0.95)
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
