extends Control
## Bottom-right status cluster for the OUTSIDE views, where the in-cabin pod isn't readable:
## a rev arc, the gear, a big speed readout, and warning telltales.
##
## The telltales are the point of it. They watch the systems that are already modelled - M7's
## per-tyre temperature / wear / punctures and M8's chassis damage - and surface them as lights
## you can read at a glance instead of numbers you have to hunt for in the debug text. Amber is
## "look at this soon", red flashes because you need to know NOW (a puncture, a dying engine).
##
## Like the in-cabin cluster, the rev arc graduates itself off the CAR: full scale is the next
## whole 1000 past redline_rpm and the red zone starts at shift_light_frac.

var car

const PANEL := Vector2(292.0, 106.0)
const MARGIN := 16.0
const SWEEP_START := 210.0        # deg, arc zero (lower left)
const SWEEP := 240.0              # deg of travel, clockwise to lower right

const C_PANEL := Color(0.035, 0.05, 0.085, 0.74)
const C_EDGE := Color(0.35, 0.55, 0.70, 0.32)
const C_TRACK := Color(0.15, 0.21, 0.29, 0.95)   # unlit part of the rev arc
const C_FILL := Color(0.36, 0.86, 0.96)
const C_REDZONE := Color(0.45, 0.10, 0.09, 0.95)
const C_RED := Color(0.96, 0.20, 0.15)
const C_AMBER := Color(1.0, 0.72, 0.13)
const C_OFF := Color(0.15, 0.16, 0.19)
const C_TEXT := Color(0.94, 0.97, 1.0)
const C_DIM := Color(0.50, 0.60, 0.70)

var _t := 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(delta: float) -> void:
	_t += delta
	queue_redraw()

func _pt(c: Vector2, r: float, deg: float) -> Vector2:
	# gauge convention: 0 = right, 90 = up. Screen Y grows downward, hence the negated sine.
	var a := deg_to_rad(deg)
	return c + Vector2(cos(a), -sin(a)) * r

func _arc(c: Vector2, r: float, from_deg: float, to_deg: float, col: Color, width: float) -> void:
	if absf(to_deg - from_deg) < 0.5:
		return
	var pts := PackedVector2Array()
	var steps := maxi(int(absf(to_deg - from_deg) / 4.0), 2)
	for i in range(steps + 1):
		pts.append(_pt(c, r, lerpf(from_deg, to_deg, float(i) / float(steps))))
	draw_polyline(pts, col, width, true)

func _lamp(pos: Vector2, size: Vector2, label: String, state: int, font: Font) -> void:
	# state: 0 = dark, 1 = amber warning, 2 = red critical (flashes so it can't be ignored)
	var lit := state
	if state >= 2 and fmod(_t, 0.66) > 0.36:
		lit = 0                                    # blink phase
	var body := C_OFF
	var text := C_DIM.darkened(0.35)
	if lit == 1:
		body = C_AMBER
		text = Color(0.15, 0.10, 0.0)
	elif lit >= 2:
		body = C_RED
		text = Color(1, 1, 1)
	if lit > 0:
		# a soft halo so a lit lamp reads in peripheral vision
		draw_rect(Rect2(pos - Vector2(2, 2), size + Vector2(4, 4)), Color(body.r, body.g, body.b, 0.22))
	draw_rect(Rect2(pos, size), body)
	draw_rect(Rect2(pos, size), Color(0, 0, 0, 0.45), false, 1.0)
	var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
	draw_string(font, pos + Vector2((size.x - w) * 0.5, size.y * 0.5 + 3.5), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 9, text)

func _draw() -> void:
	if car == null or not car.has_method("get_engine"):
		return
	var wheels: Array = car.get_wheels()
	if wheels.size() < 4:
		return
	var eng: Dictionary = car.get_engine()
	var font := ThemeDB.fallback_font
	var vs := get_viewport_rect().size
	var org := Vector2(vs.x - PANEL.x - MARGIN, vs.y - PANEL.y - MARGIN)

	draw_rect(Rect2(org, PANEL), C_PANEL)
	draw_rect(Rect2(org, PANEL), C_EDGE, false, 1.0)

	# --- rev arc, scaled off the car exactly like the in-cabin cluster ---
	var redline: float = car.redline_rpm
	var rpm_max: float = ceil(redline / 1000.0) * 1000.0
	var red_from: float = redline * float(car.shift_light_frac) / maxf(rpm_max, 1.0)
	var rpm: float = float(eng.get("rpm", 0.0))
	var frac := clampf(rpm / maxf(rpm_max, 1.0), 0.0, 1.0)
	var c := org + Vector2(60.0, 70.0)
	var r := 42.0
	var a_end := SWEEP_START - SWEEP
	_arc(c, r, SWEEP_START, a_end, C_TRACK, 7.0)
	_arc(c, r, SWEEP_START - SWEEP * red_from, a_end, C_REDZONE, 7.0)
	if frac > 0.001:
		var fill := C_FILL if frac < red_from else C_RED
		_arc(c, r, SWEEP_START, SWEEP_START - SWEEP * frac, fill, 7.0)

	# gear in the middle of the arc, rpm underneath it
	var g := int(eng.get("gear", 0))
	var gtxt := "N" if g == 0 else ("R" if g == -1 else str(g))
	var gw := font.get_string_size(gtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 30).x
	draw_string(font, c + Vector2(-gw * 0.5, 6.0), gtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 30,
		C_RED if frac >= red_from else C_TEXT)
	var rtxt := "%d" % int(round(rpm))
	var rw := font.get_string_size(rtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
	draw_string(font, c + Vector2(-rw * 0.5, 21.0), rtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, C_DIM)

	# --- speed ---
	var kmh: float = float(eng.get("speed_kmh", 0.0))
	var stxt := "%d" % int(round(maxf(kmh, 0.0)))
	var sw := font.get_string_size(stxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 44).x
	var sx := org.x + PANEL.x - 16.0
	draw_string(font, Vector2(sx - sw, org.y + 50.0), stxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 44, C_TEXT)
	var uw := font.get_string_size("km/h", HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	draw_string(font, Vector2(sx - uw, org.y + 64.0), "km/h", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C_DIM)

	# --- telltales: read the systems that are already modelled (M7 tyres, M8 damage) ---
	var punctured := false
	var worn := 0.0
	var tyre_hot := 0.0
	for w in wheels:
		if w.punctured:
			punctured = true
		worn = maxf(worn, w.tyre_wear)
		tyre_hot = maxf(tyre_hot, w.temp)
	var dmg: float = float(eng.get("damage", 0.0))
	var etemp: float = float(eng.get("temp", 20.0))
	var eopt: float = car.engine_optimal_temp
	var topt: float = car.optimal_temp
	var twin: float = car.temp_grip_window

	# CHECK ENGINE: running hot, or damaged enough to be costing real power
	var s_eng := 0
	if etemp > eopt + 25.0 or dmg > 0.35 or bool(eng.get("stalled", false)):
		s_eng = 2
	elif etemp > eopt + 8.0 or dmg > 0.05:
		s_eng = 1
	# TYRES: a puncture is an emergency; wear and heat are advisories
	var s_tyre := 0
	if punctured:
		s_tyre = 2
	elif worn > 0.75 or tyre_hot > topt + twin * 0.6:
		s_tyre = 1
	# CHASSIS damage (power / grip / steering pull all scale off this)
	var s_dmg := 0
	if dmg > 0.35:
		s_dmg = 2
	elif dmg > 0.05:
		s_dmg = 1

	var lw := 52.0
	var lh := 15.0
	var ly := org.y + PANEL.y - lh - 9.0
	var lx := org.x + PANEL.x - 16.0 - (lw * 3.0 + 12.0)
	_lamp(Vector2(lx, ly), Vector2(lw, lh), "ENGINE", s_eng, font)
	_lamp(Vector2(lx + lw + 6.0, ly), Vector2(lw, lh), "TYRE", s_tyre, font)
	_lamp(Vector2(lx + (lw + 6.0) * 2.0, ly), Vector2(lw, lh), "DAMAGE", s_dmg, font)
