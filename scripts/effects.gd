extends Node3D
class_name SurfaceEffects
## M11 - surface effects, built as a small data-driven particle system rather than three
## hand-wired emitters. A LAYER is declared once in `LAYERS` (size, life, gravity, growth, colour
## source, render order) and `_build_layer()` turns that declaration into four per-wheel emitters.
## Adding a fourth layer - water spray, snow, mud - is a dictionary, not new code.
##
##   DUST  (loose surfaces) - the gravel plume. Needs SPEED and SLIP: a rally car trailing dust is
##                            sliding, and dust at walking pace looks wrong.
##   SMOKE (hard surfaces)  - white-grey burnt rubber from long drifts, spinouts and hard stops.
##                            Deliberately thinner and smaller than dust.
##   GRIT  (loose surfaces) - stones and sand thrown ballistically. Needs slip, stops with it.
##
## Look, and why (researched, see CHANGELOG):
##  * Sprites are a 2x2 ATLAS of puffs, each puff a CLUSTER OF OVERLAPPING CIRCLES - which is what
##    a real dust or smoke silhouette is. `BILLBOARD_PARTICLES` + `anim_offset` gives every
##    particle its own random frame; a single texture per emitter made every particle identical,
##    which is what read as "one weird oblong shape".
##  * Particles are born SMALL and GROW while fading to nothing (`scale_amount_curve` up,
##    `color_ramp` alpha down). Ending on alpha 0 is the single biggest factor in whether a
##    particle effect reads as believable.
##  * Emission is from a small BOX at each contact patch, not a point, so a cloud has body.
##  * Particles are UNSHADED but tinted by the sun's current colour and energy. Shaded billboards
##    are lit through a camera-facing normal, so their brightness changes as you swing the camera -
##    which is what made the colour look wrong. Tinting keeps them in step with the time of day
##    without that artefact.

var car                              # untyped so get_wheels() resolves dynamically
var stage                            # RallyStage: grip_at() + _surface_color()

# --- gates: what it takes to disturb the surface ------------------------------------------
@export var slip_ref := 6.0          # m/s of contact-patch slip for a full-intensity effect
@export var slip_floor := 1.2        # m/s below which the tyre is gripping and throws nothing
@export var dust_speed_min := 8.0    # m/s (~29 km/h) of work before gravel dust starts at all
@export var dust_speed_ref := 26.0   # m/s (~94 km/h) at which the speed gate is fully open
@export var asphalt_grip := 1.2      # base grip above this = a hard surface: smoke, no dust
# --- smoke (hard surfaces) ----------------------------------------------------------------
@export var smoke_temp := 110.0      # C at which the tread starts to smoke (M7 optimum is 85)
@export var smoke_full_temp := 165.0 # C at which heat alone smokes as hard as it ever will
@export var smoke_power_ref := 60000.0  # W of friction power at the patch for full smoke, cold
@export var smoke_scale := 0.55      # smoke is thinner and smaller than dust - "much less"
# --- skid marks ---------------------------------------------------------------------------
@export var mark_pool := 900
@export var mark_fade := 14.0
@export var mark_interval := 0.03
# --- shared -------------------------------------------------------------------------------
@export var atlas_cells := 2         # 2x2 = 4 distinct puff sprites per atlas
@export var atlas_px := 64           # pixels per frame
@export var attack := 0.18           # s for an effect to swell to a new intensity
@export var release := 1.60          # s for a CLOUD to fade back down (see _smooth)
@export var release_grit := 0.14     # s for GRIT - stones stop when the slip does

# A layer declaration. `grow` is start->end scale over life: >1 means the puff expands as it ages.
const LAYERS := {
	"dust":  {"amount": 34, "life": 3.2, "size": 0.42, "gravity": -0.55, "rise": 2.2,
			  "grow": [0.30, 1.85], "alpha": 0.44, "spread": 34.0, "damp": [1.2, 2.8],
			  "box": Vector3(0.30, 0.12, 0.30), "prio": 1, "spin": 22.0},
	"smoke": {"amount": 26, "life": 2.4, "size": 0.30, "gravity": -0.35, "rise": 1.7,
			  "grow": [0.26, 1.60], "alpha": 0.30, "spread": 30.0, "damp": [1.4, 3.0],
			  "box": Vector3(0.16, 0.10, 0.16), "prio": 2, "spin": 18.0},
	"grit":  {"amount": 26, "life": 0.55, "size": 0.055, "gravity": -19.0, "rise": 9.0,
			  "grow": [1.0, 0.9], "alpha": 0.95, "spread": 24.0, "damp": [0.0, 0.4],
			  "box": Vector3(0.05, 0.03, 0.05), "prio": 0, "spin": 90.0},
}

var _em := {}                        # layer name -> Array[CPUParticles3D], one per wheel
var _sm := {}                        # layer name -> Array[float], smoothed intensity per wheel
var _atlas: ImageTexture
var _sun: DirectionalLight3D
var _mm: MultiMesh
var _mark_next := 0
var _marks: Array = []
var _lay_accum := 0.0

func _ready() -> void:
	_atlas = _make_puff_atlas(atlas_cells, atlas_px)
	for lname in LAYERS.keys():
		_em[lname] = _build_layer(LAYERS[lname])
		_sm[lname] = [0.0, 0.0, 0.0, 0.0]
	_build_marks()
	_sun = _find_sun()

func _find_sun() -> DirectionalLight3D:
	var p := get_parent()
	if p == null:
		return null
	for c in p.get_children():
		if c is DirectionalLight3D:
			return c
	return null

# --- sprite generation ---------------------------------------------------------------------

func _make_puff_atlas(cells: int, px: int) -> ImageTexture:
	# One texture holding cells x cells puff frames. Each frame is drawn as a CLUSTER OF CIRCLES
	# rather than one blob: overlapping lobes are what give smoke and dust their bumpy, rounded
	# silhouette, and taking the max of soft circular falloffs merges them into a single shape
	# instead of a bag of separate dots.
	var n := cells * px
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260814
	for cy in range(cells):
		for cx in range(cells):
			_draw_puff(img, cx * px, cy * px, px, rng)
	return ImageTexture.create_from_image(img)

func _draw_puff(img: Image, ox: int, oy: int, sz: int, rng: RandomNumberGenerator) -> void:
	var lobes: Array = []
	for i in range(rng.randi_range(4, 7)):
		var a := rng.randf_range(0.0, TAU)
		var d := rng.randf_range(0.0, 0.24)
		lobes.append([0.5 + cos(a) * d, 0.5 + sin(a) * d, rng.randf_range(0.17, 0.30)])
	for y in range(sz):
		for x in range(sz):
			var u := (float(x) + 0.5) / float(sz)
			var v := (float(y) + 0.5) / float(sz)
			var a := 0.0
			for L in lobes:
				var dx: float = u - L[0]
				var dy: float = v - L[1]
				var r: float = sqrt(dx * dx + dy * dy) / L[2]
				a = maxf(a, clampf(1.0 - r, 0.0, 1.0))
			a = a * a * (3.0 - 2.0 * a)                    # soft shoulder, never a hard rim
			var edge: float = minf(minf(u, 1.0 - u), minf(v, 1.0 - v))
			a *= clampf(edge / 0.07, 0.0, 1.0)             # frames must not bleed into each other
			img.set_pixel(ox + x, oy + y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))

func _curve(a: float, b: float) -> Curve:
	var c := Curve.new()
	c.max_value = maxf(maxf(a, b), 1.0)
	c.add_point(Vector2(0.0, a))
	c.add_point(Vector2(1.0, b))
	return c

func _build_layer(spec: Dictionary) -> Array:
	var out: Array = []
	for i in range(4):
		out.append(_make_emitter(spec))
	return out

func _make_emitter(spec: Dictionary) -> CPUParticles3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(spec["size"], spec["size"])
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED    # tinted by the sun instead - see _light()
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES    # required for per-particle atlas frames
	mat.billboard_keep_scale = true
	mat.particles_anim_h_frames = atlas_cells
	mat.particles_anim_v_frames = atlas_cells
	mat.particles_anim_loop = false
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _atlas
	mat.proximity_fade_enabled = true       # soft particles: fade where the sprite cuts the ground,
	mat.proximity_fade_distance = 0.5       # instead of showing a hard intersection line
	mat.render_priority = spec["prio"]
	mesh.material = mat
	var p := CPUParticles3D.new()
	p.mesh = mesh
	p.emitting = false
	p.amount = spec["amount"]
	p.lifetime = spec["life"]
	p.lifetime_randomness = 0.5
	p.direction = Vector3.UP
	p.spread = spec["spread"]
	p.gravity = Vector3(0, spec["gravity"], 0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX   # a volume, so the cloud has body
	p.emission_box_extents = spec["box"]
	# every particle draws a RANDOM frame from the atlas: anim_speed 0 holds whichever it picked
	p.anim_offset_min = 0.0
	p.anim_offset_max = 1.0
	p.anim_speed_min = 0.0
	p.anim_speed_max = 0.0
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.5
	p.scale_amount_curve = _curve(spec["grow"][0], spec["grow"][1])   # born small, swells as it ages
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.angular_velocity_min = -spec["spin"]
	p.angular_velocity_max = spec["spin"]
	p.damping_min = spec["damp"][0]
	p.damping_max = spec["damp"][1]
	var ramp := Gradient.new()              # ending on alpha 0 is what stops it looking like sprites
	ramp.set_color(0, Color(1, 1, 1, 0.0))
	ramp.set_color(1, Color(1, 1, 1, 0.0))
	ramp.add_point(0.10, Color(1, 1, 1, 1.0))
	ramp.add_point(0.40, Color(1, 1, 1, 0.75))
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
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = -1
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

# --- physical drivers ----------------------------------------------------------------------

func slip_speed(w, v: float) -> float:
	var long_slip: float = absf(float(w.kappa)) * maxf(v, 2.0)
	var lat_slip: float = absf(sin(float(w.slip_angle))) * v
	return sqrt(long_slip * long_slip + lat_slip * lat_slip)

func slip_frac(w, v: float, fz_ref: float) -> float:
	var s: float = slip_speed(w, v)
	if s < slip_floor:
		return 0.0
	var load: float = clampf(float(w.Fz) / maxf(fz_ref, 1.0), 0.0, 1.6)
	return clampf((s - slip_floor) / maxf(slip_ref - slip_floor, 0.1), 0.0, 1.0) * load

func dust_frac(v: float, vslip: float, slip_amt: float) -> float:
	# Dust needs SPEED AND SLIP, multiplied - not added. A car pottering along a gravel road does
	# not trail a plume, and neither does a car sliding at walking pace; the plume belongs to a
	# rally car moving fast and sideways. The speed gate takes whichever is larger, road speed or
	# slip speed, so a stationary burnout or a spinout still raises dust while a slow crawl cannot.
	var work: float = maxf(v, vslip)
	var speed_gate: float = clampf((work - dust_speed_min) / maxf(dust_speed_ref - dust_speed_min, 0.1), 0.0, 1.0)
	return speed_gate * clampf(slip_amt, 0.0, 1.0)

func smoke_frac(temp: float, fz: float, vslip: float, grip: float) -> float:
	var thermal := clampf((temp - smoke_temp) / maxf(smoke_full_temp - smoke_temp, 1.0), 0.0, 1.0)
	var power := clampf(grip * fz * vslip / maxf(smoke_power_ref, 1.0), 0.0, 1.0)
	return maxf(thermal, power)

func _smooth(prev: float, target: float, dt: float, rel: float = -1.0) -> float:
	# Fast attack, slow release. CPUParticles3D.color is a uniform over the whole system, so a raw
	# per-frame intensity re-tints every live particle at once and the load pumping through the
	# bump stops under braking showed up as the cloud flickering. This rides over the troughs.
	var tau: float = attack if target > prev else (release if rel < 0.0 else rel)
	return move_toward(prev, target, dt / maxf(tau, 0.01))

func _light() -> Color:
	# Particles are unshaded, so they must be told what the light is doing or they stay at noon
	# brightness through dusk and night while the ground darkens around them.
	if _sun == null:
		return Color(1, 1, 1)
	var e: float = clampf(_sun.light_energy, 0.18, 1.35)
	return _sun.light_color.lerp(Color.WHITE, 0.45) * e

func ground_color(x: float, z: float) -> Color:
	# The colour the player actually SEES there - not the terrain's own colour, because wear.gd
	# paints the driven line dark and the car lives on that line. The wear fraction is recovered
	# from the grip the wear node reports against the stage's base grip, so no extra plumbing.
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
	# airborne dust is finer than the packed surface and scatters more light, so it reads a shade
	# lighter than the ground it came off - but only a shade, or it stops matching
	return base.lightened(0.10)

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
	var kick: Vector3 = (Vector3.UP + back * 0.55).normalized()
	var lit := _light()

	for i in range(mini(wheels.size(), 4)):
		var w = wheels[i]
		if not w.contact:
			for nm in _em.keys():
				_em[nm][i].emitting = false
			continue
		var cp: Vector3 = w.contact_point
		var grip: float = stage.grip_at(cp.x, cp.z)
		var vs: float = slip_speed(w, v)
		var sa: float = slip_frac(w, v, fz_ref)
		if grip > asphalt_grip:
			_emit_layer(i, "dust", 0.0, delta, cp, kick, Color.WHITE, lit)
			_emit_layer(i, "grit", 0.0, delta, cp, kick, Color.WHITE, lit, release_grit)
			var sf: float = smoke_frac(float(w.temp), float(w.Fz), vs, grip) * smoke_scale
			_emit_layer(i, "smoke", sf, delta, cp, kick, Color(0.90, 0.90, 0.92), lit)
			if lay and sa > 0.12:
				_lay_mark(cp, w.contact_normal, fwd, clampf(sa, 0.0, 1.0))
		else:
			_emit_layer(i, "smoke", 0.0, delta, cp, kick, Color.WHITE, lit)
			var col := ground_color(cp.x, cp.z)
			_emit_layer(i, "dust", dust_frac(v, vs, sa), delta, cp, kick, col, lit)
			_emit_layer(i, "grit", sa, delta, cp, kick, col.darkened(0.14), lit, release_grit)

func _emit_layer(i: int, layer: String, target: float, dt: float, cp: Vector3, kick: Vector3, col: Color, lit: Color, rel: float = -1.0) -> void:
	var arr: Array = _sm[layer]
	arr[i] = _smooth(arr[i], target, dt, rel)
	var amt: float = arr[i]
	var p: CPUParticles3D = _em[layer][i]
	if amt <= 0.01:
		p.emitting = false
		return
	var spec: Dictionary = LAYERS[layer]
	p.global_position = cp + Vector3.UP * 0.05
	p.direction = kick if kick.length() > 0.01 else Vector3.UP
	p.initial_velocity_min = float(spec["rise"]) * 0.35 * amt
	p.initial_velocity_max = float(spec["rise"]) * amt
	var a_max: float = float(spec["alpha"])
	var c := Color(col.r * lit.r, col.g * lit.g, col.b * lit.b)
	c.a = clampf(a_max * (0.35 + 0.65 * amt), 0.0, a_max)
	p.color = c
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
