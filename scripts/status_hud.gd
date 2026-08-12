extends Control
## Bottom-right instrument for the OUTSIDE views, where the in-cabin pod isn't readable:
## a round speedometer with a digital repeat, the gear, a rev ring around the rim, and real
## car-style warning telltales.
##
## The telltales are the point of it. They watch systems that are already modelled - M7's
## per-tyre temperature / wear / punctures, the engine's coolant temperature, and M8's chassis
## damage - and surface them as the symbols you'd actually see lit on a dashboard, instead of
## numbers buried in the debug text. Amber means look at this soon; red FLASHES because you need
## to know now (a puncture, an overheating engine).
##
## Both scales graduate themselves off the CAR: the speedo runs to the car's theoretical top
## speed (redline through the tallest gear) and the rev ring reddens at shift_light_frac, so
## changing a gear ratio or the redline on the Tab panel rescales the face.

var car

const PANEL := Vector2(208.0, 208.0)
const MARGIN := 14.0
const R := 80.0                   # dial radius (tick tips)
const SWEEP_START := 212.0        # deg, zero at lower left
const SWEEP := 244.0              # deg of travel, clockwise to lower right

const C_PANEL := Color(0.10, 0.10, 0.11, 0.90)
const C_FACE := Color(0.16, 0.16, 0.17)
const C_RIM := Color(0.07, 0.07, 0.08)
const C_TICK := Color(0.93, 0.94, 0.96)
const C_TICK_MINOR := Color(0.62, 0.63, 0.66)
const C_DANGER := Color(0.86, 0.14, 0.12)
const C_NEEDLE := Color(0.90, 0.13, 0.11)
const C_TEXT := Color(0.88, 0.89, 0.91)
const C_DIM := Color(0.55, 0.56, 0.60)
const C_LAMP_OFF := Color(0.30, 0.31, 0.33)
const C_AMBER := Color(1.0, 0.68, 0.10)
const C_RED := Color(0.95, 0.19, 0.15)
const C_REV := Color(0.36, 0.86, 0.96)

var _t := 0.0
var _odo := 0.0                   # metres travelled, for the odometer strip
var _kmh_shown := 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(delta: float) -> void:
	_t += delta
	if car != null and car.has_method("get_engine"):
		var kmh: float = float(car.get_engine().get("speed_kmh", 0.0))
		_odo += kmh / 3.6 * delta
		_kmh_shown += (kmh - _kmh_shown) * clampf(delta / 0.06, 0.0, 1.0)   # needle has mass
	queue_redraw()

func _pt(c: Vector2, r: float, deg: float) -> Vector2:
	# gauge convention: 0 = right, 90 = up. Screen Y grows downward, hence the negated sine.
	var a := deg_to_rad(deg)
	return c + Vector2(cos(a), -sin(a)) * r

func _arc(c: Vector2, r: float, from_deg: float, to_deg: float, col: Color, width: float) -> void:
	if absf(to_deg - from_deg) < 0.5:
		return
	var pts := PackedVector2Array()
	var steps := maxi(int(absf(to_deg - from_deg) / 3.0), 2)
	for i in range(steps + 1):
		pts.append(_pt(c, r, lerpf(from_deg, to_deg, float(i) / float(steps))))
	draw_polyline(pts, col, width, true)

# --- real-car telltale symbols, drawn from primitives so they scale cleanly ---

func _icon_coolant(c: Vector2, s: float, col: Color) -> void:
	# thermometer standing in liquid: the coolant-temperature warning
	draw_rect(Rect2(c.x - s * 0.11, c.y - s * 0.62, s * 0.22, s * 0.72), col)
	draw_circle(c + Vector2(0.0, s * 0.22), s * 0.26, col)
	for k in [-1.0, 1.0]:
		var pts := PackedVector2Array()
		for i in range(7):
			var f := float(i) / 6.0
			pts.append(Vector2(c.x + k * (s * 0.30 + s * 0.42 * f), c.y + s * 0.42 + sin(f * TAU) * s * 0.10))
		draw_polyline(pts, col, 1.6, true)

func _icon_engine(c: Vector2, s: float, col: Color) -> void:
	# engine block silhouette: the check-engine lamp
	draw_rect(Rect2(c.x - s * 0.46, c.y - s * 0.22, s * 0.86, s * 0.60), col)
	draw_rect(Rect2(c.x - s * 0.22, c.y - s * 0.50, s * 0.42, s * 0.30), col)
	draw_rect(Rect2(c.x - s * 0.62, c.y - s * 0.44, s * 0.18, s * 0.22), col)
	draw_rect(Rect2(c.x + s * 0.40, c.y - s * 0.06, s * 0.26, s * 0.24), col)
	draw_rect(Rect2(c.x - s * 0.66, c.y + s * 0.02, s * 0.20, s * 0.20), col)

func _icon_tyre(c: Vector2, s: float, col: Color) -> void:
	# tyre cross-section with an exclamation: the TPMS / tyre-pressure lamp
	var pts := PackedVector2Array()
	for i in range(13):
		var a := lerpf(180.0, 0.0, float(i) / 12.0)
		pts.append(c + Vector2(cos(deg_to_rad(a)) * s * 0.56, -sin(deg_to_rad(a)) * s * 0.52))
	draw_polyline(pts, col, 2.0, true)
	draw_line(c + Vector2(-s * 0.56, 0.0), c + Vector2(-s * 0.56, s * 0.40), col, 2.0)
	draw_line(c + Vector2(s * 0.56, 0.0), c + Vector2(s * 0.56, s * 0.40), col, 2.0)
	draw_line(c + Vector2(-s * 0.62, s * 0.40), c + Vector2(s * 0.62, s * 0.40), col, 2.0)
	for k in range(5):
		var x := c.x - s * 0.50 + s * 1.0 * float(k) / 4.0
		draw_line(Vector2(x, c.y + s * 0.40), Vector2(x, c.y + s * 0.58), col, 1.5)
	draw_line(c + Vector2(0.0, -s * 0.30), c + Vector2(0.0, s * 0.06), col, 2.0)
	draw_circle(c + Vector2(0.0, s * 0.22), 1.5, col)

func _icon_warn(c: Vector2, s: float, col: Color) -> void:
	# the general warning triangle: chassis damage
	draw_polyline(PackedVector2Array([
		c + Vector2(0.0, -s * 0.58), c + Vector2(s * 0.60, s * 0.42),
		c + Vector2(-s * 0.60, s * 0.42), c + Vector2(0.0, -s * 0.58)]), col, 2.0, true)
	draw_line(c + Vector2(0.0, -s * 0.20), c + Vector2(0.0, s * 0.10), col, 2.0)
	draw_circle(c + Vector2(0.0, s * 0.26), 1.5, col)

func _lamp_col(state: int) -> Color:
	# state: 0 dark, 1 amber, 2 red (flashes, so it cannot be ignored)
	if state >= 2:
		return C_RED if fmod(_t, 0.66) < 0.36 else C_LAMP_OFF.darkened(0.3)
	if state == 1:
		return C_AMBER
	return C_LAMP_OFF

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
	var c := org + PANEL * 0.5

	draw_rect(Rect2(org, PANEL), C_PANEL)
	draw_circle(c, R + 18.0, C_RIM)
	draw_circle(c, R + 6.0, C_FACE)

	# --- speedometer face, scaled to the car's theoretical top speed ---
	var ratios: Array = car.gear_ratios
	var top_ratio: float = float(ratios[ratios.size() - 1]) * float(car.final_drive)
	var v_max: float = (float(car.redline_rpm) * TAU / 60.0) / maxf(top_ratio, 0.01) * float(car.wheel_radius) * 3.6
	var kmh_max: float = maxf(ceil(v_max / 20.0) * 20.0, 40.0)
	# label every 40 km/h with a minor tick between: a 280 scale labelled every 20 puts fifteen
	# numerals on an 80 px dial, which is unreadable at a glance - and glanceable is the point
	var majors := maxi(int(kmh_max / 40.0), 1)
	var danger := 0.88                                  # top of the scale reads red, as on a real face
	for i in range(majors * 2 + 1):
		var f := float(i) / float(majors * 2)
		var a := SWEEP_START - SWEEP * f
		var is_major := i % 2 == 0
		var hot := f >= danger
		var col := (C_DANGER if hot else (C_TICK if is_major else C_TICK_MINOR))
		var l: float = (R * 0.15) if is_major else (R * 0.08)
		draw_line(_pt(c, R, a), _pt(c, R - l, a), col, 3.0 if is_major else 1.6)
		if is_major:
			var txt := "%d" % int(round(f * kmh_max))
			var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			var p := _pt(c, R * 0.74, a)
			draw_string(font, p - Vector2(w * 0.5, -4.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
				C_DANGER if hot else C_TEXT)

	# --- rev ring around the rim: the tacho, so both instruments live in one dial ---
	var redline: float = car.redline_rpm
	var rpm_max: float = ceil(redline / 1000.0) * 1000.0
	var red_from: float = redline * float(car.shift_light_frac) / maxf(rpm_max, 1.0)
	var rfrac := clampf(float(eng.get("rpm", 0.0)) / maxf(rpm_max, 1.0), 0.0, 1.0)
	_arc(c, R + 12.0, SWEEP_START, SWEEP_START - SWEEP, Color(0.24, 0.25, 0.27), 5.0)
	if rfrac > 0.002:
		_arc(c, R + 12.0, SWEEP_START, SWEEP_START - SWEEP * rfrac,
			C_REV if rfrac < red_from else C_RED, 5.0)

	# --- needle ---
	var sfrac := clampf(_kmh_shown / kmh_max, 0.0, 1.0)
	var na := SWEEP_START - SWEEP * sfrac
	draw_line(_pt(c, -R * 0.12, na), _pt(c, R * 0.86, na), C_NEEDLE, 3.0)
	draw_circle(c, 5.0, C_RIM)

	# --- digital repeat: gear badge, speed, units ---
	var g := int(eng.get("gear", 0))
	var gtxt := "N" if g == 0 else ("R" if g == -1 else str(g))
	var badge := Rect2(c.x - 48.0, c.y - 19.0, 26.0, 30.0)
	draw_rect(badge, Color(0.87, 0.88, 0.90))
	var gw := font.get_string_size(gtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	draw_string(font, Vector2(badge.position.x + (26.0 - gw) * 0.5, badge.position.y + 23.0), gtxt,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 21, Color(0.10, 0.10, 0.11))
	var stxt := "%d" % int(round(maxf(_kmh_shown, 0.0)))
	draw_string(font, Vector2(c.x - 16.0, c.y + 11.0), stxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 34, C_TEXT)
	draw_string(font, Vector2(c.x - 16.0, c.y + 27.0), "KM/H", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, C_DIM)

	# --- telltales, from the systems already modelled ---
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

	var s_cool := 0                                    # coolant temperature
	if etemp > eopt + 22.0:
		s_cool = 2
	elif etemp > eopt + 8.0:
		s_cool = 1
	var s_eng := 0                                     # check engine: stalled, or damage costing power
	if bool(eng.get("stalled", false)) or dmg > 0.35:
		s_eng = 2
	elif dmg > 0.05:
		s_eng = 1
	var s_tyre := 0                                    # TPMS: a puncture is an emergency
	if punctured:
		s_tyre = 2
	elif worn > 0.75 or tyre_hot > topt + twin * 0.6:
		s_tyre = 1
	var s_dmg := 0                                     # general warning: chassis damage
	if dmg > 0.35:
		s_dmg = 2
	elif dmg > 0.05:
		s_dmg = 1

	var iy := c.y + 48.0
	var step := 27.0
	_icon_warn(Vector2(c.x - step * 1.5, iy), 15.0, _lamp_col(s_dmg))
	_icon_coolant(Vector2(c.x - step * 0.5, iy), 15.0, _lamp_col(s_cool))
	_icon_engine(Vector2(c.x + step * 0.5, iy), 15.0, _lamp_col(s_eng))
	_icon_tyre(Vector2(c.x + step * 1.5, iy), 15.0, _lamp_col(s_tyre))

	# --- odometer strip ---
	var otxt := "%06d" % int(_odo / 1000.0 * 10.0)     # tenths of a km, like a trip meter
	var ow := font.get_string_size(otxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	draw_rect(Rect2(c.x - ow * 0.5 - 5.0, c.y + 60.0, ow + 10.0, 15.0), Color(0.07, 0.07, 0.08))
	draw_string(font, Vector2(c.x - ow * 0.5, c.y + 72.0), otxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C_DIM)
