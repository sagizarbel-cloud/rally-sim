extends CanvasLayer
## Live tuning panel (toggle with Tab). Each slider writes straight into the vehicle's
## exported properties via set()/get(), so changes are felt immediately. A "Reset" button
## restores the values the car launched with.

var vehicle
var _panel: PanelContainer
var _defaults := {}
var _ctls: Array = []      # cached slider/checkbox controls (built once in _ready)

# label, property, min, max, step, value-formatter
# Specs for BOTH M1 and M2 params. In _ready, only the ones the loaded car actually
# has are shown (so the same panel adapts to whichever vehicle is wired in).
var _specs := [
	# engine / drivetrain
	["Power (M1)",           "engine_power",      120000.0, 900000.0, 5000.0, func(v): return "%d kW" % int(v / 1000.0)],
	["Launch / 1st gear",    "launch_boost",           1.0,      5.0,   0.1,  func(v): return "%.1fx" % v],
	["Peak torque (M2)",     "peak_torque",          150.0,   1500.0,  10.0,  func(v): return "%d Nm" % int(v)],
	["Redline (M2)",         "redline_rpm",         5000.0,   9500.0, 100.0,  func(v): return "%d rpm" % int(v)],
	["Shift light @ (M2)",   "shift_light_frac",       0.75,     1.0,   0.01, func(v): return "%d%% redline" % int(v * 100.0)],
	["Final drive (M2)",     "final_drive",            2.5,      5.5,   0.05, func(v): return "%.2f" % v],
	["AWD split (M2)",       "torque_split",           0.3,      0.9,   0.05, func(v): return "%d%% rear" % int(v * 100.0)],
	["Aero drag (M2)",       "drag_k",                 0.05,     2.5,   0.05, func(v): return "%.2f" % v],
	# slip-ratio drivetrain feel (M2)
	# A3 differentials: type per axle + its parameters + the AWD centre coupling
	["Front diff (M2)",      "front_diff_type",        0.0,      3.0,   1.0,  func(v): return ["OPEN", "VISCOUS", "CLUTCH-PACK", "LOCKED"][clampi(int(v), 0, 3)]],
	["Rear diff (M2)",       "rear_diff_type",         0.0,      3.0,   1.0,  func(v): return ["OPEN", "VISCOUS", "CLUTCH-PACK", "LOCKED"][clampi(int(v), 0, 3)]],
	["Front visc (M2)",      "front_visc",             0.0,    300.0,  10.0,  func(v): return "%d Nm/(rad/s)" % int(v)],
	["Rear visc (M2)",       "rear_visc",              0.0,    300.0,  10.0,  func(v): return "%d Nm/(rad/s)" % int(v)],
	["Front preload (M2)",   "front_preload",          0.0,    300.0,  10.0,  func(v): return "%d Nm" % int(v)],
	["Rear preload (M2)",    "rear_preload",           0.0,    300.0,  10.0,  func(v): return "%d Nm" % int(v)],
	["Front power ramp (M2)","front_power_ramp",       0.0,      1.0,   0.05, func(v): return "%.2f" % v],
	["Rear power ramp (M2)", "rear_power_ramp",        0.0,      1.0,   0.05, func(v): return "%.2f" % v],
	["Front coast ramp (M2)","front_coast_ramp",       0.0,      1.0,   0.05, func(v): return "%.2f" % v],
	["Rear coast ramp (M2)", "rear_coast_ramp",        0.0,      1.0,   0.05, func(v): return "%.2f" % v],
	["Centre coupling (M2)", "centre_coupling",        0.0,    200.0,   5.0,  func(v): return "%d Nm/(rad/s)" % int(v)],
	["Centre preload (M2)",  "centre_preload",         0.0,    150.0,   5.0,  func(v): return "%d Nm" % int(v)],
	["Wheel inertia (M2)",   "wheel_inertia",          0.5,      4.0,   0.1,  func(v): return "%.1f" % v],
	["Engine inertia (M2)",  "engine_inertia",         0.05,     0.6,   0.01, func(v): return "%.2f" % v],
	["Peak slip tarmac (M2)","peak_slip_tarmac",       0.06,     0.45,  0.01, func(v): return "%d%% slip" % int(v * 100.0)],
	["Peak slip gravel (M2)","peak_slip_gravel",       0.10,     0.60,  0.01, func(v): return "%d%% slip" % int(v * 100.0)],
	["Idle torque (M2)",     "idle_torque_frac",       0.2,      0.9,   0.05, func(v): return "%d%% of peak" % int(v * 100.0)],
	# A1: engine-as-inertia + clutch
	["Intake lag (M2)",      "intake_tau",             0.0,      0.25,  0.01, func(v): return "%.2f s" % v],
	["Eng brake @ idle (M2)","engine_brake_idle",      5.0,     60.0,   1.0,  func(v): return "%d Nm" % int(v)],
	["Eng brake @ redline (M2)","engine_brake_redline",20.0,   150.0,   5.0,  func(v): return "%d Nm" % int(v)],
	["Clutch capacity (M2)", "clutch_margin",          1.0,      2.5,   0.05, func(v): return "%.2fx peak" % v],
	["Clutch bite rpm (M2)", "bite_rpm",            1200.0,   3500.0, 100.0,  func(v): return "%d rpm" % int(v)],
	["Anti-stall (M2)",      "anti_stall",             0.0,      1.0,   1.0,  func(v): return "ON" if v else "OFF"],
	["Manual clutch (M2)",   "manual_clutch",          0.0,      1.0,   1.0,  func(v): return "ON" if v else "OFF"],
	["Auto blip (M2)",       "auto_blip",              0.0,      1.0,   1.0,  func(v): return "ON" if v else "OFF"],
	# A4: shift model + the two new assists
	["Shift time (M2)",      "shift_time",             0.05,     0.60,  0.01, func(v): return "%.2f s" % v],
	["Overrev guard (M2)",   "overrev_guard",          0.0,      1.0,   1.0,  func(v): return "ON" if v else "OFF"],
	["Launch assist (M2)",   "launch_assist",          0.0,      1.0,   1.0,  func(v): return "ON" if v else "OFF"],
	["Stability assist (M2)","stability_assist",       0.0,      1.0,   1.0,  func(v): return "ON" if v else "OFF"],
	["Stability gain (M2)",  "stability_gain",       500.0,  10000.0, 250.0,  func(v): return "%d Nm/(rad/s)" % int(v)],
	["Stability margin (M2)","stability_margin",       0.05,     0.80,  0.05, func(v): return "%.2f rad/s" % v],
	["Traction control (M2)","tc_enabled",             0.0,      1.0,   1.0,  func(v): return "ON" if v else "OFF"],
	["TC slip target (M2)",  "tc_slip_target",         0.10,     0.80,  0.05, func(v): return "%.2f" % v],
	["FWD front bias (M2)",  "fwd_bias",               0.0,      0.8,   0.05, func(v): return "%.2f m" % v],
	["RWD rear bias (M2)",   "rwd_bias",               0.0,      0.8,   0.05, func(v): return "%.2f m" % v],
	# suspension (M2)
	["Ride freq front (M2)", "ride_freq_front",        0.8,      2.4,  0.05, func(v): return "%.2f Hz" % v],
	["Ride freq rear (M2)",  "ride_freq_rear",         0.8,      2.4,  0.05, func(v): return "%.2f Hz" % v],
	["Damping ratio (M2)",   "zeta",                   0.25,     1.30, 0.05, func(v): return "%.2f zeta" % v],
	["Roll gradient (M2)",   "roll_gradient_target",   1.5,      8.0,  0.25, func(v): return "%.2f deg/g" % v],
	["Roll couple front(M2)","roll_couple_front",      0.30,     0.75, 0.01, func(v): return "%d%% front" % int(v * 100.0)],
	["Bump stop zone (M2)",  "bumpstop_zone",          0.05,     0.50, 0.01, func(v): return "%d%% of travel" % int(v * 100.0)],
	["Bump stop force (M2)", "bumpstop_g",             1.0,     15.0,  0.5,  func(v): return "%.1f g" % v],
	["Camber (M2)",          "camber_deg",             0.0,      6.0,    0.5, func(v): return "%.1f deg" % v],
	# virtual pedals (input shaping)
	["Throttle rise",        "throttle_rise_time",     0.0,      0.5,   0.02, func(v): return "%.2f s" % v],
	["Throttle fall",        "throttle_fall_time",     0.0,      0.5,   0.02, func(v): return "%.2f s" % v],
	["Brake rise",           "brake_rise_time",        0.0,      0.5,   0.02, func(v): return "%.2f s" % v],
	["Brake fall",           "brake_fall_time",        0.0,      0.5,   0.02, func(v): return "%.2f s" % v],
	# brakes
	["Brake torque (M2)",    "brake_torque",        1000.0,   6000.0, 100.0,  func(v): return "%d Nm" % int(v)],
	["Handbrake torque (M2)","handbrake_torque",    1000.0,   8000.0, 100.0,  func(v): return "%d Nm" % int(v)],
	["HB opens centre (M2)", "handbrake_opens_centre", 0.0,     1.0,   1.0,  func(v): return "ON" if v else "OFF"],
	["Slide friction (M2)",  "slide_friction",         0.0,      1.0,   1.0,  func(v): return "ON" if v else "OFF"],
	# chassis / grip (shared)
	# drives chassis_mass, NOT the RigidBody's `mass`: chassis_mass is the single authority the
	# suspension, roll gradient, tyre load reference and rolling resistance all read (the body's
	# mass follows it in _derive_setup). Pointing this row at `mass` desynced the two.
	["Car weight",           "chassis_mass",         700.0,   2500.0,   25.0, func(v): return "%d kg" % int(v)],
	["Grip - lateral",       "mu_lat",                 0.6,      2.2,   0.05, func(v): return "%.2f" % v],
	["Grip - longitudinal",  "mu_long",                0.6,      2.6,   0.05, func(v): return "%.2f" % v],
	# tyre thermal + wear + puncture (M7)
	["Optimal tyre temp",    "optimal_temp",          50.0,    120.0,   5.0,   func(v): return "%d C" % int(v)],
	["Tyre heat rate",       "tyre_heat_rate",     0.00005,  0.0015, 0.00005, func(v): return "%.5f" % v],
	["Tyre cool rate",       "tyre_cool_rate",       0.01,     0.20,   0.01,  func(v): return "%.2f" % v],
	["Tyre wear rate",       "tyre_wear_rate",        0.0,     0.02,   0.001, func(v): return "%.3f" % v],
	["Worn grip",            "worn_grip",             0.40,     1.0,    0.05,  func(v): return "%.2f" % v],
	["Cold grip",            "cold_grip",             0.50,     1.0,    0.05,  func(v): return "%.2f" % v],
	# engine thermal (physical heat balance)
	["Engine heat cap",      "engine_heat_capacity", 20000.0, 250000.0, 5000.0, func(v): return "%d kJ/K" % int(v / 1000.0)],
	["Coolant heat frac",    "coolant_heat_frac",      0.2,      1.5,   0.05,  func(v): return "%.2f" % v],
	["Thermostat",           "thermostat_temp",       60.0,    105.0,   1.0,   func(v): return "%d C" % int(v)],
	["Radiator",             "radiator_k",           200.0,   3000.0,  50.0,   func(v): return "%d W/K" % int(v)],
	# damage (M8)
	["Impact threshold",     "impact_threshold",     20.0,    120.0,   5.0,   func(v): return "%d" % int(v)],
	["Damage per hit",       "damage_gain",           0.0,      1.0,    0.05,  func(v): return "%.2f" % v],
	["Damage power loss",    "damage_power_loss",     0.0,      0.9,    0.05,  func(v): return "%.2f" % v],
	["Damage steer pull",    "damage_steer_pull",     0.0,      0.5,    0.02,  func(v): return "%.2f" % v],
]

func _ready() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 1.0            # span the window height so the scroll area has room
	_panel.offset_left = -372
	_panel.offset_right = -12
	_panel.offset_top = 12
	_panel.offset_bottom = -12
	add_child(_panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	_panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(vbox)

	var title := Label.new()
	title.text = "TUNING   (Tab to hide)"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	for s in _specs:
		if vehicle.get(s[1]) == null:
			continue                      # this vehicle (M1 or M2) doesn't have the param
		_defaults[s[1]] = vehicle.get(s[1])
		if typeof(vehicle.get(s[1])) == TYPE_BOOL:
			_add_toggle(vbox, s[0], s[1])   # bool params (e.g. traction control) get a checkbox
		else:
			_add_row(vbox, s[0], s[1], s[2], s[3], s[4], s[5])

	var reset := Button.new()
	reset.text = "Reset to launch values"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(_reset)
	vbox.add_child(reset)

	_ctls = _all_sliders(self)   # cached once: used by Reset and the live re-sync below
	_panel.visible = false   # hidden until Tab (CanvasLayer itself has no 'visible')

func _process(_delta: float) -> void:
	# Keep the widgets showing what the car ACTUALLY has: code can change these properties
	# behind the panel's back (e.g. the [1]/[2]/[3] diff presets). Without this the sliders
	# would sit at stale positions and shove the old value back the moment one was touched.
	if not _panel.visible:
		return
	for ctl in _ctls:
		if not ctl.has_meta("prop"):
			continue
		var prop: String = ctl.get_meta("prop")
		var cur = vehicle.get(prop)
		if cur == null:
			continue
		if ctl is HSlider:
			if not is_equal_approx(ctl.value, float(cur)):
				ctl.value = float(cur)      # fires value_changed -> refreshes the label too
		elif ctl is CheckButton:
			if ctl.button_pressed != bool(cur):
				ctl.button_pressed = bool(cur)

func _add_row(vbox: VBoxContainer, label: String, prop: String, mn: float, mx: float, step: float, fmt: Callable) -> void:
	var top := HBoxContainer.new()
	var name_lbl := Label.new(); name_lbl.text = label
	name_lbl.custom_minimum_size = Vector2(180, 0)
	var val_lbl := Label.new()
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name_lbl); top.add_child(val_lbl)
	vbox.add_child(top)

	var slider := HSlider.new()
	slider.min_value = mn; slider.max_value = mx; slider.step = step
	slider.value = vehicle.get(prop)
	slider.focus_mode = Control.FOCUS_NONE   # so Tab isn't eaten by focus navigation
	slider.custom_minimum_size = Vector2(320, 0)
	slider.value_changed.connect(func(v):
		vehicle.set(prop, v)
		val_lbl.text = fmt.call(v))
	vbox.add_child(slider)
	val_lbl.text = fmt.call(slider.value)
	# remember the slider so Reset can move it
	slider.set_meta("prop", prop)
	slider.set_meta("val_lbl", val_lbl)
	slider.set_meta("fmt", fmt)

func _add_toggle(vbox: VBoxContainer, label: String, prop: String) -> void:
	var btn := CheckButton.new()
	btn.text = label
	btn.button_pressed = vehicle.get(prop)
	btn.focus_mode = Control.FOCUS_NONE
	btn.toggled.connect(func(on): vehicle.set(prop, on))
	vbox.add_child(btn)
	btn.set_meta("prop", prop)

func _reset() -> void:
	for ctl in _ctls:
		if not ctl.has_meta("prop"):
			continue
		var prop: String = ctl.get_meta("prop")
		if ctl is HSlider:
			ctl.value = _defaults[prop]      # triggers value_changed -> writes + label
		elif ctl is CheckButton:
			ctl.button_pressed = _defaults[prop]   # triggers toggled -> writes

func _all_sliders(node: Node) -> Array:
	var out := []
	for c in node.get_children():
		if c is HSlider or c is CheckButton:
			out.append(c)
		out += _all_sliders(c)
	return out

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("tuning_toggle"):
		_panel.visible = not _panel.visible
