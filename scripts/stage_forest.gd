extends RefCounted
class_name StageForest
## ARC E - the roadside spruce forest of the generated stage (SHAKEDOWN).
##
## Two jobs, and the second is why it exists now:
##   1. It is scenery: tall spruces lining a gravel road are what a forest rally stage LOOKS like,
##      and they give the eye scale and parallax that open grass cannot.
##   2. It is an OCCLUDER. A sight line through a forest survives with probability
##      exp(-density x crown width x depth) - at one tree per `spacing^2` (33 m^2), ~4 m crowns and
##      two chunks (90 m) of depth that is ~1e-5. That is what lets StageChunks stream only a narrow
##      window `band_chunks` wide either side of the road instead of everything in sight.
##
## DETERMINISTIC AND LOAD-ORDER FREE, like the ground it stands on. Trees live on a GLOBAL lattice of
## `spacing` metre cells; each cell's tree position, size, yaw and tint are a hash of the cell and the
## stage seed. A tree belongs to the one chunk its jittered position falls in, so neighbouring chunks
## partition the forest exactly and the same seed always grows the same forest, at any LOD.
##
## Trees are built from the chunk's OWN sample arrays (height and edge distance, apron included), so
## growing a chunk's forest costs no extra sample_at() - the 11.4 us road search D4 measured as 96% of
## a chunk's cost. A chunk's trees are MultiMesh children of the chunk's MeshInstance3D: they hide,
## cache and free with it, and cost one draw call per chunk per LOD.

var area                                 ## StageArea
var spacing := 5.75                      ## m: one tree per spacing^2 = 33 m^2, before clearings
var clearance := 5.0                     ## m outside the carriageway edge kept clear of trunks
var edge_ramp := 7.0                     ## m over which the forest thickens from the clearance line
var detail_m := 80.0                     ## camera distance at which a chunk swaps to silhouettes.
                                         ## 110 -> 80 m after the fullscreen drive: past 80 m a
                                         ## 25 m spruce is under ~1/8 of the screen tall, and the
                                         ## silhouette is the same outline.
var min_h := 16.0                        ## m, tree height range (mature Norway spruce: 15-35 m)
var max_h := 29.0
var collide := true                      ## trunks near the car are solid

var _seed := 0
var _noise: FastNoiseLite
var _ends: Array = []                    ## road ends: no trees in front of the tunnel mouths
var mesh_near: ArrayMesh
var mesh_far: ArrayMesh
var _mat: ShaderMaterial

const FOREST_SHADER := """
shader_type spatial;
// Vertex colour carries the bough shading (dark inside, light tips, darker low down); the MultiMesh
// instance colour, multiplied in by the engine, carries each tree's tint.
// Wind: a slow two-frequency sway that grows with height squared, phased by the tree's position so
// neighbours do not move in lockstep. The mesh is built at UNIT height, so VERTEX.y is the fraction
// of the tree's height and the sway scales with the instance.
uniform float sway = 0.010;
void vertex() {
	vec3 wp = MODEL_MATRIX[3].xyz;
	float ph = wp.x * 0.071 + wp.z * 0.053;
	float h = VERTEX.y;
	float s = (sin(TIME * 0.83 + ph) * 0.65 + sin(TIME * 2.07 + ph * 1.7) * 0.25) * sway * h * h;
	VERTEX.x += s;
	VERTEX.z += s * 0.6;
}
// The colours are authored in sRGB (as a person picks them); the shader works in linear light.
vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}
void fragment() {
	ALBEDO = to_linear(clamp(COLOR.rgb, 0.0, 1.0));
	ROUGHNESS = 0.92;
	SPECULAR = 0.25;
	// (No BACKLIGHT: it switches the material onto the translucency lighting path for every tree
	// pixel, and the 2026-11-17 fullscreen drive was bound by per-pixel cost.)
}
"""

## BAKED-SHADOW VARIANT (2026-11-18). The same material plus a light() function that takes the sun's
## visibility from INSTANCE_CUSTOM.r - baked per tree from the trees around it (StageChunks) - and
## combines it with the live shadow, if any, by taking the darker of the two. Used only when the
## shadow mode is hybrid or baked; the live-only mode keeps Godot's own lighting untouched.
const BAKED_LIGHT := """
uniform float bake_strength = 1.0;
void light() {
	float a = ATTENUATION;
	if (LIGHT_IS_DIRECTIONAL) {
		// SELF-SHADOW: the live shadow map shaded each spruce's inner boughs under the tier above;
		// without it the baked trees came out pale grey-green. The mesh is built at unit height
		// with a 0.17 base radius, so a vertex's distance from the axis over the crown radius at
		// its height says how far out on the bough it is: the tips see the sun, the inside does not.
		a = min(a, mix(1.0, ivis * mix(0.06, 1.0, iself * iself * iself), bake_strength));
	}
	// Burley diffuse, as Godot's own default lighting computes it (scene_forward_lights_inc), so
	// the baked modes light a surface exactly as the live mode does. Plain Lambert lost most of a low
	// evening sun on rough ground, where Burley's grazing-angle term is ~1.7x.
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float ldh = clamp(dot(LIGHT, normalize(VIEW + LIGHT)), 0.0, 1.0);
	float fd90m1 = 2.0 * ldh * ldh * ROUGHNESS - 0.5;
	float fdv = 1.0 + fd90m1 * pow(1.0 - ndv, 5.0);
	float fdl = 1.0 + fd90m1 * pow(1.0 - ndl, 5.0);
	DIFFUSE_LIGHT += fdv * fdl * ndl * a * LIGHT_COLOR / PI;
	// No specular: a spruce crown at roughness 0.92 has next to none, and a hand-written highlight
	// here turned every sunlit bough grey.
}
"""
var mat_baked: ShaderMaterial

func _init(a) -> void:
	area = a
	_seed = int(area.def.seed)
	_noise = FastNoiseLite.new()
	_noise.seed = _seed & 0x7FFFFFFF
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0 / 140.0         # clearings and thickets on a ~100 m scale
	_noise.fractal_octaves = 2
	var cl = area.gen.centreline if area.gen != null else null
	if cl != null:
		_ends = [cl.point_at(0.0)["pos"], cl.point_at(cl.length())["pos"]]
	var sh := Shader.new()
	sh.code = FOREST_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	var shb := Shader.new()
	shb.code = FOREST_SHADER.replace("uniform float sway", "varying float ivis;\nvarying float iself;\nuniform float sway").replace("void vertex() {", "void vertex() {\n\tivis = INSTANCE_CUSTOM.r;\n\tiself = smoothstep(0.25, 0.85, length(VERTEX.xz) / max(0.17 * (1.0 - VERTEX.y * 0.92), 0.01));") + BAKED_LIGHT
	mat_baked = ShaderMaterial.new()
	mat_baked.shader = shb
	mesh_near = _spruce_mesh(8, 7, true)
	mesh_far = _spruce_mesh(3, 4, false)

# ---------------------------------------------------------------- the tree meshes

func _spruce_mesh(tiers: int, points: int, trunk: bool) -> ArrayMesh:
	## A Norway spruce at UNIT height: a narrow cone of drooping bough tiers. Each tier is a star of
	## `points` branch tips (alternating long and short, so the silhouette is ragged rather than a
	## clean cone) fanned from a stem point above, with an underside fanned back to the stem so the
	## crown is dark from below rather than hollow. Instances scale it to their height and width.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var crown_base := 0.10                # the lowest boughs start at a tenth of the height
	var base_r := 0.17                    # crown radius at the bottom, in heights (width ~ 0.34 H)
	for t in range(tiers):
		var f0: float = float(t) / float(tiers)          # 0 at the bottom tier
		var f1: float = float(t + 1) / float(tiers)
		var y_bot: float = lerpf(crown_base, 0.93, f0)
		var y_top: float = lerpf(crown_base, 0.93, f1) + 0.16 * (1.0 - f0) + 0.03
		if t == tiers - 1:
			y_top = 1.0
		var r: float = base_r * pow(1.0 - f0 * 0.92, 1.1) * (1.0 + 0.12 * sin(float(t) * 2.3))
		var droop: float = 0.025 * (1.0 - f0)           # tips hang below the tier's attachment
		var ao: float = lerpf(0.55, 1.0, f0)            # low boughs are shaded by those above
		var apex := Vector3(0.0, y_top, 0.0)
		var under := Vector3(0.0, y_bot + 0.02, 0.0)
		var ring: Array = []
		var n: int = points * 2
		var rot: float = float(t) * 0.9
		for i in range(n):
			var a: float = TAU * float(i) / float(n) + rot
			var rr: float = r * (1.0 if i % 2 == 0 else 0.62)
			var yy: float = y_bot - (droop if i % 2 == 0 else droop * 0.4)
			ring.append(Vector3(cos(a) * rr, yy, sin(a) * rr))
		var c_tip := Color(0.30, 0.42, 0.26) * ao
		var c_in := Color(0.10, 0.15, 0.09) * ao
		var c_under := Color(0.07, 0.09, 0.06) * ao
		for i in range(n):
			var p0: Vector3 = ring[i]
			var p1: Vector3 = ring[(i + 1) % n]
			# upper surface: apex -> tips. Godot's front face is CLOCKWISE seen from outside, and the
			# ring runs clockwise seen from above (+x toward +z), so apex, p0, p1 faces up and out.
			_v(st, apex, Vector3.UP, c_in)
			_v(st, p0, (Vector3(p0.x, 0.0, p0.z).normalized() + Vector3(0, 0.8, 0)).normalized(), c_tip if i % 2 == 0 else c_tip * 0.8)
			_v(st, p1, (Vector3(p1.x, 0.0, p1.z).normalized() + Vector3(0, 0.8, 0)).normalized(), c_tip if (i + 1) % 2 == 0 else c_tip * 0.8)
			if trunk and f0 < 0.5:
				# underside: back to the stem, facing down. Only the lower half of the crown - nobody
				# stands under the top of a 25 m spruce, and it saves a quarter of the triangles.
				_v(st, under, Vector3.DOWN, c_under)
				_v(st, p1, (Vector3(p1.x, 0.0, p1.z).normalized() + Vector3(0, -0.6, 0)).normalized(), c_under * 1.4)
				_v(st, p0, (Vector3(p0.x, 0.0, p0.z).normalized() + Vector3(0, -0.6, 0)).normalized(), c_under * 1.4)
	if trunk:
		# a six-sided trunk from the ground into the crown
		var tr0 := 0.014
		var tr1 := 0.006
		var yt := 0.55
		var ct := Color(0.24, 0.17, 0.11)
		for i in range(6):
			var a0: float = TAU * float(i) / 6.0
			var a1: float = TAU * float(i + 1) / 6.0
			var d0 := Vector3(cos(a0), 0.0, sin(a0))
			var d1 := Vector3(cos(a1), 0.0, sin(a1))
			var b0 := d0 * tr0
			var b1 := d1 * tr0
			var t0 := d0 * tr1 + Vector3(0, yt, 0)
			var t1 := d1 * tr1 + Vector3(0, yt, 0)
			b0.y = -0.02
			b1.y = -0.02
			_v(st, b0, d0, ct)
			_v(st, b1, d1, ct)
			_v(st, t1, d1, ct * 0.8)
			_v(st, b0, d0, ct)
			_v(st, t1, d1, ct * 0.8)
			_v(st, t0, d0, ct * 0.8)
	var m: ArrayMesh = st.commit()
	m.surface_set_material(0, _mat)
	return m

func _v(st: SurfaceTool, p: Vector3, n: Vector3, c: Color) -> void:
	st.set_color(c)
	st.set_normal(n)
	st.add_vertex(p)

# ---------------------------------------------------------------- placement

static func _hash(i: int, j: int, s: int) -> int:
	var h: int = (i * 73856093) ^ (j * 19349663) ^ (s * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	h = (h * 668265263) ^ (h >> 15)
	return h & 0x7FFFFFFF

static func _u(h: int) -> float:
	return float(h & 0xFFFFFF) / 16777216.0

func grow(k: Vector2i, lod: int, h: PackedFloat32Array, e: PackedFloat32Array, ax: int,
		step: float, o: Vector3, span: float) -> Dictionary:
	## The chunk's trees. Kept with its old signature for StageChunks; the work is chunk_trees().
	return chunk_trees(k, o, span)

## Per-chunk tree lists, cached. A PURE function of the chunk key and the seed - the same trees
## whatever was built first - because the baked shadows (2026-11-18) need the trees of chunks that
## are not built yet: a spruce's shadow falls up to ~60 m from its trunk, across chunk borders.
## Until then the trees were read off the chunk's own sample arrays, which only the chunk itself has.
## Now every candidate asks StageArea.sample_at() for its exact ground height and edge distance.
## Most candidates are rejected first by the cheap hash and clearing tests, which need neither.
var _trees: Dictionary = {}             ## Vector2i -> Dictionary
var _trees_order: Array = []
const TREES_CACHE_MAX := 4096

func chunk_trees(k: Vector2i, o: Vector3, span: float) -> Dictionary:
	if _trees.has(k):
		return _trees[k]
	var xf: Array = []
	var tint: Array = []
	var trunks := PackedVector4Array()
	var occ := PackedFloat32Array()     # x, y, z, height, width per tree - for shadows and AO
	var i0: int = int(floor(o.x / spacing))
	var i1: int = int(floor((o.x + span) / spacing))
	var j0: int = int(floor(o.z / spacing))
	var j1: int = int(floor((o.z + span) / spacing))
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var hs: int = _hash(i, j, _seed)
			var px: float = (float(i) + _u(hs)) * spacing
			var pz: float = (float(j) + _u(hs >> 7 ^ hs * 31)) * spacing
			if px < o.x or px >= o.x + span or pz < o.z or pz >= o.z + span:
				continue                      # this cell's tree belongs to a neighbour
			var h2: int = _hash(i, j, _seed ^ 0x5bd1e995)
			# Density: thin at the clearance line and thickening into the wood, with clearings and
			# thickets from a low-frequency field so the treeline is not a uniform wall. The clearing
			# factor is tested FIRST: it needs no road search, and it rejects most candidates.
			var nv: float = _noise.get_noise_2d(px, pz)
			var dens_clear: float = smoothstep(-0.55, -0.15, nv)
			if _u(h2) >= dens_clear:
				continue
			var near_end := false
			for p in _ends:
				var pe: Vector3 = p
				if Vector2(pe.x - px, pe.z - pz).length_squared() < 70.0 * 70.0:
					near_end = true
			if near_end:
				continue
			var smp: Vector3 = area.sample_at(px, pz)
			var ed: float = smp.z
			if ed < clearance:
				continue
			var dens: float = smoothstep(clearance, clearance + edge_ramp, ed) * dens_clear
			if _u(h2) >= dens:
				continue
			# skip cliffs: no spruce stands on a slope steeper than ~40 degrees. Base terrain only:
			# trees stand beyond the clearance, where the road's cut has already blended out.
			var gx: float = (area.def.elevation_at(px + 1.0, pz) - area.def.elevation_at(px - 1.0, pz)) * 0.5
			var gz: float = (area.def.elevation_at(px, pz + 1.0) - area.def.elevation_at(px, pz - 1.0)) * 0.5
			if gx * gx + gz * gz > 0.7:
				continue
			var py: float = smp.x
			var h3: int = _hash(i, j, _seed ^ 0x27d4eb2f)
			var hgt: float = lerpf(min_h, max_h, pow(_u(h3), 0.8))
			# trees at the forest edge are younger: the clearing was cut, and they grew back
			hgt *= lerpf(0.7, 1.0, smoothstep(clearance, clearance + edge_ramp * 2.0, ed))
			var wid: float = hgt * lerpf(0.85, 1.2, _u(h3 >> 9))
			var yaw: float = _u(h2 >> 5) * TAU
			var lean := Vector3(_u(h3 >> 3) - 0.5, 0.0, _u(h3 >> 13) - 0.5) * 0.05
			var b := Basis(Vector3.UP, yaw)
			b = Basis(Vector3(lean.z, 0.0, -lean.x).normalized() if lean.length() > 1e-4 else Vector3.RIGHT,
					lean.length()) * b
			b = b * Basis.from_scale(Vector3(wid, hgt, wid))     # scale in the tree's own frame
			xf.append(Transform3D(b, Vector3(px, py, pz)))
			# tint: blue-green to yellow-green, a little brighter or darker per tree
			var hue: float = _u(h2 >> 11)
			var val: float = lerpf(0.78, 1.12, _u(h3 >> 17))
			tint.append(Color(lerpf(0.86, 1.10, hue) * val, val, lerpf(1.06, 0.84, hue) * val))
			trunks.append(Vector4(px, py, pz, maxf(hgt * 0.014, 0.18)))
			occ.append_array([px, py, pz, hgt, wid])
	var rec := {"xf": xf, "tint": tint, "trunks": trunks, "occ": occ}
	_trees[k] = rec
	_trees_order.append(k)
	while _trees_order.size() > TREES_CACHE_MAX:
		_trees.erase(_trees_order.pop_front())
	return rec

func instances(xf: Array, tint: Array, mesh: Mesh, shadows: bool, vis: PackedFloat32Array = PackedFloat32Array()) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var baked: bool = vis.size() == xf.size() and not vis.is_empty()
	mm.use_custom_data = baked
	mm.mesh = mesh
	mm.instance_count = xf.size()
	for n in range(xf.size()):
		mm.set_instance_transform(n, xf[n])
		mm.set_instance_color(n, tint[n])
		if baked:
			mm.set_instance_custom_data(n, Color(vis[n], 0.0, 0.0, 0.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	if baked:
		mmi.material_override = mat_baked
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi

func attach(mi: Node3D, g: Dictionary, lod: int) -> void:
	## Hang this chunk's trees off its ground mesh. A full-detail chunk carries both meshes and lets
	## the renderer swap them by camera distance (visibility ranges, measured to the chunk's centre);
	## a coarse chunk is only ever far away, so it carries the silhouettes alone.
	var xf: Array = g["xf"]
	if xf.is_empty():
		return
	if lod == 1:
		# The detailed trees cast NO shadow of their own: a twin set of silhouettes renders into the
		# shadow map only. A spruce's shadow on the road is its outline, which the 24-triangle
		# silhouette already has, so this costs a tenth of the shadow triangles for the same picture.
		# MEASURED (chase view, 300 m into SHAKEDOWN): see CHANGELOG 2026-11-17.
		var vis: PackedFloat32Array = g.get("vis", PackedFloat32Array())
		var near := instances(xf, g["tint"], mesh_near, false, vis)
		near.name = "TreesNear"
		near.visibility_range_end = detail_m
		near.visibility_range_end_margin = 10.0
		mi.add_child(near)
		var shadow := instances(xf, g["tint"], mesh_far, true)
		shadow.name = "TreesShadow"
		shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		shadow.visibility_range_end = detail_m
		shadow.visibility_range_end_margin = 10.0
		mi.add_child(shadow)
		var far := instances(xf, g["tint"], mesh_far, false, vis)
		far.name = "TreesFar"
		far.visibility_range_begin = detail_m
		far.visibility_range_begin_margin = 10.0
		mi.add_child(far)
	else:
		var far2 := instances(xf, g["tint"], mesh_far, false, g.get("vis", PackedFloat32Array()))
		far2.name = "TreesFar"
		mi.add_child(far2)

func trunk_body(trunks: PackedVector4Array) -> StaticBody3D:
	## One static body per chunk holding all its trunks, built complete BEFORE it enters the tree so
	## the physics engine assembles its shape once - adding trunks one at a time to the area's own
	## body would rebuild that body's compound shape per trunk.
	if not collide or trunks.is_empty():
		return null
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	for t in trunks:
		var col := CollisionShape3D.new()
		var cs := CylinderShape3D.new()
		cs.radius = t.w
		cs.height = 6.0
		col.shape = cs
		col.position = Vector3(t.x, t.y + 2.5, t.z)
		body.add_child(col)
	return body
