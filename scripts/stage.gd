extends StaticBody3D
class_name RallyStage
## M5 - a procedural rally stage.
##
## Rolling-hill heightmap terrain (SimplexSmooth noise) with a winding dirt-road LOOP carved
## through it. The road follows the hills (so it crests and dips like a real stage) but is
## flattened across its width and mildly banked; roadside posts mark it. Feeds a
## HeightMapShape3D collider + a vertex-coloured mesh (grass off-road, dirt on it).

@export var size := 720.0                # square terrain side (m) - fits the circuit; the drag strip spurs out
@export var cells := 320                 # grid resolution -> cell = size/cells (~2.25 m)
@export var hill_height := 10.0          # rolling-hill amplitude (gentler -> less air)
@export var hill_freq := 0.004           # lower = broader, gentler hills
@export var hill_octaves := 2            # fewer octaves = smoother (less high-freq bumps)
@export var road_center := Vector3(0, 0, 0)
@export var road_radius := 168.0
@export var road_wind1 := 42.0           # 3-lobe winding (moderate turns)
@export var road_wind2 := 24.0           # 5-lobe winding
@export var road_width := 8.5            # nominal width; pinches in places (shoulders take over)
@export var width_var := 0.42            # how much the road narrows at the pinch points (0..1)
@export var start_zone := 34.0           # metres of arc around start/finish kept wide + flat
@export var start_runup := 20.0          # spawn/respawn this many metres BEFORE the line, so crossing it starts the lap + ghost
@export var center_lap_radius := 55.0    # radius of the timed lap on the centre dirt circle (fits inside the patch)
@export var road_shoulder := 7.0
@export var crest_amp := 1.0             # extra road roll on top of the hills (subtle -> less air)
@export var bank_gain := 3.0             # camber follows LOCAL curvature -> banks WITH the turn
@export var bank_max := 0.06             # cap so camber is never too sharp (either way)
@export var shoulder_berm := 0.45        # raised berm along each road shoulder (m)
@export var berm_pos := 2.2              # berm peak this far outside the road edge
@export var berm_width := 2.0            # berm falloff width
@export var grass_color := Color(0.44, 0.44, 0.26)   # dry Mediterranean scrub
@export var road_color := Color(0.60, 0.53, 0.40)    # dusty grey-tan gravel (Acropolis-ish)

# --- outer ASPHALT circuit: a winding technical loop (Monte-Carlo inspired) OUTSIDE the dirt loop.
# A proper flat road (follows the hills along its centreline, level across its width) with an ABRUPT
# edge + kerb, not a wide blend -- reads like a real road. ---
@export var asphalt_radius := 300.0      # base radius (stays clear of the dirt loop's ~234 m bulge)
@export var asphalt_w1 := 20.0           # 2-lobe wind
@export var asphalt_w2 := 13.0           # 3-lobe wind
@export var asphalt_w3 := 8.0            # 5-lobe wind (tighter kinks -> technical, street-circuit feel)
@export var asphalt_width := 15.0        # road width
@export var asphalt_shoulder := 20.0     # (drag-strip corridor still uses this)
@export var asphalt_edge := 2.0          # ABRUPT shoulder: sharp fall-off to the terrain
@export var asphalt_kerb := 0.12         # small raised kerb lip right at the road edge
@export var asphalt_elev := 0.0          # drag strip flat elevation
@export var asphalt_color := Color(0.22, 0.22, 0.25)
# --- DRAG STRIP: a 4 km straight branching off the circuit's +X side, for real top-speed runs. ---
@export var strip_x0 := 285.0            # near end (overlaps the circuit's right side)
@export var strip_len := 4000.0          # length of the straight (m) - strip_x1 derives from it
@export var strip_hw := 12.0             # half-width (24 m wide)
@export var runoff_r := 95.0             # braking / turn-around pad at the far end
@export var strip_marker_step := 100.0   # distance posts down both shoulders (m)
@export var strip_km_step := 1000.0      # billboard distance call-outs (m)
# --- guard rail (real W-beam spec: 0.75 m beam top, posts ~2 m apart) ---
@export var rail_height := 0.75          # top of the beam above the ground (m)
@export var rail_beam_h := 0.32          # beam face height (m)
@export var rail_beam_t := 0.10          # beam thickness (m)
@export var rail_post_step := 2.0        # post spacing along the rail (m)
@export var rail_span := 8.0             # beam / collision panel length (m)
# --- per-surface traction multipliers (applied to tyre mu by the vehicle) ---
@export var asphalt_grip := 1.52         # asphalt grips best (bumped a touch to calm high-gear wheelspin)
@export var dirt_grip := 1.1             # dirt loop / centre patch - more grip in the turns
@export var grass_grip := 0.8            # loose off-track
# --- flat disc in the CENTRE for the reactive/deformable dirt patch ---
@export var patch_radius := 75.0         # matches the DeformableTerrain zone half-size (150/2)
@export var patch_bed := 0.15            # matches DeformableTerrain.bed_height (tiles hide the step under it)
@export var patch_floor := -0.06         # stage ground UNDER the patch sits below the ruts so they work
@export var center_blend := 18.0         # gentle grass ramp from the patch edge up to the hills
@export var obstacle_count := 46         # solid trees/poles scattered on the grass (collidable crash-test props)

var _cs := 0.0
var _n := 0
var _half := 0.0
var _strip_elev := 0.0            # drag strip is flat at the LOCAL hill height of its branch (smooth join)
var strip_x1 := 0.0               # derived in _ready(): strip_x0 + strip_len
var _noise := FastNoiseLite.new()

func _ready() -> void:
	_cs = size / float(cells)
	_n = cells + 1
	_half = size * 0.5
	collision_layer = 1
	collision_mask = 0
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = hill_freq
	_noise.fractal_octaves = hill_octaves
	_strip_elev = _noise.get_noise_2d(strip_x0, 0.0) * hill_height   # match the circuit's local elevation
	strip_x1 = strip_x0 + strip_len
	_build()
	_markers()
	_build_drag_strip()
	_build_obstacles()

func _road(th: float) -> float:
	return road_radius + road_wind1 * sin(3.0 * th) + road_wind2 * sin(5.0 * th)

func _start_factor(th: float) -> float:
	# 1.0 right at start/finish (theta=0), fading to 0 over start_zone metres of arc
	var arc := absf(atan2(sin(th), cos(th))) * road_radius
	return clampf(1.0 - arc / maxf(start_zone, 1.0), 0.0, 1.0)

func _road_halfwidth(th: float) -> float:
	# the drivable width pinches in places; where it does, the shoulders take over the track
	var pinch := (0.5 + 0.5 * sin(2.0 * th + 0.7)) * (1.0 - _start_factor(th))   # no pinch at start
	var hw := road_width * 0.5 * (1.0 - width_var * pinch)
	return hw * (1.0 + 0.35 * _start_factor(th))                                 # a bit wider at start

func _road_curv(th: float) -> float:
	# signed curvature of the polar loop r(th) -> drives camber that leans WITH the local turn
	var r := _road(th)
	var r1 := 3.0 * road_wind1 * cos(3.0 * th) + 5.0 * road_wind2 * cos(5.0 * th)
	var r2 := -9.0 * road_wind1 * sin(3.0 * th) - 25.0 * road_wind2 * sin(5.0 * th)
	return (r * r + 2.0 * r1 * r1 - r * r2) / maxf(pow(r * r + r1 * r1, 1.5), 1e-3)

func _road_t(x: float, z: float) -> float:
	var dx := x - road_center.x
	var dz := z - road_center.z
	var rho := sqrt(dx * dx + dz * dz)
	var th := atan2(dz, dx)
	var half := _road_halfwidth(th)
	return 1.0 - smoothstep(half, half + road_shoulder, absf(rho - _road(th)))

func _asphalt_r(th: float) -> float:
	# radius of the winding asphalt centreline at angle th (2/3/5-lobe wind -> a technical street loop)
	return asphalt_radius + asphalt_w1 * sin(2.0 * th + 0.6) + asphalt_w2 * sin(3.0 * th + 1.2) + asphalt_w3 * sin(5.0 * th + 0.4)

func _asphalt_dist(x: float, z: float) -> float:
	# distance from the asphalt centreline (0 = on the line)
	var dx := x - road_center.x
	var dz := z - road_center.z
	return absf(sqrt(dx * dx + dz * dz) - _asphalt_r(atan2(dz, dx)))

func _height(x: float, z: float) -> float:
	var base := _noise.get_noise_2d(x, z) * hill_height
	var dx := x - road_center.x
	var dz := z - road_center.z
	var rho := sqrt(dx * dx + dz * dz)
	# centre reactive-dirt patch: SQUARE region (matches the deformable tile grid) so the dirt slab
	# doesn't overhang the round flatten at its corners. Ground sits below the ruts, then ramps up to
	# the patch bed at the edge so the tiles meet the grass flush (no lip).
	var cheb := maxf(absf(dx), absf(dz))
	if cheb < patch_radius:
		return patch_floor
	if cheb < patch_radius + center_blend:
		var te := smoothstep(patch_radius, patch_radius + center_blend, cheb)
		return lerpf(patch_bed, base, te)
	# drag strip corridor: flat at the LOCAL branch elevation (joins the hilly circuit smoothly)
	if x >= strip_x0 and x <= strip_x1 and absf(z) < strip_hw + asphalt_shoulder:
		var ts := 1.0 - smoothstep(strip_hw, strip_hw + asphalt_shoulder, absf(z))
		return lerpf(base, _strip_elev, ts)
	# outer asphalt circuit: a flat road (follows the hills only at its centreline) with an ABRUPT edge
	var ad := _asphalt_dist(x, z)
	var ahw := asphalt_width * 0.5
	if ad < ahw + asphalt_edge + 1.0:
		var ath := atan2(dz, dx)
		var arr := _asphalt_r(ath)
		var aelev := _noise.get_noise_2d(road_center.x + cos(ath) * arr, road_center.z + sin(ath) * arr) * hill_height
		var at := 1.0 - smoothstep(ahw, ahw + asphalt_edge, ad)   # sharp fall-off, not a wide blend
		var kd := ad - ahw
		return lerpf(base, aelev, at) + asphalt_kerb * exp(-(kd * kd) / 0.6)   # + a small kerb lip at the edge
	# dirt rally road (follows the hills, banked, bermed)
	var th := atan2(dz, dx)
	var rr := _road(th)
	var rdist := absf(rho - rr)
	var half := _road_halfwidth(th)
	if rdist >= half + road_shoulder:
		return base
	# road follows the hills (sampled at the centreline) so it doesn't cliff off, + a designed roll
	var cx := road_center.x + cos(th) * rr
	var cz := road_center.z + sin(th) * rr
	var road_elev := _noise.get_noise_2d(cx, cz) * hill_height + crest_amp * sin(3.0 * th)
	var sf := _start_factor(th)
	var bank := clampf(_road_curv(th) * bank_gain, -bank_max, bank_max) * (rho - rr) * (1.0 - 0.8 * sf)
	var t := 1.0 - smoothstep(half, half + road_shoulder, rdist)
	var h := lerpf(base, road_elev + bank, t)         # flat road surface (+ camber), berm added below
	var bd := rdist - half - berm_pos                 # raised berm ridge just outside each road edge
	return h + shoulder_berm * (1.0 - sf) * exp(-(bd * bd) / (berm_width * berm_width))

func _on_drag_strip(x: float, z: float) -> bool:
	if x >= strip_x0 and x <= strip_x1 and absf(z) <= strip_hw + 1.0:
		return true
	return (x - strip_x1) * (x - strip_x1) + z * z < runoff_r * runoff_r   # runoff pad

func _surface_color(x: float, z: float) -> Color:
	var c := grass_color.lerp(road_color, _road_t(x, z))       # grass or dirt road
	var ad := _asphalt_dist(x, z)
	var ta := 1.0 - smoothstep(asphalt_width * 0.5, asphalt_width * 0.5 + 1.5, ad)   # crisp asphalt edge
	c = c.lerp(asphalt_color, ta)                              # circuit asphalt
	if x >= strip_x0 and x <= strip_x1:                        # drag strip corridor (within terrain)
		var ts := 1.0 - smoothstep(strip_hw, strip_hw + 3.5, absf(z))
		c = c.lerp(asphalt_color, ts)
	return c

func grip_at(x: float, z: float) -> float:
	# traction by surface at a world position (queried per wheel by the vehicle)
	if _asphalt_dist(x, z) < asphalt_width * 0.5 + 1.0:
		return asphalt_grip                                   # circuit
	if _on_drag_strip(x, z):
		return asphalt_grip                                   # drag strip / runoff
	var dx := x - road_center.x
	var dz := z - road_center.z
	if sqrt(dx * dx + dz * dz) < patch_radius:
		return dirt_grip                                      # centre reactive patch
	if _road_t(x, z) > 0.4:
		return dirt_grip                                      # dirt rally loop
	return grass_grip

func _build() -> void:
	var verts := PackedVector3Array(); verts.resize(_n * _n)
	var norms := PackedVector3Array(); norms.resize(_n * _n)
	var cols := PackedColorArray(); cols.resize(_n * _n)
	var heights := PackedFloat32Array(); heights.resize(_n * _n)
	for j in range(_n):
		for i in range(_n):
			var x := i * _cs - _half
			var z := j * _cs - _half
			var h := _height(x, z)
			var idx := j * _n + i
			heights[idx] = h
			verts[idx] = Vector3(x, h, z)
			cols[idx] = _surface_color(x, z)
	for j in range(_n):
		for i in range(_n):
			var idx := j * _n + i
			var hl: float = heights[j * _n + max(i - 1, 0)]
			var hr: float = heights[j * _n + min(i + 1, _n - 1)]
			var hd: float = heights[max(j - 1, 0) * _n + i]
			var hu: float = heights[min(j + 1, _n - 1) * _n + i]
			norms[idx] = Vector3(hl - hr, 2.0 * _cs, hd - hu).normalized()
	var indices := PackedInt32Array()
	for j in range(cells):
		for i in range(cells):
			var a := j * _n + i
			var b := j * _n + i + 1
			var c := (j + 1) * _n + i
			var d := (j + 1) * _n + i + 1
			indices.append(a); indices.append(b); indices.append(c)   # wound so the top is the front face
			indices.append(b); indices.append(d); indices.append(c)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # terrain: render both sides (no see-through slopes)
	mi.material_override = mat
	add_child(mi)
	var shape := HeightMapShape3D.new()
	shape.map_width = _n
	shape.map_depth = _n
	shape.map_data = heights
	var col := CollisionShape3D.new()
	col.shape = shape
	col.scale = Vector3(_cs, 1.0, _cs)
	add_child(col)

func get_spawn() -> Transform3D:
	return get_spawn_for(1)                           # default: the dirt rally loop

func get_spawn_for(which: int) -> Transform3D:
	# which: 0 = centre dirt circle, 1 = dirt rally loop, 2 = asphalt ring. Spawn a short run-up BEFORE
	# the finish ray (theta=0) so that crossing it starts the lap + ghost.
	var rchar := center_lap_radius
	if which == 1:
		rchar = road_radius
	elif which == 2:
		rchar = asphalt_radius
	var th := -start_runup / rchar
	var r := _circuit_r(which, th)
	var pos := road_center + Vector3(cos(th), 0, sin(th)) * r
	pos.y = _height(pos.x, pos.z) + 1.8
	var tangent := Vector3(-sin(th), 0, cos(th))     # along the circuit, pointing toward the line
	return Transform3D(Basis(), pos).looking_at(pos + tangent, Vector3.UP)

func _circuit_r(which: int, th: float) -> float:
	if which == 0:
		return center_lap_radius
	if which == 2:
		return _asphalt_r(th)
	return _road(th)

func _markers() -> void:
	# roadside posts along the loop (alternating colours)
	var count := 60
	for k in range(count):
		var th := TAU * float(k) / float(count)
		var rr := _road(th)
		var radial := Vector3(cos(th), 0, sin(th))
		var c := road_center + radial * rr
		var col := Color(0.95, 0.95, 0.98) if k % 2 == 0 else Color(0.95, 0.5, 0.1)
		for s in [-1.0, 1.0]:
			var p := c + radial * (_road_halfwidth(th) + 1.5) * float(s)
			p.y = _height(p.x, p.z)
			_post(p, col)
	# start / finish gates on the timed circuits (centre circle + dirt loop + asphalt ring)
	_start_finish_gate(0)
	_start_finish_gate(1)
	_start_finish_gate(2)
	# asphalt circuit label (on the near straight, following the hills)
	var albl := Label3D.new()
	albl.text = "ASPHALT CIRCUIT"
	albl.font_size = 150; albl.pixel_size = 0.04
	albl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	albl.modulate = Color(0.82, 0.9, 1.0)
	albl.outline_size = 20; albl.outline_modulate = Color(0, 0, 0, 0.9)
	var alr := _asphalt_r(PI * 0.5)   # a point on the winding loop, straight ahead (+Z)
	albl.position = Vector3(road_center.x, _height(road_center.x, road_center.z + alr) + 7.0, road_center.z + alr)
	add_child(albl)

func _flat_slab(sz: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	# a flat asphalt slab with box collision; top surface sits at pos.y + sz.y/2
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new(); box.size = sz
	col.shape = box
	body.add_child(col)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = sz
	mi.mesh = bm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # no stray grey shadow rectangle
	body.add_child(mi)
	add_child(body)

func _build_drag_strip() -> void:
	# the straight + runoff pad, built as flat slabs that continue past the terrain edge
	var mat := StandardMaterial3D.new()
	mat.albedo_color = asphalt_color
	mat.roughness = 0.9
	var edge := _half - 6.0                                   # start just inside the terrain edge (overlap)
	var slen := strip_x1 - edge
	_flat_slab(Vector3(slen, 0.6, strip_hw * 2.0), Vector3((edge + strip_x1) * 0.5, _strip_elev - 0.3, 0.0), mat)
	_flat_slab(Vector3(runoff_r * 2.0, 0.6, runoff_r * 2.0), Vector3(strip_x1, _strip_elev - 0.3, 0.0), mat)
	var lbl := Label3D.new()
	lbl.text = "%.1f km STRAIGHT ->" % (strip_len / 1000.0)
	lbl.font_size = 150; lbl.pixel_size = 0.06
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = Color(0.82, 0.9, 1.0)
	lbl.outline_size = 20; lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.position = Vector3(edge + 70.0, _strip_elev + 7.0, 0.0)
	add_child(lbl)
	_strip_distance_markers()
	_strip_end_rails()

func _strip_distance_markers() -> void:
	# Distance posts every strip_marker_step down BOTH shoulders, a taller orange one on each
	# kilometre, plus a billboard call-out there. Counts derive from the strip's real length, so
	# changing strip_len re-marks the whole thing. The posts stand just INSIDE the slab edge:
	# past the terrain edge there is no ground outside it to stand on.
	var stations := int(floor((strip_x1 - strip_x0) / strip_marker_step))
	if stations < 1:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.12; cyl.bottom_radius = 0.12; cyl.height = 1.0   # unit height -> scaled per instance
	mm.mesh = cyl
	mm.instance_count = stations * 2
	var zoff := strip_hw - 0.8
	var i := 0
	for k in range(1, stations + 1):
		var d := strip_marker_step * float(k)
		var is_km := fposmod(d, strip_km_step) < 0.5
		var h := 2.6 if is_km else 1.6
		var col := Color(0.95, 0.5, 0.1) if is_km else Color(0.95, 0.95, 0.98)
		for s in [-1.0, 1.0]:
			var b := Basis(Vector3.RIGHT, Vector3.UP * h, Vector3.BACK)
			var p := Vector3(strip_x0 + d, _strip_elev + h * 0.5, zoff * float(s))
			mm.set_instance_transform(i, Transform3D(b, p))
			mm.set_instance_color(i, col)
			i += 1
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var pm := StandardMaterial3D.new()
	pm.vertex_color_use_as_albedo = true
	mmi.material_override = pm
	add_child(mmi)
	# kilometre call-outs, one per km, readable from either direction (billboarded)
	var d_km := strip_km_step
	while d_km <= strip_len + 0.5:
		var kl := Label3D.new()
		kl.text = "%.0f km" % (d_km / 1000.0)
		kl.font_size = 130; kl.pixel_size = 0.05
		kl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		kl.modulate = Color(1.0, 0.72, 0.35)
		kl.outline_size = 18; kl.outline_modulate = Color(0, 0, 0, 0.9)
		kl.position = Vector3(strip_x0 + d_km, _strip_elev + 4.2, zoff)
		add_child(kl)
		d_km += strip_km_step

func _strip_end_rails() -> void:
	# Barrier around the far lip of the runoff pad: an arc wrapping past 90 degrees each side, so an
	# overshoot AND a drift either way meet something solid instead of the void off the slab edge.
	var r := runoff_r - 4.0                      # inside the square pad at every angle (90.8 < 95)
	var a0 := -deg_to_rad(115.0)
	var a1 := deg_to_rad(115.0)
	var steps := maxi(2, int(ceil((a1 - a0) * r / rail_span)))
	var pts := PackedVector3Array()
	for k in range(steps + 1):
		var a := lerpf(a0, a1, float(k) / float(steps))
		pts.append(Vector3(strip_x1 + cos(a) * r, _strip_elev, sin(a) * r))
	_guard_rail(pts)

func _guard_rail(pts: PackedVector3Array) -> void:
	# W-beam barrier along a polyline: one static body carrying a box per span, with the beam
	# faces and posts drawn as two MultiMeshes (a 350 m arc is ~44 panels and ~176 posts).
	if pts.size() < 2:
		return
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var beams := MultiMesh.new()
	beams.transform_format = MultiMesh.TRANSFORM_3D
	var box := BoxMesh.new(); box.size = Vector3.ONE        # unit box -> sized per instance
	beams.mesh = box
	beams.instance_count = pts.size() - 1
	var posts: Array[Vector3] = []
	var carry := 0.0
	for k in range(pts.size() - 1):
		var a: Vector3 = pts[k]
		var b: Vector3 = pts[k + 1]
		var seg := b - a
		var span := seg.length()
		var dir := seg / span
		var side := Vector3(-dir.z, 0.0, dir.x)             # perpendicular in the ground plane
		var mid := (a + b) * 0.5 + Vector3(0, rail_height - rail_beam_h * 0.5, 0)
		beams.set_instance_transform(k, Transform3D(Basis(dir * span, Vector3.UP * rail_beam_h, side * rail_beam_t), mid))
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(span, rail_beam_h, rail_beam_t)
		col.shape = shape
		col.transform = Transform3D(Basis(dir, Vector3.UP, side), mid)
		body.add_child(col)
		var t := carry                                       # posts walk the polyline at a fixed spacing
		while t < span:
			posts.append(a + seg * (t / span))
			t += rail_post_step
		carry = t - span
	var bmi := MultiMeshInstance3D.new()
	bmi.multimesh = beams
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.72, 0.74, 0.76)
	bmat.metallic = 0.6; bmat.roughness = 0.4
	bmi.material_override = bmat
	body.add_child(bmi)
	var pmm := MultiMesh.new()
	pmm.transform_format = MultiMesh.TRANSFORM_3D
	var pcyl := CylinderMesh.new()
	pcyl.top_radius = 0.07; pcyl.bottom_radius = 0.07; pcyl.height = 1.0
	pmm.mesh = pcyl
	pmm.instance_count = posts.size()
	for k in range(posts.size()):
		var p: Vector3 = posts[k] + Vector3(0, rail_height * 0.5, 0)
		pmm.set_instance_transform(k, Transform3D(Basis(Vector3.RIGHT, Vector3.UP * rail_height, Vector3.BACK), p))
	var pmi := MultiMeshInstance3D.new()
	pmi.multimesh = pmm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.42, 0.44, 0.46)
	pmat.metallic = 0.5; pmat.roughness = 0.5
	pmi.material_override = pmat
	body.add_child(pmi)

func _post(pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.14; cyl.bottom_radius = 0.14; cyl.height = 2.0
	mi.mesh = cyl
	var m := StandardMaterial3D.new(); m.albedo_color = color
	mi.material_override = m
	mi.position = pos + Vector3(0, 1.0, 0)
	add_child(mi)

func _start_finish_gate(which: int) -> void:
	# a striped-post gate straddling the finish ray (theta=0) on circuit `which` (1=dirt loop, 2=asphalt),
	# with a banner beam + billboard text. The two posts sit just outside each road edge (radially).
	var r0 := _circuit_r(which, 0.0)
	var hw: float = asphalt_width * 0.5
	if which == 0:
		hw = 4.0                          # centre skid-pad: a modest gate width
	elif which == 1:
		hw = _road_halfwidth(0.0)
	var yg := _height(r0, 0.0)
	var post_h := 5.0
	var off := hw + 2.0
	var xin := r0 - off
	var xout := r0 + off
	_gate_post(Vector3(xin, yg, 0.0), post_h)
	_gate_post(Vector3(xout, yg, 0.0), post_h)
	# banner beam across the top (spans the road)
	var beam := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = Vector3(xout - xin, 0.45, 0.45)
	beam.mesh = bm
	var mat := StandardMaterial3D.new(); mat.albedo_color = Color(0.85, 0.12, 0.12)
	beam.material_override = mat
	beam.position = Vector3(r0, yg + post_h, 0.0)
	add_child(beam)
	# START / FINISH text hung above the beam
	var lbl := Label3D.new()
	lbl.text = "START / FINISH"
	lbl.font_size = 150; lbl.pixel_size = 0.028
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = Color(1.0, 0.9, 0.3)
	lbl.outline_size = 18; lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.position = Vector3(r0, yg + post_h + 1.3, 0.0)
	add_child(lbl)

func _build_obstacles() -> void:
	# solid, collidable trees + poles to crash into (M8 damage testing). On the ground's collision layer.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260730
	# a guaranteed little grove in the grass beside the start, so it's trivial to test a hit
	for p in [Vector2(188, -10), Vector2(198, -3), Vector2(208, 4), Vector2(193, 9), Vector2(150, 7), Vector2(158, -9)]:
		_obstacle(p.x, p.y, true, rng)
	# scatter the rest across the grass, skipping the roads / centre patch / drag strip
	var placed := 0
	var attempts := 0
	while placed < obstacle_count and attempts < obstacle_count * 12:
		attempts += 1
		var x := rng.randf_range(-size * 0.46, size * 0.46)
		var z := rng.randf_range(-size * 0.46, size * 0.46)
		if _on_road_or_patch(x, z):
			continue
		_obstacle(x, z, rng.randf() > 0.35, rng)
		placed += 1

func _on_road_or_patch(x: float, z: float) -> bool:
	if _road_t(x, z) > 0.05:
		return true                                            # on/near the dirt road
	var dx := x - road_center.x
	var dz := z - road_center.z
	if sqrt(dx * dx + dz * dz) < patch_radius + center_blend + 6.0:
		return true                                            # centre deformable patch
	if _asphalt_dist(x, z) < asphalt_width * 0.5 + 4.0:
		return true                                            # on the asphalt ring
	if x > strip_x0 - 30.0 and absf(z) < strip_hw + 8.0:
		return true                                            # drag strip corridor
	return false

func _obstacle(x: float, z: float, is_tree: bool, rng: RandomNumberGenerator) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector3(x, _height(x, z), z)
	var h := rng.randf_range(4.5, 6.5) if is_tree else rng.randf_range(2.8, 3.6)
	var r := rng.randf_range(0.42, 0.6) if is_tree else 0.17
	# collision cylinder (a touch fatter so it's easy to hit)
	var col := CollisionShape3D.new()
	var cs := CylinderShape3D.new(); cs.height = h; cs.radius = maxf(r, 0.28)
	col.shape = cs
	col.position = Vector3(0, h * 0.5, 0)
	body.add_child(col)
	# trunk mesh
	var trunk := MeshInstance3D.new()
	var cyl := CylinderMesh.new(); cyl.height = h; cyl.top_radius = r; cyl.bottom_radius = r * 1.15
	trunk.mesh = cyl
	trunk.position = Vector3(0, h * 0.5, 0)
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color(0.35, 0.23, 0.12) if is_tree else Color(0.62, 0.62, 0.66)
	trunk.material_override = tm
	body.add_child(trunk)
	if is_tree:
		var foliage := MeshInstance3D.new()
		var fr := rng.randf_range(2.0, 3.2)
		var sph := SphereMesh.new(); sph.radius = fr; sph.height = fr * 2.0
		foliage.mesh = sph
		foliage.position = Vector3(0, h + fr * 0.4, 0)
		var fm := StandardMaterial3D.new()
		fm.albedo_color = Color(0.17, 0.40, 0.15).lerp(Color(0.32, 0.50, 0.20), rng.randf())
		foliage.material_override = fm
		body.add_child(foliage)
	add_child(body)

func _gate_post(base: Vector3, height: float) -> void:
	# a red/white striped gate post built from stacked segments
	var segs := 5
	var seg_h := height / float(segs)
	for i in range(segs):
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.18; cyl.bottom_radius = 0.18; cyl.height = seg_h
		mi.mesh = cyl
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.9, 0.12, 0.12) if i % 2 == 0 else Color(0.97, 0.97, 0.97)
		mi.material_override = m
		mi.position = Vector3(base.x, base.y + seg_h * (float(i) + 0.5), base.z)
		add_child(mi)
