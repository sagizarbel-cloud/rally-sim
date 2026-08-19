extends Node3D
class_name DeformableTerrain
## M3 - large deformable dirt field. GPU height-displacement + Bekker-Wong dig model.
##
## Rendering: every tile shares ONE pre-built tessellated plane and is displaced in a
## vertex shader by a per-tile height texture. Digging just rewrites texture pixels -> no
## CPU remeshing, so tiles load without a stutter. A parallel height array feeds a per-tile
## HeightMapShape collider (re-cooked on a throttle) so the wheels physically drop into ruts.
## Only tiles near the car are live; the rest of the field is flat squares. A square that has
## been dug keeps drawing its OWN height texture (see Rut/_persist) instead of a pristine one,
## so driving away from a rut does not erase it.
##
## Dig model (Bekker-Wong terramechanics):
##   * Pressure-sinkage: z = (p/k)^(1/n), p = Fz/(contact_len*tire_width). LOAD sets the
##     target depth; it is approached PER DISTANCE ROLLED (not per time), so a fast pass and
##     a slow pass leave the same groove, and repeated passes deepen it (multi-pass sinkage).
##   * Wheelspin excavation: a spinning wheel (slip) digs deeper than a rolling one.
##   * Pile-up: soil displaced from the rut is pushed into raised shoulders (berms).

@export var zone_center := Vector3(120, 0, 0)   # dirt field centred on the track (just big enough for it)
@export var zone_size := 160.0
@export var track_center := Vector3(120, 0, 0)  # small loop, reachable from start
@export var track_corridor := 10.0              # wear the track (posts at +-5m) plus ~5m each side
@export var tile_size := 12.0                   # metres per tile (smaller = cheaper loads)
@export var tile_cells := 64                    # cells per tile side -> cell = size/cells
@export var bed_height := 0.15                   # undisturbed dirt surface
@export var max_sinkage := 0.12
@export var height_scale := 0.6                  # height encoded as h/height_scale in an RGBA8 texture
@export var keep_radius := 15.0                  # tiles always loaded within this of the car
@export var cone_reach := 30.0                   # + load this far ahead in the DRIVING direction (45 deg cone)
@export var unload_radius := 36.0                # free tiles beyond this (ruts persisted)

# Bekker pressure-sinkage
@export var k_terrain := 500000.0                # ~11cm ruts under load (between the last two)
@export var n_exp := 1.0
@export var tire_width := 0.22
@export var contact_len := 0.25
@export var pass_gain := 0.7                     # fraction of remaining depth dug per pass

# wheelspin excavation
@export var spin_dig := 0.06                     # extra depth per unit slip (m)
@export var max_spin_sink := 0.12
@export var spin_rate := 1.6                     # how fast a spinning wheel excavates

# pile-up / berms (kept very subtle so they can't launch/flip the car)
@export var pileup_frac := 0.05                  # displaced soil pushed to the shoulders
@export var max_pileup := 0.008
@export var berm_fill_floor := 0.03              # loose soil settles back into ruts, but they keep >= this depth
@export var rise_vis := 0.005                    # berm height at which the brighter shoulder colour is full

@export var flat_vis_cells := 32                 # mesh cells per side of a DUG tile's unloaded visual
												 # (snapped down to a divisor of tile_cells; colour is
												 # per-pixel, so this only sets displacement/lighting detail)

@export var dirt_color := Color(0.66, 0.48, 0.26)   # brighter, more saturated dirt
@export var rut_color := Color(0.22, 0.15, 0.08)    # deeper/darker ruts (bigger contrast)
@export var berm_color := Color(1.0, 0.90, 0.66)    # brighter piled soil (bigger contrast)

const TRACK_R := 40.0
const TRACK_WOBBLE := 10.0
const TRACK_BENDS := 3.0

var vehicle: Node

var _cs := 0.0
var _tn := 0                     # texture / height nodes per tile side (cells + 1)
var _half_t := 0.0               # tile half size
var _half := 0.0
var _min := Vector2.ZERO
var _ntiles := 0
var _tiles := {}                 # Vector2i -> Tile
var _plane: ArrayMesh            # shared tessellated plane (built once)
var _shader: Shader
var _recook_accum := 0.0
var _saved := {}                 # Vector2i -> Rut, so ruts survive tile unload/reload
var _flat_quad: PlaneMesh        # cheap flat square (undug ground is always shown as these)
var _flat_quad_dug: PlaneMesh    # tessellated square for ground that HAS been dug (4 verts show no rut)
var _flat_mat: ShaderMaterial    # SAME deformable shader + a flat height texture (so no load seam)
var _flat_tex: ImageTexture
var _flat_vis := {}              # Vector2i -> MeshInstance3D (flat visual; hidden while a tile is active)
var _fstep := 1                  # tile cells per unloaded-visual cell (exact divisor of tile_cells)
var _fvn := 0                    # unloaded-visual nodes per side

const SHADER_CODE := """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D height_tex : filter_linear, repeat_disable;   // clamp: a tile edge must not blend with the opposite edge
uniform float texel;
uniform float cellw;
uniform float hscale;
uniform float bed;
uniform float maxsink;
uniform vec3 dirt : source_color;
uniform vec3 rut : source_color;
uniform vec3 bright : source_color;
uniform float risescale;
void vertex() {
float h = texture(height_tex, UV).r * hscale;
VERTEX.y = h;
float hl = texture(height_tex, UV - vec2(texel, 0.0)).r * hscale;
float hr = texture(height_tex, UV + vec2(texel, 0.0)).r * hscale;
float hd = texture(height_tex, UV - vec2(0.0, texel)).r * hscale;
float hu = texture(height_tex, UV + vec2(0.0, texel)).r * hscale;
NORMAL = normalize(vec3(hl - hr, 2.0 * cellw, hd - hu));
}
void fragment() {
// height is read PER PIXEL, not interpolated from the vertices: rut colour is then set by
// the height TEXTURE's resolution, so a coarse mesh still shows a rut at full darkness.
float vh = texture(height_tex, UV).r * hscale;
float depth = clamp((bed - vh - 0.015) / maxsink, 0.0, 1.0);      // deadzone: only real ruts darken, not faint churn
float rise = clamp((vh - bed - 0.0015) / risescale, 0.0, 1.0);   // deadzone: ignore texture-rounding noise
vec3 c = mix(dirt, rut, depth);
c = mix(c, bright, rise * 0.9);
ALBEDO = c;
ROUGHNESS = 1.0;
METALLIC = 0.0;
}
"""

class Tile:
	var body: StaticBody3D
	var mi: MeshInstance3D
	var mat: ShaderMaterial
	var img: Image
	var tex: ImageTexture
	var heights: PackedFloat32Array
	var shape: HeightMapShape3D
	var center: Vector3
	var tx := 0
	var tz := 0
	var tex_dirty := false
	var col_dirty := false
	var dug := false

class Rut:
	## Deformation that OUTLIVES its tile. Freeing a tile must not erase the ruts you just dug, so
	## the released tile hands its heights (for the collider when it reloads) AND its height texture
	## (for the flat quad that takes over rendering) to this record.
	var heights: PackedFloat32Array
	var img: Image
	var tex: ImageTexture
	var mat: ShaderMaterial

func _ready() -> void:
	_cs = tile_size / float(tile_cells)
	_tn = tile_cells + 1
	_half_t = tile_size * 0.5
	_half = zone_size * 0.5
	_min = Vector2(zone_center.x - _half, zone_center.z - _half)
	_ntiles = int(round(zone_size / tile_size))
	# the unloaded visual of a dug tile reuses that tile's own height texture, so its nodes must land
	# exactly ON tile nodes (borders included) or the two meshes crack apart. Take the finest step
	# that divides tile_cells and still fits the budget.
	_fstep = 1
	for step in range(1, tile_cells + 1):
		if tile_cells % step == 0 and tile_cells / step <= flat_vis_cells:
			_fstep = step
			break
	_fvn = tile_cells / _fstep + 1
	_shader = Shader.new(); _shader.code = SHADER_CODE
	_build_plane()
	_build_flat_visuals()
	_build_track()

func _ground_material(tex: Texture2D, texel: float, cellw: float) -> ShaderMaterial:
	# THE one place a ground material is configured. All three paths - the live tile, the pristine
	# flat square and a dug tile's unloaded square - must shade identically or the load boundary
	# shows a seam, so they differ only in the height texture they read and how far apart its
	# texels sit (texel/cellw, which set the finite-difference normal's slope).
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("height_tex", tex)
	m.set_shader_parameter("texel", texel)
	m.set_shader_parameter("cellw", cellw)
	m.set_shader_parameter("hscale", height_scale)
	m.set_shader_parameter("bed", bed_height)
	m.set_shader_parameter("maxsink", max_sinkage)
	m.set_shader_parameter("dirt", dirt_color)
	m.set_shader_parameter("rut", rut_color)
	m.set_shader_parameter("bright", berm_color)
	m.set_shader_parameter("risescale", maxf(rise_vis, 0.001))
	return m

func _build_flat_visuals() -> void:
	# the WHOLE field is always shown as flat brown squares (cheap: shared quad + material);
	# a square's flat visual is hidden only while its deformable tile is active near the car.
	_flat_quad = PlaneMesh.new()
	_flat_quad.size = Vector2(tile_size, tile_size)
	# ... except once a square has been dug: 4 corner vertices cannot carry a rut's displacement,
	# so dug ground swaps to this coarser copy of the live tile's mesh (shared by every dug square).
	_flat_quad_dug = PlaneMesh.new()
	_flat_quad_dug.size = Vector2(tile_size, tile_size)
	_flat_quad_dug.subdivide_width = _fvn - 2
	_flat_quad_dug.subdivide_depth = _fvn - 2
	_flat_quad_dug.custom_aabb = AABB(Vector3(-_half_t, -1.0, -_half_t), Vector3(tile_size, 2.0, tile_size))
	var fimg := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	fimg.fill(Color(bed_height / height_scale, 0, 0, 1))
	_flat_tex = ImageTexture.create_from_image(fimg)
	_flat_mat = _ground_material(_flat_tex, 0.5, _cs)        # same shader as live tiles -> identical shading
	for tz in range(_ntiles):
		for tx in range(_ntiles):
			var mi := MeshInstance3D.new()
			mi.mesh = _flat_quad
			mi.material_override = _flat_mat
			mi.position = Vector3(_min.x + (tx + 0.5) * tile_size, 0.0, _min.y + (tz + 0.5) * tile_size)
			add_child(mi)
			_flat_vis[Vector2i(tx, tz)] = mi

func _build_plane() -> void:
	# one shared flat, tessellated, UV'd plane; the shader displaces it per tile
	var verts := PackedVector3Array(); verts.resize(_tn * _tn)
	var uvs := PackedVector2Array(); uvs.resize(_tn * _tn)
	var norms := PackedVector3Array(); norms.resize(_tn * _tn)
	for j in range(_tn):
		for i in range(_tn):
			var idx := j * _tn + i
			verts[idx] = Vector3(i * _cs - _half_t, 0.0, j * _cs - _half_t)
			uvs[idx] = Vector2(float(i) / float(_tn - 1), float(j) / float(_tn - 1))
			norms[idx] = Vector3.UP
	var indices := PackedInt32Array()
	for j in range(tile_cells):
		for i in range(tile_cells):
			var a := j * _tn + i
			var b := j * _tn + i + 1
			var d := (j + 1) * _tn + i
			var e := (j + 1) * _tn + i + 1
			# WINDING: the top of the tile must be the FRONT face. Wound the other way round,
			# `cull_disabled` still draws it, but Godot negates NORMAL on back faces - the
			# shader's carefully-built up-normal then points into the ground, the sun
			# contributes nothing, and the whole tile renders ambient-only DARK BROWN beside
			# the light flat squares. That was the bug, and cull_disabled is what hid it
			# (nothing goes invisible, it just goes dark). Same class as the M5 stage flip.
			indices.append(a); indices.append(b); indices.append(d)
			indices.append(b); indices.append(e); indices.append(d)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices
	_plane = ArrayMesh.new()
	_plane.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# generous AABB so it isn't culled when the shader pushes verts around
	_plane.custom_aabb = AABB(Vector3(-_half_t, -1.0, -_half_t), Vector3(tile_size, 2.0, tile_size))

func _tile_index(wx: float, wz: float) -> Vector2i:
	return Vector2i(int(floor((wx - _min.x) / tile_size)), int(floor((wz - _min.y) / tile_size)))

func _on_track(wx: float, wz: float) -> bool:
	var dx := wx - track_center.x
	var dz := wz - track_center.z
	var rho := sqrt(dx * dx + dz * dz)
	var rr := TRACK_R + TRACK_WOBBLE * sin(TRACK_BENDS * atan2(dz, dx))
	return absf(rho - rr) <= track_corridor

func _ensure_tile(tx: int, tz: int) -> void:
	if tx < 0 or tz < 0 or tx >= _ntiles or tz >= _ntiles:
		return
	var key := Vector2i(tx, tz)
	if _tiles.has(key):
		return
	var t := Tile.new()
	t.tx = tx; t.tz = tz
	t.center = Vector3(_min.x + (tx + 0.5) * tile_size, 0.0, _min.y + (tz + 0.5) * tile_size)
	var r: Rut = _saved.get(key)
	if r != null:                                    # returning to ground we already dug
		t.heights = r.heights.duplicate()            # the tile mutates its own copy; _persist writes back
		t.img = r.img                                # SHARE the texture with the unloaded square, so
		t.tex = r.tex                                # neither a re-upload nor a chance of them drifting
		t.dug = true
	else:
		t.heights = PackedFloat32Array(); t.heights.resize(_tn * _tn); t.heights.fill(bed_height)
		t.img = Image.create(_tn, _tn, false, Image.FORMAT_RGBA8)
		t.img.fill(Color(bed_height / height_scale, 0, 0, 1))
		t.tex = ImageTexture.create_from_image(t.img)
	t.mat = _ground_material(t.tex, 1.0 / float(_tn), _cs)
	t.body = StaticBody3D.new()
	t.body.position = t.center
	t.body.collision_layer = 1
	t.body.collision_mask = 0
	t.mi = MeshInstance3D.new()
	t.mi.mesh = _plane
	t.mi.material_override = t.mat
	t.body.add_child(t.mi)
	t.shape = HeightMapShape3D.new()
	t.shape.map_width = _tn
	t.shape.map_depth = _tn
	t.shape.map_data = t.heights
	var col := CollisionShape3D.new()
	col.shape = t.shape
	col.scale = Vector3(_cs, 1.0, _cs)
	t.body.add_child(col)
	add_child(t.body)
	if _flat_vis.has(key):
		_flat_vis[key].visible = false          # deformable tile takes over rendering here
	_tiles[key] = t

func _physics_process(delta: float) -> void:
	if vehicle == null or not vehicle.has_method("get_wheels"):
		return
	if Input.is_action_just_pressed("reset"):
		_reset_dirt()

	var car: Vector3 = vehicle.global_position
	var vel: Vector3 = vehicle.linear_velocity
	var hvel := Vector3(vel.x, 0.0, vel.z)
	var spd := hvel.length()
	var dist := spd * delta
	var drive_dir := (hvel / spd) if spd > 0.5 else Vector3.ZERO
	# load tiles: always within keep_radius, plus a 45-degree cone ahead in the DRIVING
	# direction (velocity-based, so it also loads ahead when reversing). Unload the rest.
	var ct := _tile_index(car.x, car.z)
	var reach := int(ceil(cone_reach / tile_size)) + 1
	for dj in range(-reach, reach + 1):
		for di in range(-reach, reach + 1):
			var tx := ct.x + di
			var tz := ct.y + dj
			var off := Vector3(_min.x + (tx + 0.5) * tile_size - car.x, 0.0, _min.y + (tz + 0.5) * tile_size - car.z)
			var d := off.length()
			var want := d <= keep_radius
			if not want and d <= cone_reach and spd > 0.5:
				want = off.normalized().dot(drive_dir) >= 0.707
			if want:
				_ensure_tile(tx, tz)
	_unload_far(car)

	var wheels: Array = vehicle.get_wheels()
	for w in wheels:
		if not w.contact or w.Fz <= 1.0:
			continue
		var cp: Vector3 = w.contact_point
		if absf(cp.x - zone_center.x) > _half or absf(cp.z - zone_center.z) > _half:
			continue
		if not _on_track(cp.x, cp.z):
			continue                                # only the track corridor wears
		var ti := _tile_index(cp.x, cp.z)
		var t: Tile = _tiles.get(Vector2i(ti.x, ti.y))
		if t == null:
			continue
		_dig(t, w, cp, dist, delta)

	# push texture updates (cheap) and re-cook colliders on a throttle
	for t in _tiles.values():
		if t.tex_dirty:
			t.tex.update(t.img)
			t.tex_dirty = false
	_recook_accum += delta
	if _recook_accum > 0.1:
		for t in _tiles.values():
			if t.col_dirty:
				t.shape.map_data = t.heights
				t.col_dirty = false
		_recook_accum = 0.0

func _dig(_t: Tile, w, cp: Vector3, dist: float, delta: float) -> void:
	var p := float(w.Fz) / (contact_len * tire_width)
	var z_load := clampf(pow(p / k_terrain, 1.0 / n_exp), 0.0, max_sinkage)
	var slip: float = w.slip
	var z_spin := clampf(slip * spin_dig, 0.0, max_spin_sink)
	var target := maxf(bed_height - z_load - z_spin, 0.02)   # stay above the base ground
	# how much to move toward target this frame: rolling is per-distance (speed-independent),
	# spinning digs over time even when stopped.
	var roll := clampf(dist / contact_len, 0.0, 1.0) * pass_gain
	var spin := clampf(slip * spin_rate * delta, 0.0, 1.0)
	var approach := clampf(roll + spin, 0.0, 1.0)
	if approach <= 0.0:
		return

	var sink := bed_height - target                            # total depth at the centre
	var rad := maxi(2, int(round(tire_width / _cs)))           # wider, SMOOTH-walled rut (no ledge to trip on)
	# carve by WORLD position so a rut continues across tile borders (each cell -> its own tile)
	for dj in range(-(rad + 1), rad + 2):
		for di in range(-(rad + 1), rad + 2):
			var nr := sqrt(float(di * di + dj * dj)) / float(rad)
			if nr > 1.8:
				continue
			var wx := cp.x + float(di) * _cs
			var wz := cp.z + float(dj) * _cs
			var tt := _tile_at(wx, wz)
			if tt == null:
				continue
			var lii := int(round((wx - (tt.center.x - _half_t)) / _cs))
			var ljj := int(round((wz - (tt.center.z - _half_t)) / _cs))
			if lii < 0 or ljj < 0 or lii >= _tn or ljj >= _tn:
				continue
			var idx := ljj * _tn + lii
			var cur: float = tt.heights[idx]
			if nr <= 1.0:
				var wgt := 1.0 - smoothstep(0.0, 1.0, nr)      # smooth bowl -> gentle walls
				var ctarget := maxf(bed_height - sink * wgt, 0.02)
				if ctarget < cur:
					_set_h(tt, idx, lii, ljj, cur - (cur - ctarget) * approach)
			else:                                              # nr <= 1.8
				var bw := (1.8 - nr) / 0.8
				if cur >= bed_height:                          # undisturbed shoulder -> low berm
					var berm := minf(bed_height + sink * pileup_frac * bw, bed_height + max_pileup)
					if berm > cur:
						_set_h(tt, idx, lii, ljj, cur + (berm - cur) * approach * 0.6)
				else:                                          # rutted -> loose soil settles back, less than it sank
					var fill := bed_height - berm_fill_floor
					if fill > cur:
						_set_h(tt, idx, lii, ljj, cur + (fill - cur) * approach * 0.15)

func _tile_at(wx: float, wz: float) -> Tile:
	var ti := _tile_index(wx, wz)
	return _tiles.get(Vector2i(ti.x, ti.y))

func _set_h(t: Tile, idx: int, ii: int, jj: int, h: float) -> void:
	t.heights[idx] = h
	t.img.set_pixel(ii, jj, Color(h / height_scale, 0, 0, 1))
	t.tex_dirty = true
	t.col_dirty = true
	t.dug = true
	# keep shared border cells equal in the neighbouring tile so their meshes meet (no crack)
	if ii == 0:
		_mirror(t.tx - 1, t.tz, _tn - 1, jj, h)
	elif ii == _tn - 1:
		_mirror(t.tx + 1, t.tz, 0, jj, h)
	if jj == 0:
		_mirror(t.tx, t.tz - 1, ii, _tn - 1, h)
	elif jj == _tn - 1:
		_mirror(t.tx, t.tz + 1, ii, 0, h)

func _mirror(tx: int, tz: int, ii: int, jj: int, h: float) -> void:
	var nt: Tile = _tiles.get(Vector2i(tx, tz))
	if nt == null:
		return
	nt.heights[jj * _tn + ii] = h
	nt.img.set_pixel(ii, jj, Color(h / height_scale, 0, 0, 1))
	nt.tex_dirty = true
	nt.col_dirty = true
	nt.dug = true                                    # its border row IS dug: it must persist like any other

func _unload_far(car: Vector3) -> void:
	var rem: Array = []
	for key in _tiles:
		var t: Tile = _tiles[key]
		if Vector2(t.center.x - car.x, t.center.z - car.z).length() > unload_radius:
			if t.dug:
				_persist(key, t)                      # keep the ruts - the geometry AND the colour
			t.body.queue_free()
			if _flat_vis.has(key):
				_flat_vis[key].visible = true         # the flat square takes rendering back over
			rem.append(key)
	for key in rem:
		_tiles.erase(key)

func _persist(key: Vector2i, t: Tile) -> void:
	# A released tile hands its height texture to the flat square that takes over rendering here, so
	# the ruts stay exactly as dark as they were under the car instead of snapping back to pristine
	# dirt. Ground that was never dug never reaches this and keeps the one shared flat material, so
	# undriven field costs nothing extra.
	if t.tex_dirty:
		t.tex.update(t.img)                          # the square inherits this texture: flush before handover
		t.tex_dirty = false
	var r: Rut = _saved.get(key)
	if r == null:
		r = Rut.new()
		r.img = t.img
		r.tex = t.tex
		r.mat = _ground_material(t.tex, float(_fstep) / float(_tn), _cs * float(_fstep))
		_saved[key] = r
	r.heights = t.heights.duplicate()
	var mi: MeshInstance3D = _flat_vis.get(key)
	if mi != null:
		mi.mesh = _flat_quad_dug
		mi.material_override = r.mat

func _reset_dirt() -> void:
	for t in _tiles.values():
		t.body.queue_free()
	_tiles.clear()
	_saved.clear()
	for mi in _flat_vis.values():
		mi.mesh = _flat_quad                          # back to the cheap 2-triangle pristine square
		mi.material_override = _flat_mat
		mi.visible = true

func _build_track() -> void:
	var n := 42                                     # ~6 m between posts along the loop
	for k in range(n):
		var a := TAU * float(k) / float(n)
		var rr := TRACK_R + TRACK_WOBBLE * sin(TRACK_BENDS * a)
		var dir := Vector3(cos(a), 0, sin(a))
		var mid := track_center + dir * rr
		_post(mid - dir * 5.0, Color(0.95, 0.5, 0.1))   # 10 m gate (inner)
		_post(mid + dir * 5.0, Color(0.95, 0.95, 0.98))  # outer
	var lbl := Label3D.new()
	lbl.text = "DIRT TRACK"
	lbl.font_size = 140; lbl.pixel_size = 0.02
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = Color(0.9, 0.65, 0.35)
	lbl.outline_size = 18; lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.position = track_center + Vector3(0, bed_height + 4.0, 0)
	add_child(lbl)

func _post(pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.12; cyl.bottom_radius = 0.12; cyl.height = 1.6
	mi.mesh = cyl
	var m := StandardMaterial3D.new(); m.albedo_color = color
	mi.material_override = m
	mi.position = Vector3(pos.x, bed_height + 0.8, pos.z)
	add_child(mi)
