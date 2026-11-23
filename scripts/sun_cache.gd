extends Node
## BAKED SHADOWS THAT LOOK LIKE THE LIVE ONES (2026-11-23).
##
## sagi, on the per-vertex bake: "when having an extreme angle ... the shadows start to stretch into
## a Christmas tree shape where every cell stretches horizontally to its length. they usually don't
## seem to match the cast on shadow in shape and boundaries at all". Two causes, both structural:
## the bake stored shade only at the ground's grid points (one per 1.4 m, blended across triangles),
## so a long thin low-sun shadow became stacked grid bars; and it modelled each tree as a smooth cone
## with an invented soft edge, not the mesh the live shadow is drawn from.
##
## So near the car the baked mode now uses a REAL SHADOW MAP - the same kind the live mode uses,
## drawn from the same 24-triangle tree silhouettes - but drawn ONCE and kept, not every frame:
## an orthographic camera along the sun renders the trees' depth into its own small world, and the
## ground shader compares against it. It is redrawn only when the car has moved on a fraction of the
## region, when new trees have streamed in (at most every REDRAW_MIN_S), or when the sun changes.
## Beyond the region the per-vertex bake still applies, blended in at the region's edge.
##
## The live shadow map costs ~2.6 ms EVERY frame (bench, 2026-11-18); this costs one similar render
## every second or so, and a few texture reads per ground pixel.

const RES := 2048                       ## texels per side: 0.16 m each over REGION_M
const REGION_M := 320.0                 ## metres per side, centred just ahead of the car
const DEPTH_M := 900.0                  ## how deep the sun camera sees (encoded range)
const MOVE_FRAC := 0.125                ## redraw when the car is this fraction of REGION_M off centre
const REDRAW_MIN_S := 0.5               ## and for newly streamed trees, at most this often

const CASTER_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform float sc_depth = 900.0;
void fragment() {
	// Distance from the camera plane along the sun, 0..1, split into a coarse and a fine channel so
	// the 16-bit float target keeps millimetres rather than ~0.5 m.
	float d = clamp(-VERTEX.z / sc_depth, 0.0, 1.0) * 256.0;
	ALBEDO = vec3(floor(d) / 256.0, fract(d), 0.0);
}
"""

## The ground's side of it: inserted into the baked ground shader ahead of light().
const GROUND_GLSL := """
uniform sampler2D sc_tex : filter_nearest, repeat_disable;
uniform float sc_on = 0.0;
uniform vec3 sc_cam;
uniform vec3 sc_right;
uniform vec3 sc_up;
uniform vec3 sc_fwd;
uniform float sc_size = 320.0;
uniform float sc_depth = 900.0;
uniform float sc_res = 2048.0;
float sc_stored(ivec2 t) {
	vec4 c = texelFetch(sc_tex, clamp(t, ivec2(0), ivec2(int(sc_res) - 1)), 0);
	return c.r + c.g / 256.0;
}
// Fraction of the sun this world point sees, and how much the cache covers it (0 at its edge).
vec2 sc_vis(vec3 p, float slope_bias) {
	vec3 r = p - sc_cam;
	vec2 uv = vec2(dot(r, sc_right) / sc_size + 0.5, 0.5 - dot(r, sc_up) / sc_size);
	float edge = max(abs(uv.x - 0.5), abs(uv.y - 0.5));
	float cover = 1.0 - smoothstep(0.40, 0.48, edge);
	if (sc_on < 0.5 || cover <= 0.0) {
		return vec2(1.0, 0.0);
	}
	float d = dot(r, sc_fwd) / sc_depth - (0.12 + slope_bias) / sc_depth;
	// 2x2 percentage-closer filter, bilinearly weighted: the same soft-but-exact edge a shadow map has
	vec2 f = uv * sc_res - 0.5;
	ivec2 b = ivec2(floor(f));
	vec2 w = fract(f);
	float s00 = step(d, sc_stored(b));
	float s10 = step(d, sc_stored(b + ivec2(1, 0)));
	float s01 = step(d, sc_stored(b + ivec2(0, 1)));
	float s11 = step(d, sc_stored(b + ivec2(1, 1)));
	float v = mix(mix(s00, s10, w.x), mix(s01, s11, w.x), w.y);
	return vec2(v, cover);
}
"""

var chunks                              ## StageChunks (untyped: no class_name dependency)
var material: ShaderMaterial            ## the baked ground material to feed
var forest_material: ShaderMaterial     ## the baked tree material (optional)
var enabled := false

var _vp: SubViewport
var _cam: Camera3D
var _caster_mat: ShaderMaterial
var _nodes := {}                        ## chunk key -> MultiMeshInstance3D in the cache's world
var _sun := Vector3.UP
var _centre := Vector3.ZERO
var _have_centre := false
var _dirty := true
var _since := 0.0
var redraws := 0

func _ready() -> void:
	_vp = SubViewport.new()
	_vp.name = "SunCacheViewport"
	_vp.own_world_3d = true
	_vp.size = Vector2i(RES, RES)
	_vp.use_hdr_2d = true
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_vp.positional_shadow_atlas_size = 0
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	add_child(_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1.0, 1.0, 1.0)     # "nothing toward the sun": decodes beyond any depth
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = REGION_M
	_cam.near = 0.05
	_cam.far = DEPTH_M
	_cam.keep_aspect = Camera3D.KEEP_HEIGHT
	_cam.current = true
	_vp.add_child(_cam)
	var sh := Shader.new()
	sh.code = CASTER_SHADER
	_caster_mat = ShaderMaterial.new()
	_caster_mat.shader = sh
	_caster_mat.set_shader_parameter("sc_depth", DEPTH_M)
	if material != null:
		material.set_shader_parameter("sc_tex", _vp.get_texture())
		material.set_shader_parameter("sc_size", REGION_M)
		material.set_shader_parameter("sc_depth", DEPTH_M)
		material.set_shader_parameter("sc_res", float(RES))

func add(k: Vector2i, chunk_mi: Node3D) -> void:
	## Mirror a chunk's tree silhouettes into the cache's world. The MultiMesh RESOURCE is shared
	## with the chunk's own (shadow) instance, so this costs a node, not a copy of the trees.
	remove(k)
	var src: MultiMeshInstance3D = null
	for name in ["TreesShadow", "TreesFar"]:
		var n := chunk_mi.get_node_or_null(name) as MultiMeshInstance3D
		if n != null:
			src = n
			break
	if src == null or src.multimesh == null:
		return
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = src.multimesh
	mmi.material_override = _caster_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.transform = chunk_mi.global_transform * src.transform
	_vp.add_child(mmi)
	_nodes[k] = mmi
	_dirty = true

func remove(k: Vector2i) -> void:
	if _nodes.has(k):
		var n: Node = _nodes[k]
		if is_instance_valid(n):
			n.queue_free()
		_nodes.erase(k)
		_dirty = true

func set_sun(toward_sun: Vector3) -> void:
	var d := toward_sun.normalized()
	if d.distance_to(_sun) > 1e-4:
		_sun = d
		_have_centre = false              # force a redraw from scratch

func set_enabled(on: bool) -> void:
	enabled = on
	_have_centre = false
	if material != null:
		material.set_shader_parameter("sc_on", 0.0)
	if forest_material != null:
		forest_material.set_shader_parameter("sc_on", 0.0)

func update(p: Vector3, vel: Vector3, delta: float) -> void:
	if not enabled or material == null:
		return
	_since += delta
	# Centre a little AHEAD of the car: the ground it is about to see matters more than behind.
	var want: Vector3 = p + Vector3(vel.x, 0.0, vel.z) * 1.5
	var off: float = Vector2(want.x - _centre.x, want.z - _centre.z).length()
	var move: bool = not _have_centre or off > REGION_M * MOVE_FRAC
	if not move and not (_dirty and _since >= REDRAW_MIN_S):
		return
	_redraw(want if move else _centre)

func _redraw(c: Vector3) -> void:
	_centre = c
	_have_centre = true
	_dirty = false
	_since = 0.0
	redraws += 1
	var L := _sun
	if L.y < 0.05:
		L = Vector3(L.x, 0.05, L.z).normalized()
	# Snap the centre to whole texels in the camera's own plane, so a redraw never shifts the
	# texel grid under a shadow edge (the edges would crawl as the car drives - "shimmer").
	var up_ref := Vector3.UP if absf(L.y) < 0.99 else Vector3(0, 0, 1)
	var fwd := -L
	var right := fwd.cross(up_ref).normalized()
	var up := right.cross(fwd).normalized()
	var texel: float = REGION_M / float(RES)
	var cx: float = round(c.dot(right) / texel) * texel
	var cy: float = round(c.dot(up) / texel) * texel
	var cz: float = c.dot(fwd)
	var centre: Vector3 = right * cx + up * cy + fwd * cz
	var cam_pos: Vector3 = centre - fwd * (DEPTH_M * 0.5)
	_cam.global_transform = Transform3D(Basis(right, up, -fwd), cam_pos)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	for m in [material, forest_material]:
		if m == null:
			continue
		m.set_shader_parameter("sc_on", 1.0)
		m.set_shader_parameter("sc_cam", cam_pos)
		m.set_shader_parameter("sc_right", right)
		m.set_shader_parameter("sc_up", up)
		m.set_shader_parameter("sc_fwd", fwd)
