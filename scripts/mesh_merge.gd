extends RefCounted
## Bakes a set of STATIC MeshInstance3D parts into one mesh with one surface per material.
##
## WHY THIS EXISTS (measured 2026-11-17, legacy map, chase view, lavapipe - draw counts are exact):
## the car is drawn from ~140 separate box, cylinder and torus nodes, and every node is its own draw
## call in every pass it appears in (depth pre-pass, colour, each shadow cascade). Hiding the car
## removed 569 of the frame's 870 draw calls while removing only 46,664 of its 1.3 M triangles -
## the car was two thirds of the frame's draw calls and 4% of its geometry. A draw call costs the
## render thread a fixed amount whatever it draws, so the cure is fewer, larger draws of the SAME
## triangles: one surface per material instead of one node per box.
##
## WHAT STAYS THE SAME: every triangle, every normal, every UV, and the very Material OBJECTS - a
## merged surface carries the material its parts were given, so code that recolours a material
## (the livery per drive mode, the brake lights) still reaches it. The part's transform relative to
## `root` is baked into its vertices, which is the same multiplication the GPU did per vertex.
##
## WHAT IT MUST NOT BE GIVEN: anything that moves relative to `root` (wheels, needles, the steering
## wheel - merge those under their OWN moving node instead), and anything transparent - separate
## transparent nodes are sorted back to front against each other each frame, and one merged surface
## cannot be.
##
## Used through `preload`, deliberately without a `class_name`: this project never opens the editor,
## and a new global class is not resolvable until the class cache is rebuilt (see CLAUDE.md).

## Returns the node holding the merged mesh (already added under `root`), or null when `parts` holds
## nothing usable. The originals are removed and freed.
## `shadow_proxy`: when the parts cast shadows, put all of their triangles into ONE extra
## single-surface mesh that only casts shadows, and stop the visible one casting. A shadow pass
## ignores materials, so it then costs one draw per cascade instead of one per material.
static func merge(root: Node3D, parts: Array, node_name: String, shadow_proxy := false) -> MeshInstance3D:
	var groups: Array = []            # first-seen order, so the surface order is the build order
	var by_mat := {}                  # material instance id -> index into groups
	var cast := GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var seen := false
	var sh_v := PackedVector3Array()
	var sh_i := PackedInt32Array()
	for part in parts:
		var mi := part as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var xf := _relative(root, mi)
		# normals turn with the inverse transpose, which is the rotation itself when there is no
		# scale - written out in full so a scaled part would still be lit correctly
		var nb := xf.basis.inverse().transposed()
		if not seen:
			cast = mi.cast_shadow
			seen = true
		for si in range(mi.mesh.get_surface_count()):
			var mat: Material = mi.material_override
			if mat == null:
				mat = mi.get_active_material(si)
			var key: int = mat.get_instance_id() if mat != null else 0
			if not by_mat.has(key):
				by_mat[key] = groups.size()
				groups.append({"mat": mat, "v": PackedVector3Array(), "n": PackedVector3Array(),
					"uv": PackedVector2Array(), "i": PackedInt32Array()})
			var g: Dictionary = groups[by_mat[key]]
			var arr: Array = mi.mesh.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var n = arr[Mesh.ARRAY_NORMAL]
			var uv = arr[Mesh.ARRAY_TEX_UV]
			var idx = arr[Mesh.ARRAY_INDEX]
			var gv: PackedVector3Array = g["v"]
			var gn: PackedVector3Array = g["n"]
			var guv: PackedVector2Array = g["uv"]
			var gi: PackedInt32Array = g["i"]
			var base := gv.size()
			var sbase := sh_v.size()
			for k in range(v.size()):
				var p: Vector3 = xf * v[k]
				gv.append(p)
				sh_v.append(p)
				gn.append((nb * (n[k] as Vector3)).normalized() if n != null else Vector3.UP)
				guv.append(uv[k] if uv != null else Vector2.ZERO)
			if idx != null:
				for k in range((idx as PackedInt32Array).size()):
					gi.append(base + int(idx[k]))
					sh_i.append(sbase + int(idx[k]))
			else:
				for k in range(v.size()):
					gi.append(base + k)
					sh_i.append(sbase + k)
			g["v"] = gv
			g["n"] = gn
			g["uv"] = guv
			g["i"] = gi
	if groups.is_empty():
		return null
	var mesh := ArrayMesh.new()
	for g in groups:
		var a: Array = []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = g["v"]
		a[Mesh.ARRAY_NORMAL] = g["n"]
		a[Mesh.ARRAY_TEX_UV] = g["uv"]
		a[Mesh.ARRAY_INDEX] = g["i"]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		if g["mat"] != null:
			mesh.surface_set_material(mesh.get_surface_count() - 1, g["mat"])
	var out := MeshInstance3D.new()
	out.name = node_name
	out.mesh = mesh
	out.cast_shadow = cast
	for part in parts:
		var nd := part as Node
		if nd == null:
			continue
		if nd.get_parent() != null:
			nd.get_parent().remove_child(nd)
		nd.free()
	root.add_child(out)
	if shadow_proxy and cast == GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
		out.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var sa: Array = []
		sa.resize(Mesh.ARRAY_MAX)
		sa[Mesh.ARRAY_VERTEX] = sh_v
		sa[Mesh.ARRAY_INDEX] = sh_i
		var smesh := ArrayMesh.new()
		smesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sa)
		var shadow := MeshInstance3D.new()
		shadow.name = node_name + "Shadow"
		shadow.mesh = smesh
		shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		root.add_child(shadow)
	return out

## `node`'s transform expressed in `root`'s space, from the local transforms alone - so it works
## before either is inside the scene tree, which is when a body is being built.
static func _relative(root: Node3D, node: Node3D) -> Transform3D:
	var xf := node.transform
	var p := node.get_parent()
	while p != null and p != root:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf
