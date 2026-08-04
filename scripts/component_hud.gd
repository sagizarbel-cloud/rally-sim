extends Control
## Player-facing component overlay (top-right): a clean top-down schematic of the drivetrain.
## Wheels + engine are coloured by temperature (blue cold -> green -> yellow -> orange -> red hot;
## RED = punctured tyre), tyres darken from the bottom with wear. Axle lines + a spine + diff marks
## show the drivetrain, with the DRIVEN axles/diffs highlighted for the current mode (AWD/RWD/FWD).
## No panel background / title / body outline - kept minimal. Separate from the debug/tuning text HUD.

var car

const STOPS := [
	[20.0, Color(0.25, 0.45, 1.0)],   # cold  - blue
	[55.0, Color(0.20, 0.85, 0.40)],  # cool  - green
	[85.0, Color(0.95, 0.85, 0.20)],  # warm  - yellow (tyre optimal)
	[110.0, Color(1.0, 0.5, 0.1)],    # hot   - orange
	[132.0, Color(0.9, 0.15, 0.1)],   # v.hot - red
]

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(_delta: float) -> void:
	queue_redraw()

func _temp_color(temp: float, punctured: bool) -> Color:
	if punctured:
		return Color(0.92, 0.12, 0.12)
	var first: float = STOPS[0][0]
	if temp <= first:
		return STOPS[0][1]
	for i in range(STOPS.size() - 1):
		var a: float = STOPS[i][0]
		var b: float = STOPS[i + 1][0]
		if temp <= b:
			var lo: Color = STOPS[i][1]
			var hi: Color = STOPS[i + 1][1]
			return lo.lerp(hi, (temp - a) / (b - a))
	return STOPS[STOPS.size() - 1][1]

func _diff_mark(p: Vector2, driven: bool, on_col: Color, off_col: Color) -> void:
	var s := 8.0
	var r := Rect2(p - Vector2(s * 0.5, s * 0.5), Vector2(s, s))
	draw_rect(r, on_col if driven else off_col)
	draw_rect(r, Color(0, 0, 0, 0.5), false, 1.0)

func _draw() -> void:
	if car == null or not car.has_method("get_engine"):
		return
	var wheels: Array = car.get_wheels()
	if wheels.size() < 4:
		return
	var eng: Dictionary = car.get_engine()
	var etemp: float = eng.get("temp", 20.0)
	var dmg: float = eng.get("damage", 0.0)
	var mode: String = eng.get("mode", "AWD")
	var font := ThemeDB.fallback_font
	var vs := get_viewport_rect().size

	# schematic layout (car pointing UP), anchored top-right
	var cx := vs.x - 66.0
	var topY := 26.0
	var track := 42.0
	var frontY := topY + 32.0
	var rearY := frontY + 96.0
	var lx := cx - track
	var rx := cx + track
	var ww := 15.0
	var wl := 30.0
	var line_grey := Color(0.55, 0.55, 0.6, 0.7)
	var drive_col := Color(0.95, 0.8, 0.25)         # powered axle / diff
	var idle_col := Color(0.42, 0.42, 0.48, 0.85)   # unpowered
	var front_driven := mode == "FWD" or mode == "AWD"
	var rear_driven := mode == "RWD" or mode == "AWD"

	# drivetrain: engine->front link, spine (propshaft), two axles, diff marks
	draw_line(Vector2(cx, topY + 14.0), Vector2(cx, frontY), line_grey, 2.0)
	draw_line(Vector2(cx, frontY), Vector2(cx, rearY), line_grey, 2.0)
	draw_line(Vector2(lx, frontY), Vector2(rx, frontY), drive_col if front_driven else idle_col, 3.0)
	draw_line(Vector2(lx, rearY), Vector2(rx, rearY), drive_col if rear_driven else idle_col, 3.0)
	_diff_mark(Vector2(cx, frontY), front_driven, drive_col, idle_col)
	if mode == "AWD":
		_diff_mark(Vector2(cx, (frontY + rearY) * 0.5), true, drive_col, idle_col)   # centre diff
	_diff_mark(Vector2(cx, rearY), rear_driven, drive_col, idle_col)

	# engine square at the nose
	var es := 18.0
	var er := Rect2(cx - es * 0.5, topY - 4.0, es, es)
	draw_rect(er, _temp_color(etemp, false))
	draw_rect(er, Color(0, 0, 0, 0.45), false, 1.0)

	# four wheels, centred on the axle ends
	var wc := [Vector2(lx, frontY), Vector2(rx, frontY), Vector2(lx, rearY), Vector2(rx, rearY)]
	for i in range(4):
		var w = wheels[i]
		var r := Rect2(wc[i] - Vector2(ww * 0.5, wl * 0.5), Vector2(ww, wl))
		draw_rect(r, _temp_color(w.temp, w.punctured))
		var wf: float = clampf(w.tyre_wear, 0.0, 1.0)
		if wf > 0.01:
			draw_rect(Rect2(r.position + Vector2(0, wl * (1.0 - wf)), Vector2(ww, wl * wf)), Color(0.03, 0.03, 0.03, 0.5))
		draw_rect(r, Color(0, 0, 0, 0.45), false, 1.0)

	# compact damage bar under the car
	var dby := rearY + 22.0
	var dbw := (rx - lx) + ww
	draw_string(font, Vector2(lx - ww * 0.5, dby), "DMG %d%%" % int(dmg * 100.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.82, 0.82, 0.88))
	draw_rect(Rect2(lx - ww * 0.5, dby + 4.0, dbw, 5.0), Color(0.12, 0.12, 0.14, 0.7))
	draw_rect(Rect2(lx - ww * 0.5, dby + 4.0, dbw * dmg, 5.0), Color(0.25 + 0.65 * dmg, 0.72 - 0.55 * dmg, 0.15))
