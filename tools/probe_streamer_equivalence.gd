extends SceneTree
# TEMPORARY - is the work-list streamer the SAME streamer as the per-tick scan it replaced?
# Copy to the project root as _probe_tmp.gd, run
#   godot --headless --path . --script res://_probe_tmp.gd
# read the PROBE lines, delete the copy. It must print 0 differences. Delete this file together
# with scripts/probe_framelog.gd when D4s hiccup item closes (docs/PLAN-stages-ground-map.md §9).
class Frozen extends StageChunks:
	var frozen := false
	func _derive() -> void:      # the measured-cost feedback would let timing noise move the radii
		if not frozen:
			super._derive()

var w: Node
var n := 0

func ref_update(ch, p: Vector3) -> void:
	# The update() that shipped until 2026-11-16, fed the lattice-cell centre.
	if ch._have_prev and p.distance_to(ch._prev_p) > ch.r_solid:
		ch._job = {}
		ch.prime(p)
		ch._prev_p = p
		return
	ch._prev_p = p
	ch._have_prev = true
	if not ch._job.is_empty():
		ch._step_job()
		return
	var pq: Vector3 = ch._cell_centre(ch._cell_of(p))
	ch._pq = pq
	var r := int(ceil(ch.r_view / ch.span)) + 1
	var c: Vector2i = ch.key_at(pq.x, pq.z)
	var drop: Array = []
	for k in ch._live:
		var dk: float = ch._dist_to_chunk(k, pq)
		if dk > ch.r_view + ch.span:
			drop.append(k)
		elif dk > ch.r_detail + ch.span and not ch._near_corridor(k):
			drop.append(k)
	var freed := 0
	for k in drop:
		if freed >= 2:
			break
		ch._unload(k)
		freed += 1
	var rc := int(ceil((ch.r_solid + ch.span) / ch.span)) + 1
	for dz in range(-rc, rc + 1):
		for dx in range(-rc, rc + 1):
			var kk := Vector2i(c.x + dx, c.y + dz)
			if ch._live.has(kk):
				ch._sync_collider(kk)
	var best_k := Vector2i.ZERO
	var best_d := INF
	var best_lod := 0
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var k := Vector2i(c.x + dx, c.y + dz)
			if not ch._in_area(k):
				continue
			var d: float = ch._dist_to_chunk(k, pq)
			var have: int = int(ch._live[k]["lod"]) if ch._live.has(k) else 0
			var want_lod: int = ch._want_lod(k, d, have)
			if want_lod == 0:
				continue
			if have == want_lod:
				continue
			var pri: float = d if have == 0 else d + ch.r_view
			if pri < best_d:
				best_d = pri
				best_k = k
				best_lod = want_lod
	if best_lod > 0:
		if ch._restore(best_k, best_lod):
			return
		ch._start_job(best_k, best_lod)
		ch._step_job()

func differ(a, b) -> String:
	if a._live.size() != b._live.size():
		return "resident count %d vs %d" % [a._live.size(), b._live.size()]
	for k in a._live:
		if not b._live.has(k):
			return "resident key %s" % str(k)
		if int(a._live[k]["lod"]) != int(b._live[k]["lod"]):
			return "lod at %s" % str(k)
		if (a._live[k]["col"] != null) != (b._live[k]["col"] != null):
			return "collider at %s" % str(k)
	if a._cache_order != b._cache_order:
		return "cache order"
	if a._built != b._built or a._cache_hits != b._cache_hits:
		return "counters built %d/%d hits %d/%d" % [a._built, b._built, a._cache_hits, b._cache_hits]
	return ""

func make(area, car) -> Frozen:
	var ch := Frozen.new()
	ch.area = area
	ch.car = car
	area.add_child(ch)
	ch.configure()
	ch.frozen = true
	ch.build_budget_ms = 1e9          # one whole decision per call: the comparison is call-for-call
	return ch

func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)

func _physics_process(_d: float) -> bool:
	n += 1
	if n < 30:
		return false
	var area = w._stage_area
	area.set_physics_process(false)
	var cl = area.gen.centreline
	var a := make(area, w._car)
	var b := make(area, w._car)
	print("PROBE radii solid %.1f detail %.1f view %.1f | A==B radii: %s" % [a.r_solid, a.r_detail, a.r_view, str(a.r_solid == b.r_solid and a.r_view == b.r_view and a.band_w == b.band_w)])
	# ---- the path: (calls, speed m/s at start, speed at end, lateral offset peak m, direction)
	var legs := [
		["parked on the start line", 700, 0.0, 0.0, 0.0, 1.0],
		["pulling away 0-40 m/s", 600, 0.0, 40.0, 0.0, 1.0],
		["cruising 40 m/s", 1000, 40.0, 40.0, 0.0, 1.0],
		["off the road, 100 m out and back", 700, 15.0, 15.0, 100.0, 1.0],
		["stopped", 300, 0.0, 0.0, 0.0, 1.0],
		["turned round, 25 m/s back up the road", 1000, 25.0, 25.0, 0.0, -1.0],
		["flat out 66 m/s", 600, 66.0, 66.0, 0.0, 1.0],
	]
	var s: float = clampf(area.gen.timed_start_s - 45.0, 0.0, cl.length())
	var calls := 0
	var bad := 0
	var first_bad := ""
	var t_a := 0
	var t_b := 0
	for leg in legs:
		var name: String = leg[0]
		var cnt: int = leg[1]
		var scans0: int = a._scans
		var bad0 := bad
		for i in cnt:
			var f := float(i) / float(maxi(cnt - 1, 1))
			var v: float = lerpf(float(leg[2]), float(leg[3]), f)
			s = clampf(s + float(leg[5]) * v / 120.0, 0.0, cl.length())
			var pt: Dictionary = cl.point_at(s)
			var pos: Vector3 = pt["pos"]
			var h: Vector2 = pt["heading"]
			var off: float = float(leg[4]) * sin(PI * f)
			var p := Vector3(pos.x - h.y * off, 0.0, pos.z + h.x * off)
			var t := Time.get_ticks_usec()
			a.update(p)
			t_a += Time.get_ticks_usec() - t
			t = Time.get_ticks_usec()
			ref_update(b, p)
			t_b += Time.get_ticks_usec() - t
			calls += 1
			var why := differ(a, b)
			if why != "":
				bad += 1
				if first_bad == "":
					first_bad = "call %d (%s): %s" % [calls, name, why]
		print("PROBE leg %-40s %5d calls | scans: new %4d, per-tick %5d | differences %d | resident %d" % [name, cnt, a._scans - scans0, cnt, bad - bad0, a._live.size()])
	# ---- a teleport in the middle of the stage, then parked
	var s2: float = clampf(s + 2000.0, 0.0, cl.length()) if s + 2000.0 < cl.length() else maxf(s - 2000.0, 0.0)
	var pt2: Dictionary = cl.point_at(s2)
	var p2: Vector3 = pt2["pos"]
	p2.y = 0.0
	var scans1: int = a._scans
	var bad1 := bad
	for i in 600:
		a.update(p2)
		ref_update(b, p2)
		calls += 1
		var why2 := differ(a, b)
		if why2 != "":
			bad += 1
			if first_bad == "":
				first_bad = "call %d (teleport): %s" % [calls, why2]
	print("PROBE leg %-40s %5d calls | scans: new %4d, per-tick %5d | differences %d | resident %d" % ["teleported 2 km, then parked", 600, a._scans - scans1, 600, bad - bad1, a._live.size()])
	print("PROBE TOTAL %d calls, %d built, %d restored from cache: %d differences%s" % [calls, a._built, a._cache_hits, bad, "" if bad == 0 else " - FIRST: " + first_bad])
	print("PROBE scans %d (new) vs %d (per-tick) | wall time new %.1f s vs per-tick %.1f s" % [a._scans, calls, float(t_a) / 1e6, float(t_b) / 1e6])
	quit()
	return true
