extends Node3D
class_name SurfaceEffects
## M11 - the four surface effects, as a data-driven particle system. NAMES MATTER HERE; see the
## table in CLAUDE.md. These four are separate systems and must not be conflated:
##
##   "plume"  - DIRT/DUST PLUMES      : the big billowing dust cloud trailed on gravel/dirt.
##   "gravel" - DIRT/GRAVEL PARTICLES : stones and sand flicked ballistically from the tyre.
##   "smoke"  - ASPHALT SMOKE         : white-grey burnt rubber on tarmac.
##   marks    - ASPHALT TIRE TRACKS   : the dark rubber marks on the road (a MultiMesh).
##
## SIZES ARE IN TYRE DIAMETERS, not metres. The user specifies them that way ("4-6 times larger
## than the tires", "half a tire", "2x tire size") and it is the honest unit: it stays correct if
## the wheel size ever changes. The particle mesh is a 1x1 quad so a particle's SCALE *is* its
## diameter in metres, which keeps the arithmetic readable.
##
## Look, and why (researched, see CHANGELOG):
##  * Sprites are a 2x2 ATLAS of puffs, each a CLUSTER OF OVERLAPPING CIRCLES. `BILLBOARD_PARTICLES`
##    + `anim_offset` gives every particle its own random frame; one texture per emitter made every
##    particle identical, which read as a single oblong blob.
##  * Particles are born small and GROW while fading to alpha 0 - the single biggest factor in
##    whether a particle effect reads as believable.
##  * GPUParticles3D, for `amount_ratio`: it scales emission density continuously with no restart.
##    CPUParticles3D has no equivalent.
##  * Particles are UNSHADED but tinted by the sun, because shaded billboards are lit through a
##    camera-facing normal and change brightness as the camera swings.

var car                              # untyped so get_wheels() resolves dynamically
var stage                            # RallyStage: grip_at() + _surface_color()

# --- slip, shared by every layer ----------------------------------------------------------
@export var slip_ref := 6.0          # m/s of contact-patch slip for a full-intensity effect
@export var slip_floor := 1.2        # m/s below which the tyre is gripping and throws nothing
@export var asphalt_grip := 1.2      # base grip above this = tarmac: smoke, no dust
# --- DIRT/DUST PLUMES ---------------------------------------------------------------------
# Plumes are SPEED-driven: they kick up from 20 km/h and are fully established by 40, with sliding
# adding on top. Size is quoted in TYRE DIAMETERS and grows to a ceiling at 160 km/h.
@export var plume_speed_start := 5.6   # m/s (20 km/h) - plumes begin
@export var plume_speed_full := 11.1   # m/s (40 km/h) - speed gate fully open
@export var plume_speed_ceiling := 44.4  # m/s (160 km/h) - size and rate stop growing
@export var plume_d_min_tyres := 1.2   # plume diameter at death, in tyre diameters, at 20 km/h
@export var plume_d_max_tyres := 6.5   # ...and at the 160 km/h ceiling (~4.2x at 100 km/h)
@export var plume_birth_frac := 0.25   # born a quarter of its final diameter
# Frequency has TWO parts. Per-metre: emission proportional to speed, because particles are left in
# world space and a fixed rate is smeared over more ground the faster you go. Fluidity gain: an
# EXTRA multiplier on top, so the plume also thickens in its own right rather than only keeping up
# with distance - 40 km/h to 120 km/h is 3x from distance and another `fluid_gain` from this.
@export var fluid_gain := 1.75
# --- DIRT/GRAVEL PARTICLES ----------------------------------------------------------------
@export var gravel_d := 0.07           # m - stones are stones; they do not scale with the tyre
@export var gravel_speed_share := 0.22 # how much high speed alone flicks stones without sliding
# --- ASPHALT SMOKE ------------------------------------------------------------------------
@export var smoke_temp := 110.0        # C at which the tread starts to smoke (M7 optimum is 85)
@export var smoke_full_temp := 165.0   # C at which heat alone smokes as hard as it ever will
@export var smoke_power_ref := 60000.0 # W of friction power at the patch for full smoke, cold
@export var smoke_d_birth_tyres := 0.5 # born at half a tyre diameter
@export var smoke_d_death_tyres := 2.0 # grows to twice a tyre diameter - the BASELINE, not the max
@export var smoke_build_gain := 1.4    # a fully built column grows beyond that baseline by this
@export var smoke_density_floor := 0.45  # frequent from the start, not only once built up
# A tyre does not smoke at full volume the instant it slips: the column BUILDS under pressure and
# keeps drifting after the pressure comes off. This integrates pressure rather than tracking it.
@export var smoke_build_time := 2.6    # s of sustained slip to reach a full column
@export var smoke_decay_time := 5.0    # s to subside once the pressure is off - deliberately slower
@export var smoke_scale := 0.55        # smoke stays thinner than the plumes
# --- ASPHALT TIRE TRACKS ------------------------------------------------------------------
@export var mark_pool := 900
@export var mark_fade := 14.0
@export var mark_interval := 0.03
# --- shared -------------------------------------------------------------------------------
# DENSITY AND COST ARE THE SAME KNOB. These particles are fill-rate bound, not count bound: every
# transparent sprite is drawn back-to-front whether or not something covers it later, so cost
# scales with AREA on screen. At the 160 km/h ceiling one plume particle is 4.4 m across = 15 m2 of
# sprite, and 600 of them is ~9200 m2 - roughly 23x full-screen overdraw if they all overlapped in
# view. Doubling the COUNT therefore doubles the cost while barely looking denser, because the
# cloud is already opaque where it overlaps. Perceived density is bought far more cheaply from
# per-particle ALPHA and from the sprite carrying more of its own detail. `density` is here so the
# ceiling can still be raised deliberately, with the cost understood.
@export var density := 1.0           # build-time multiplier on every layer's particle ceiling
@export var sim_fps := 30            # particles simulate at this rate, interpolated - see _make_emitter
@export var atlas_cells := 2         # 2x2 = 4 distinct puff sprites per atlas
@export var atlas_px := 64
@export var attack := 0.18           # s for an effect to swell to a new intensity
@export var release := 1.60          # s for a CLOUD to fade back down (see _smooth)
@export var release_gravel := 0.14   # s for GRAVEL PARTICLES - stones stop when the slip does

# `grow` is [birth, knee_t, knee_frac, 1.0] as FRACTIONS of the final diameter: born at `birth`,
# reaching `knee_frac` by `knee_t` of its life, then easing to full size. The knee is what makes a
# puff expand fast at first and then settle, the way real dust does.
const LAYERS := {
	"plume":  {"amount": 240, "life": 4.6, "gravity": -0.45, "rise": 2.4,
			   "grow": [0.25, 0.32, 0.74, 1.0], "alpha": 0.52, "spread": 36.0, "damp": [1.1, 2.6],
			   "box": Vector3(0.32, 0.14, 0.32), "prio": 1, "spin": 20.0, "turb": 0.55},
	"smoke":  {"amount": 170, "life": 3.0, "gravity": -0.30, "rise": 3.0,
			   "grow": [0.25, 0.35, 0.72, 1.0], "alpha": 0.36, "spread": 30.0, "damp": [1.4, 3.0],
			   "box": Vector3(0.16, 0.10, 0.16), "prio": 2, "spin": 16.0, "turb": 0.30},
	"gravel": {"amount": 70, "life": 0.55, "gravity": -19.0, "rise": 9.0,
			   "grow": [1.0, 0.5, 1.0, 1.0], "alpha": 0.95, "spread": 24.0, "damp": [0.0, 0.4],
			   "box": Vector3(0.05, 0.03, 0.05), "prio": 0, "spin": 90.0, "turb": 0.0},
}

var _em := {}                        # layer name -> Array[CPUParticles3D], one per wheel
var _sm := {}                        # layer name -> Array[float], smoothed intensity per wheel
var _atlas: ImageTexture
var _sun: DirectionalLight3D
var _mm: MultiMesh
var _mark_next := 0
var _marks: Array = []
var _lay_accum := 0.0
var _build := [0.0, 0.0, 0.0, 0.0]   # ASPHALT SMOKE column build-up per wheel, 0..1
var _sz := {}                        # smoothed speed-driven quantities (see _physics_process)

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
	# Mipmaps: distant particles then sample a smaller level, which both stops them shimmering and
	# cuts texture-cache pressure when a plume fills the screen. Frames fade to alpha 0 at their
	# borders (see _draw_puff), so lower mips do not bleed one frame into its neighbour.
	img.generate_mipmaps()
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
			a = clampf(a * 1.35, 0.0, 1.0)                 # denser core, shorter fringe: a wide band
			                                               # of near-transparent pixels costs exactly
			                                               # as much fill as opaque ones and shows
			                                               # nothing, so spend the area on the middle
			var edge: float = minf(minf(u, 1.0 - u), minf(v, 1.0 - v))
			a *= clampf(edge / 0.07, 0.0, 1.0)             # frames must not bleed into each other
			img.set_pixel(ox + x, oy + y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))

func _curve(g: Array) -> Curve:
	# [birth, knee_t, knee_scale, death] - fast early expansion, then easing toward a ceiling.
	var c := Curve.new()
	c.max_value = maxf(maxf(float(g[0]), float(g[2])), maxf(float(g[3]), 1.0))
	c.add_point(Vector2(0.0, float(g[0])))
	c.add_point(Vector2(clampf(float(g[1]), 0.05, 0.95), float(g[2])))
	c.add_point(Vector2(1.0, float(g[3])))
	return c

func _curve_tex(g: Array) -> CurveTexture:
	var t := CurveTexture.new()
	t.curve = _curve(g)
	return t

func _ramp_tex() -> GradientTexture1D:
	# Ending on alpha 0 is the single biggest factor in whether particles read as believable.
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 0.0))
	grad.set_color(1, Color(1, 1, 1, 0.0))
	grad.add_point(0.10, Color(1, 1, 1, 1.0))
	grad.add_point(0.40, Color(1, 1, 1, 0.75))
	var t := GradientTexture1D.new()
	t.gradient = grad
	return t

func _build_layer(spec: Dictionary) -> Array:
	var out: Array = []
	for i in range(4):
		out.append(_make_emitter(spec))
	return out

func _make_emitter(spec: Dictionary) -> GPUParticles3D:
	# GPU particles, not CPU, for one reason that matters: `amount_ratio`. It scales emission
	# density continuously with no restart, which is what lets dust thicken with speed. The CPU
	# node has no equivalent - its only rate control is `amount`, and writing that mid-drive
	# restarts the system and wipes the live cloud.
	var mesh := QuadMesh.new()
	mesh.size = Vector2(1.0, 1.0)           # unit quad: a particle's SCALE is its diameter in metres
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
	mat.proximity_fade_enabled = true       # soft particles: fade where the sprite cuts the ground
	mat.proximity_fade_distance = 0.5
	mat.render_priority = spec["prio"]
	mesh.material = mat

	var pm := ParticleProcessMaterial.new()
	pm.gravity = Vector3(0, spec["gravity"], 0)
	pm.direction = Vector3.UP
	pm.spread = spec["spread"]
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = spec["rise"]
	pm.damping_min = spec["damp"][0]
	pm.damping_max = spec["damp"][1]
	pm.scale_min = 0.75
	pm.scale_max = 1.35
	pm.scale_curve = _curve_tex(spec["grow"])
	pm.color_ramp = _ramp_tex()
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -float(spec["spin"])
	pm.angular_velocity_max = float(spec["spin"])
	pm.anim_offset_min = 0.0                # every particle draws a RANDOM atlas frame
	pm.anim_offset_max = 1.0
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX   # a volume, so a cloud has body
	pm.emission_box_extents = spec["box"]
	if float(spec["turb"]) > 0.0:
		pm.turbulence_enabled = true        # dust swirls rather than drifting in straight lines
		pm.turbulence_noise_strength = float(spec["turb"])
		pm.turbulence_noise_scale = 2.2

	var p := GPUParticles3D.new()
	p.process_material = pm
	p.draw_pass_1 = mesh
	p.amount = maxi(8, int(round(float(spec["amount"]) * maxf(density, 0.05))))   # CEILING; amount_ratio scales it live
	p.lifetime = spec["life"]
	p.randomness = 0.5
	p.amount_ratio = 1.0
	# Simulate at sim_fps rather than every rendered frame, and interpolate between those steps.
	# Dust has no fast transients to miss, so a third of the simulation cost is free real estate -
	# and it is what pays for the density above.
	p.fixed_fps = sim_fps
	p.interpolate = true
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH    # correct back-to-front blending
	# A generous fixed visibility box. Without one Godot recomputes the bounds, and a moving emitter
	# with world-space particles can otherwise cull a plume that is still perfectly visible.
	p.visibility_aabb = AABB(Vector3(-25.0, -4.0, -25.0), Vector3(50.0, 22.0, 50.0))
	p.local_coords = false                  # particles stay where they were born
	p.emitting = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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

func tyre_d() -> float:
	# Sizes are quoted in tyre diameters, so everything downstream stays correct if the wheel changes.
	var r := 0.34
	if car != null and car.get("wheel_radius") != null:
		r = float(car.wheel_radius)
	return r * 2.0

func plume_frac(v: float, slip_amt: float) -> float:
	# DIRT/DUST PLUMES: speed-driven from 20 km/h, fully established by 40, sliding adds on top.
	var s: float = clampf((v - plume_speed_start) / maxf(plume_speed_full - plume_speed_start, 0.1), 0.0, 1.0)
	return s * lerpf(0.60, 1.0, clampf(slip_amt, 0.0, 1.0))

func plume_speed_t(v: float) -> float:
	return clampf((v - plume_speed_start) / maxf(plume_speed_ceiling - plume_speed_start, 0.1), 0.0, 1.0)

func plume_diameter_at(v: float) -> float:
	# Final (death) diameter in METRES, from tyre diameters, growing to the 160 km/h ceiling.
	return tyre_d() * lerpf(plume_d_min_tyres, plume_d_max_tyres, plume_speed_t(v))

func plume_density_at(v: float) -> float:
	# Per-metre emission (rate proportional to speed) TIMES a fluidity gain, so the plume thickens
	# faster than distance alone would. Normalised so the 160 km/h ceiling lands exactly on 1.0.
	var per_m: float = clampf(v / maxf(plume_speed_ceiling, 0.1), 0.0, 1.0)
	var t: float = clampf((v - plume_speed_full) / maxf(33.3 - plume_speed_full, 0.1), 0.0, 1.0)
	var gain: float = lerpf(1.0, fluid_gain, t)
	return clampf(per_m * gain / maxf(fluid_gain, 0.01), 0.03, 1.0)

func gravel_frac(v: float, slip_amt: float) -> float:
	# DIRT/GRAVEL PARTICLES: mainly slides, but high speed alone flicks some stones too, and a slide
	# at low speed throws fewer of them than the same slide at speed.
	var sf: float = clampf(v / maxf(plume_speed_ceiling, 0.1), 0.0, 1.0)
	var from_slip: float = clampf(slip_amt, 0.0, 1.0) * lerpf(0.45, 1.0, sf)
	var from_speed: float = gravel_speed_share * clampf((sf - 0.45) / 0.55, 0.0, 1.0)
	return clampf(from_slip + from_speed, 0.0, 1.0)

func smoke_build(prev: float, press: float, dt: float) -> float:
	# Integrates pressure instead of tracking it: a long drift builds a column, a stab does not,
	# and letting off tapers over smoke_decay_time rather than switching off.
	if press > 0.12:
		return clampf(prev + press * dt / maxf(smoke_build_time, 0.05), 0.0, 1.0)
	return clampf(prev - dt / maxf(smoke_decay_time, 0.05), 0.0, 1.0)

func smoke_diameter_at(build: float) -> float:
	# 0.5 -> 2.0 tyre diameters is the stated baseline (born half a tyre, grown to two), so it is
	# what an unbuilt column already does; pressure then grows it BEYOND that rather than up to it.
	return tyre_d() * smoke_d_death_tyres * lerpf(1.0, smoke_build_gain, clampf(build, 0.0, 1.0))

func smoke_density_at(v: float, build: float) -> float:
	# Frequent from the start (floor), then rising with speed and with the built column.
	var d: float = maxf(plume_density_at(v), clampf(build, 0.0, 1.0))
	return clampf(smoke_density_floor + (1.0 - smoke_density_floor) * d, smoke_density_floor, 1.0)

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

	# Speed-driven quantities, smoothed: scale_min/max and amount_ratio are shader uniforms read
	# every frame, not values baked at spawn, so writing them raw resizes every LIVE particle at
	# once. Easing them means a change reads as the cloud swelling rather than popping.
	var p_d := plume_diameter_at(v)
	var p_dens := plume_density_at(v)
	var p_rise := lerpf(0.6, 1.7, plume_speed_t(v))     # faster cars throw it up harder, too
	_sz["pd"] = move_toward(float(_sz.get("pd", p_d)), p_d, delta * 6.0)
	_sz["pn"] = move_toward(float(_sz.get("pn", p_dens)), p_dens, delta / 0.7)
	_sz["pr"] = move_toward(float(_sz.get("pr", p_rise)), p_rise, delta / 0.7)

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
			_emit(i, "plume", 0.0, delta, cp, kick, Color.WHITE, lit, 1.0, 1.0, 1.0)
			_emit(i, "gravel", 0.0, delta, cp, kick, Color.WHITE, lit, gravel_d, 1.0, 1.0, release_gravel)
			# ASPHALT SMOKE
			var press: float = smoke_frac(float(w.temp), float(w.Fz), vs, grip)
			_build[i] = smoke_build(_build[i], press, delta)
			_emit(i, "smoke", maxf(press, _build[i] * 0.6) * smoke_scale, delta, cp, kick,
					Color(0.90, 0.90, 0.92), lit, smoke_diameter_at(_build[i]),
					smoke_density_at(v, _build[i]), 1.0)
			if lay and sa > 0.12:
				_lay_mark(cp, w.contact_normal, fwd, clampf(sa, 0.0, 1.0))   # ASPHALT TIRE TRACKS
		else:
			_emit(i, "smoke", 0.0, delta, cp, kick, Color.WHITE, lit, 1.0, 1.0, 1.0)
			_build[i] = maxf(_build[i] - delta / maxf(smoke_decay_time, 0.05), 0.0)
			var col := ground_color(cp.x, cp.z)
			# DIRT/DUST PLUMES
			_emit(i, "plume", plume_frac(v, sa), delta, cp, kick, col, lit,
					float(_sz["pd"]), float(_sz["pn"]), float(_sz["pr"]))
			# DIRT/GRAVEL PARTICLES
			_emit(i, "gravel", gravel_frac(v, sa), delta, cp, kick, col.darkened(0.14), lit,
					gravel_d, 1.0, 1.0, release_gravel)

func _emit(i: int, layer: String, target: float, dt: float, cp: Vector3, kick: Vector3, col: Color, lit: Color, diameter: float, density: float, rise_mult: float, rel: float = -1.0) -> void:
	var arr: Array = _sm[layer]
	arr[i] = _smooth(arr[i], target, dt, rel)
	var amt: float = arr[i]
	var p: GPUParticles3D = _em[layer][i]
	if amt <= 0.01:
		p.emitting = false
		return
	var spec: Dictionary = LAYERS[layer]
	var pm: ParticleProcessMaterial = p.process_material
	p.global_position = cp + Vector3.UP * 0.05
	pm.direction = kick if kick.length() > 0.01 else Vector3.UP
	var rise: float = float(spec["rise"]) * rise_mult
	pm.initial_velocity_min = rise * 0.35 * amt
	pm.initial_velocity_max = rise * amt
	pm.scale_min = diameter * 0.82        # the mesh is a unit quad, so scale IS diameter in metres
	pm.scale_max = diameter * 1.22
	p.amount_ratio = clampf(density * (0.4 + 0.6 * amt), 0.03, 1.0)
	var a_max: float = float(spec["alpha"])
	var c := Color(col.r * lit.r, col.g * lit.g, col.b * lit.b)
	c.a = clampf(a_max * (0.35 + 0.65 * amt), 0.0, a_max)
	pm.color = c
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
