extends Node
## M6 surface degradation — the worn racing line on the rally loop (corners + braking zones).
##
## Accumulates "wear" where the tyres work the surface (slip + slip angle) along the rally loop,
## ONLY inside corners and their braking zones. The worked line clears loose gravel and a repeatable
## racing line emerges, gaining grip (tunable). This node PROXIES grip_at() (wraps the stage's) so the
## vehicle feels it; a MultiMesh overlay draws the line. Skid marks are separate (world.gd) and are
## ASPHALT-ONLY; dirt shows wheelspin via the dust PARTICLES instead.
##
## v1/v2 TODO: replace the grid-cell quads with a proper TRACK-ALIGNED textured trail (a decal following
## the actual driven path), not grid-aligned cells.

var car
var centreline: Centreline = null        # D2: the rally loop's shared Centreline, set by world.gd
var stage

@export var arc_samples := 1080          # centreline samples around the loop (finer along the path)
@export var lat_bins := 24               # lateral cells across the tracked width (finer -> matches the car's line, not a fat band)
@export var curv_min := 0.018            # corner threshold (1/m) ~ radius 55 m: the rally loop's genuine corners
@export var brake_dist := 32.0           # metres of braking zone tracked BEFORE each corner
@export var wear_rate := 3.0             # accumulation per unit tyre-work per second (visible in ~5 passes)
@export var wear_full := 1.0             # wear value treated as a fully-developed line (wear is 0..1)
@export var wear_grip := 0.25            # grip delta on the fully-swept line (+ grippier, - looser)
@export var lat_extent := 1.4            # tracked lateral half-width, in road-halfwidth units

var _road_r: PackedFloat32Array          # cached _road(theta) per arc sample
var _hw: PackedFloat32Array              # cached halfwidth per arc sample
var _tracked: PackedByteArray            # 1 = this arc sample is in a corner/braking zone
var _wear: PackedFloat32Array            # [arc*lat_bins + lat] accumulated wear
var _center := Vector3.ZERO
var _mm: MultiMeshInstance3D
var _cell_of: PackedInt32Array           # multimesh instance -> wear index
var _last: Array = []                    # last contact point per wheel (bridges short air-gaps -> continuous line)
var _last_ok: Array = []
var _dirty: Dictionary = {}              # wear cells changed since the last overlay push
var _inst_of: Dictionary = {}            # wear cell index -> multimesh instance (reverse of _cell_of)
var overlay_on := true                   # [F10] toggles the worn-line overlay, for A/B profiling

func _ready() -> void:
	_center = stage.road_center
	_build_field()
	_build_visual()

# ---------------------------------------------------------------- field + zone detection

func _build_field() -> void:
	_road_r = PackedFloat32Array(); _road_r.resize(arc_samples)
	_hw = PackedFloat32Array(); _hw.resize(arc_samples)
	_tracked = PackedByteArray(); _tracked.resize(arc_samples)
	_wear = PackedFloat32Array(); _wear.resize(arc_samples * lat_bins)

	# D2: the field's geometry now comes from the shared Centreline instead of calling
	# stage._road(theta) here - so when D3 replaces the polar road with a generated one, this build
	# does not change. The values are handed back VERBATIM (the radius each sample was built from,
	# and its halfwidth), not recomputed, so the field is bit-identical to the pre-D2 one and
	# C1's washboard mask - which IS this tracked field - does not move.
	var stride: int = maxi(1, centreline.sample_count() / arc_samples) if centreline != null else 1
	var loop: bool = centreline.is_loop() if centreline != null else true
	var pts := PackedVector2Array(); pts.resize(arc_samples)
	for i in range(arc_samples):
		var r: float
		if centreline != null:
			r = centreline.polar_radius_index(i * stride)
			_hw[i] = centreline.halfwidth_index(i * stride)
		else:
			var th0 := TAU * float(i) / float(arc_samples)
			r = stage._road(th0)
			_hw[i] = stage._road_halfwidth(th0)
		_road_r[i] = r
		var th := TAU * float(i) / float(arc_samples)
		pts[i] = Vector2(cos(th) * r, sin(th) * r)

	var seglen := PackedFloat32Array(); seglen.resize(arc_samples)
	for i in range(arc_samples):
		# An OPEN road has no segment leaving its last sample (§5 D2: the wrap-arounds become
		# conditional on is_loop()).
		if i == arc_samples - 1 and not loop:
			seglen[i] = 0.0
		else:
			seglen[i] = pts[i].distance_to(pts[(i + 1) % arc_samples])

	# mark corners by centreline curvature (|heading change| / segment length)
	var corner := PackedByteArray(); corner.resize(arc_samples)
	for i in range(arc_samples):
		if not loop and (i == 0 or i == arc_samples - 1):
			continue                          # open ends have no pair to difference
		var a := pts[(i - 1 + arc_samples) % arc_samples]
		var b := pts[i]
		var c := pts[(i + 1) % arc_samples]
		var h0 := b - a
		var h1 := c - b
		if h0.length() < 1e-4 or h1.length() < 1e-4:
			continue
		var dphi := atan2(h0.x * h1.y - h0.y * h1.x, h0.dot(h1))
		var kappa := absf(dphi) / maxf((h0.length() + h1.length()) * 0.5, 0.01)
		if kappa >= curv_min:
			corner[i] = 1

	# tracked = each corner, plus a braking zone of `brake_dist` metres of arc BEFORE it
	for i in range(arc_samples):
		if corner[i] == 1:
			_tracked[i] = 1
			var d := 0.0
			var j := i
			while d < brake_dist:
				if not loop and j == 0:
					break                     # the braking zone stops at the start of an open road
				j = (j - 1 + arc_samples) % arc_samples
				d += seglen[j]
				_tracked[j] = 1

# ---------------------------------------------------------------- accumulation + grip

func _physics_process(delta: float) -> void:
	if car == null:
		return
	var wheels: Array = car.get_wheels()
	if _last.size() != wheels.size():
		_last.resize(wheels.size())
		_last_ok.resize(wheels.size())
		for i in range(wheels.size()):
			_last_ok[i] = false
	for wi in range(wheels.size()):
		var w = wheels[wi]
		if not w.contact:
			continue                              # keep _last so a brief air-gap gets bridged on the next contact
		var cur: Vector3 = w.contact_point
		var work := absf(w.slip) + absf(w.slip_angle)     # longitudinal scrub + lateral scrub
		if _last_ok[wi]:
			var prev: Vector3 = _last[wi]
			var d := Vector2(cur.x - prev.x, cur.z - prev.z).length()
			if d > 0.001 and d < 5.0:
				# lay wear along the whole prev->cur segment so the line is continuous (no speed skips / bump gaps)
				var steps := maxi(1, int(ceil(d / 0.3)))
				for s in range(1, steps + 1):
					var p := prev.lerp(cur, float(s) / float(steps))
					_accum(p.x, p.z, work, delta / float(steps))
			else:
				_accum(cur.x, cur.z, work, delta)
		else:
			_accum(cur.x, cur.z, work, delta)
		_last[wi] = cur
		_last_ok[wi] = true
	_update_visual()

func _accum(x: float, z: float, work: float, dt: float) -> void:
	var idx := _cell(x, z)
	if idx < 0:
		return
	var before: float = _wear[idx]
	_wear[idx] = minf(before + wear_rate * work * dt, wear_full)
	if _wear[idx] != before:
		_dirty[idx] = true               # only changed cells get pushed to the GPU - see _update_visual

func is_tracked(x: float, z: float) -> bool:
	# C1: washboard forms where repeated braking/accelerating traffic packs the surface - the same
	# corner+braking-zone mask this node already computes for the worn line, reused verbatim so the
	# line that gets worn is the line that gets ribbed (docs/PLAN-drivetrain-suspension.md C1.1).
	# BUG FIXED 2026-08-15: this originally checked only the angular sector (theta from the map
	# centre), not lateral distance from the road - so ANY point at ANY radius sharing an angle
	# with a tracked corner/braking zone read as tracked, including open grass hundreds of metres
	# out. _cell() already does this correctly (tracked flag AND the lateral corridor bound), so
	# delegate to it instead of re-deriving half its logic.
	return _cell(x, z) >= 0

func grip_at(x: float, z: float) -> float:
	var base: float = stage.grip_at(x, z)
	var idx := _cell(x, z)
	if idx < 0:
		return base
	return base * (1.0 + wear_grip * (_wear[idx] / wear_full))

func _cell(x: float, z: float) -> int:
	# map a world point to a tracked (arc, lateral) wear cell, or -1 if outside the tracked corridor
	var dx := x - _center.x
	var dz := z - _center.z
	var i := int(round(atan2(dz, dx) / TAU * float(arc_samples)))
	i = ((i % arc_samples) + arc_samples) % arc_samples
	if _tracked[i] == 0:
		return -1
	var off := sqrt(dx * dx + dz * dz) - _road_r[i]        # radial offset from the centreline
	var u := off / maxf(_hw[i] * lat_extent, 0.5)          # -1..1 across the tracked width
	if absf(u) > 1.0:
		return -1
	var j := clampi(int((u * 0.5 + 0.5) * float(lat_bins)), 0, lat_bins - 1)
	return i * lat_bins + j

# ---------------------------------------------------------------- visual overlay (MultiMesh)

func _cell_world(idx: int) -> Vector3:
	var i := idx / lat_bins
	var j := idx % lat_bins
	var u := (float(j) + 0.5) / float(lat_bins) * 2.0 - 1.0
	var off := u * _hw[i] * lat_extent
	var th := TAU * float(i) / float(arc_samples)
	var rho := _road_r[i] + off
	var p := _center + Vector3(cos(th) * rho, 0.0, sin(th) * rho)
	p.y = stage._height(p.x, p.z) + 0.03
	return p

func _build_visual() -> void:
	var cells := PackedInt32Array()
	for i in range(arc_samples):
		if _tracked[i] == 0:
			continue
		for j in range(lat_bins):
			cells.append(i * lat_bins + j)
	_cell_of = cells
	for k in range(cells.size()):
		_inst_of[cells[k]] = k

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var quad := PlaneMesh.new()
	quad.size = Vector2(1.0, 1.0)          # unit XZ quad (faces +Y); each instance is oriented + sized to its cell
	mm.mesh = quad
	mm.instance_count = cells.size()
	for k in range(cells.size()):
		var idx := cells[k]
		var i := idx / lat_bins
		var th := TAU * float(i) / float(arc_samples)
		var radial := Vector3(cos(th), 0.0, sin(th))              # cell's lateral (across the road)
		var tang := Vector3(-sin(th), 0.0, cos(th))               # cell's length (along the road)
		var lat_w := (2.0 * _hw[i] * lat_extent) / float(lat_bins) * 1.06   # one lateral cell wide
		var arc_l := _road_r[i] * TAU / float(arc_samples) * 1.06           # one arc cell long
		mm.set_instance_transform(k, Transform3D(Basis(radial * lat_w, Vector3.UP, tang * arc_l), _cell_world(cells[k])))
		mm.set_instance_color(k, Color(0, 0, 0, 0))
	_mm = MultiMeshInstance3D.new()
	_mm.name = "WearOverlay"
	_mm.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	# SHADED, not unshaded: the terrain underneath is lit by the sun and the time-of-day cycle, so
	# an unshaded overlay drifts out of step with it - the worn line keeps its noon brightness at
	# dusk and reads as a glowing stripe at night, instead of darkening with the ground it is
	# painted on. It also has to match the dust thrown off it, which is shaded for the same reason.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.render_priority = -1              # under the effect particles, so neither flickers over the other
	mat.albedo_color = Color.WHITE
	_mm.material_override = mat
	_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mm)

func _update_visual() -> void:
	# Push ONLY the cells that changed this frame. This used to walk all ~5900 tracked cells every
	# physics frame, which is 120 sweeps a second of work that is almost entirely unchanged - and it
	# got WORSE the more of the line was worn in, because the "skip unworn" early-out stopped firing.
	# Measured: 0.24 ms/frame with a fresh line rising to 0.57 ms once fully worn (28-68 ms of CPU
	# per second at 120 Hz), against 0.0002 ms/frame for the four cells the wheels actually touch.
	if _mm == null or _dirty.is_empty():
		return
	var mm := _mm.multimesh
	for idx in _dirty.keys():
		var k = _inst_of.get(idx, -1)
		if k == null or int(k) < 0:
			continue
		var wn: float = _wear[int(idx)] / wear_full
		mm.set_instance_color(int(k), Color(0.08, 0.055, 0.04, clampf(wn * 1.05, 0.0, 0.84)))   # dark worn dirt
	_dirty.clear()

var _kh := false

func _process(_dt: float) -> void:
	# [H] hides the worn-line overlay. Polled, and a letter rather than an F-key: macOS reserves
	# F9/F10 for Mission Control and volume, so the first attempt at this toggle never received them.
	if Input.is_key_pressed(KEY_H) != _kh:
		_kh = not _kh
		if _kh:
			overlay_on = not overlay_on
			if _mm != null:
				_mm.visible = overlay_on
			print("[PERF] worn-line overlay: %s (%d instances)" % [
				"ON" if overlay_on else "OFF", _cell_of.size()])
