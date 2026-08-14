extends CanvasLayer
## Live tuning panel (toggle with Tab). Each slider writes straight into the vehicle's
## exported properties via set()/get(), so changes are felt immediately. A "Reset" button
## restores the values the car launched with.

var vehicle
var _panel: PanelContainer
var _defaults := {}
var _ctls: Array = []      # cached slider/checkbox controls (built once in _ready)
var _help_lbl: Label       # banner under the title: explains whatever is under the cursor

# What each control actually DOES, in one line, shown in the banner on hover (and as the native
# tooltip). Every line starts with the system it belongs to, because the panel is sorted A-Z and
# the alphabet scatters related knobs - the tag is how you know a diff ramp from a damper.
const HELP := {
	# --- engine ---
	"engine_power": "ENGINE (M1 only) - flat power figure for the old M1 car. The M2 car ignores it and uses Peak torque.",
	"peak_torque": "ENGINE - the peak of the torque curve (N.m), reached around 4300 rpm. The single biggest 'how fast' knob.",
	"redline_rpm": "ENGINE - rpm where the limiter cuts. Also sets the engine-audio pitch ceiling and the gearing-limited top speed.",
	"engine_inertia": "ENGINE - crank + flywheel inertia. Low = revs flare and blip quickly; high = lazy, smoother, harder to stall.",
	"idle_torque_frac": "ENGINE - full-throttle torque at idle as a fraction of peak. An engine cannot breathe at 1000 rpm; low values make launches bog.",
	"intake_tau": "ENGINE - throttle-to-torque lag (s), modelling intake filling. Larger = softer, more elastic response.",
	"engine_brake_idle": "ENGINE - motoring friction at idle (N.m). Part of how hard the car slows when you lift off in gear.",
	"engine_brake_redline": "ENGINE - motoring friction at redline (N.m). Competition spec is high (90+): strong engine braking, nose tucks on lift.",
	"engine_heat_capacity": "ENGINE - thermal mass: how slowly engine temperature moves.",
	"coolant_heat_frac": "ENGINE - share of combustion heat going into the coolant rather than out of the exhaust.",
	"thermostat_temp": "ENGINE - temperature at which the thermostat opens and the radiator starts doing work.",
	"radiator_k": "ENGINE - radiator cooling power, in watts per degree of temperature difference.",
	# --- drivetrain ---
	"final_drive": "DRIVETRAIN - the axle ratio every gear multiplies through. Higher = shorter gearing: quicker acceleration, lower top speed.",
	"torque_split": "DRIVETRAIN - AWD front/rear torque share. Higher sends more to the rear: more oversteer on power.",
	"launch_boost": "DRIVETRAIN - extra torque multiplier in 1st to get off the line. A crutch; Launch assist is the modern version.",
	"shift_time": "DRIVETRAIN - seconds a gearshift takes, with drive cut throughout. Longer = a rhythmic dip on full-throttle upshifts.",
	"wheel_inertia": "DRIVETRAIN - rotational inertia of one wheel and tyre (kg.m2). Higher resists both spin-up and lock-up.",
	"clutch_margin": "CLUTCH - torque capacity as a multiple of peak engine torque. Near 1.0 the plates slip under load; high never slips.",
	"bite_rpm": "CLUTCH - the rpm the clutch aims to hold during a launch. Higher = more aggressive, more wheelspin off the line.",
	"manual_clutch": "CLUTCH - whether the clutch pedal (Left Shift / Square) is live. OFF = the clutch is automatic.",
	# --- differentials ---
	"front_diff_type": "DIFF - front type: 0 open, 1 viscous, 2 Salisbury clutch-pack, 3 locked. Open lets the inside wheel spin away.",
	"rear_diff_type": "DIFF - rear type: 0 open, 1 viscous, 2 Salisbury clutch-pack, 3 locked. Locked makes the throttle steer the car on dirt.",
	"front_visc": "DIFF - front viscous coupling (N.m per rad/s of wheel-speed difference). Resists one wheel spinning up, smoothly.",
	"rear_visc": "DIFF - rear viscous coupling (N.m per rad/s of wheel-speed difference).",
	"front_preload": "DIFF - front clutch-pack preload (N.m): locking that is always present, even at zero torque.",
	"rear_preload": "DIFF - rear clutch-pack preload (N.m): always-on locking, independent of how much torque is flowing.",
	"front_power_ramp": "DIFF - how hard the FRONT pack locks UNDER POWER. Higher pulls the car straight and tight on exit (more understeer).",
	"rear_power_ramp": "DIFF - how hard the REAR pack locks UNDER POWER. Higher = longer, more stable power slides.",
	"front_coast_ramp": "DIFF - how hard the FRONT pack locks OFF THROTTLE. Affects entry stability.",
	"rear_coast_ramp": "DIFF - how hard the REAR pack locks OFF THROTTLE. High = stable entry; low = eager lift-off rotation.",
	"centre_coupling": "DIFF - AWD centre coupling: how hard the axles tie together when their speeds differ. High = 'four paws digging'.",
	"centre_preload": "DIFF - always-on locking between the front and rear axles, independent of any speed difference.",
	# --- suspension ---
	"ride_freq_front": "SUSPENSION - front natural frequency (Hz) - THE spring-rate handle. Gravel cars live at 1.2-1.6 Hz. Higher = stiffer, less sag, more travel left for bumps.",
	"ride_freq_rear": "SUSPENSION - rear natural frequency (Hz), normally 10-20% above the front so the car settles flat after a bump (flat ride).",
	"peak_alpha_tarmac": "TYRE - slip ANGLE where lateral grip peaks on asphalt. Low = tarmac bite that arrives early and lets go sharply.",
	"peak_alpha_gravel": "TYRE - slip ANGLE where lateral grip peaks on gravel. Higher than tarmac: gravel slides deeper and more progressively before letting go. This gap IS the surface difference.",
	"Cy": "TYRE - how sharply lateral grip falls off PAST the peak on TARMAC. Lower = flatter, more forgiving when you overshoot; the tail figure is the fraction of peak grip left at huge slip angles.",
	"cy_gravel": "TYRE - the same falloff shape for GRAVEL. Lower it to make slides catchable without moving where grip peaks (that is Peak slip angle gravel). This is the knob for 'the car lets go too easily once sideways'.",
	"sigma_lat": "TYRE - relaxation length: how far the tyre must ROLL before its lateral force builds. Bigger = the car takes a set with a beat of delay you can time a flick against; near zero = darty and instant.",
	"com_height": "CHASSIS - centre-of-mass height. Higher = more honest body roll and weight transfer (and more roll-over risk on berms); very low corners flat but feels dead.",
	"zeta_bump": "SUSPENSION - damping ratio in COMPRESSION. Lower lets the wheel follow the ground over bumps; too low and the car floats and pogos.",
	"zeta_rebound": "SUSPENSION - damping ratio in EXTENSION, normally FIRMER than bump. It pulls the wheel back down after a bump without levering the body up. Too low = double bounce after crests; too high = the car jacks down over successive bumps.",
	"knee_speed": "SUSPENSION - damper velocity where the valve blows off. Below it the damper controls body roll and pitch at full rate; above it the rate collapses so sharp hits pass through instead of spiking into the chassis.",
	"hs_blowoff": "SUSPENSION - how much rate survives above the knee, as a fraction. 1.0 = no blow-off (linear damper, the pre-B2 car); lower = rough ground is swallowed more.",
	"roll_gradient_target": "SUSPENSION - HOW FAR THE BODY LEANS: degrees of body roll per 1 g of cornering. ~2.5 = flat and go-kart-like, ~6 = soft and wallowy. The anti-roll bars are sized to hit this number.",
	"roll_couple_front": "SUSPENSION - what SHARE of total roll stiffness the FRONT axle carries (0.55 = 55%). More front = more understeer, less = more oversteer. This is the balance knob.",
	"bumpstop_zone": "SUSPENSION - fraction of travel the bump stop occupies at the top (0.20 = the last 20%): the cushion before the suspension goes solid.",
	"bumpstop_g": "SUSPENSION - bump-stop strength, in g of that corner's static load. Higher = less bottoming, but harsher and crashier over big hits.",
	"camber_deg": "SUSPENSION - static wheel lean. Negative camber gives the loaded outside tyre a flatter contact patch mid-corner.",
	# --- chassis / tyres ---
	"chassis_mass": "CHASSIS - the car's mass, and the one authority for it: moving this re-rates the springs, bars, tyre load reference and rolling resistance live.",
	"fwd_bias": "CHASSIS - how far the centre of mass shifts FORWARD in FWD mode, loading the front axle for traction.",
	"rwd_bias": "CHASSIS - how far the centre of mass shifts REARWARD in RWD mode.",
	"mu_lat": "TYRE - base lateral friction coefficient, before surface, load, temperature and wear. The cornering-grip master knob.",
	"mu_long": "TYRE - base longitudinal friction coefficient. Drives both acceleration and braking grip.",
	"peak_slip_tarmac": "TYRE - the slip ratio where TARMAC grip peaks (~0.14). Lower = grip arrives and leaves sooner, so the limit feels more on/off.",
	"peak_slip_gravel": "TYRE - the slip ratio where GRAVEL grip peaks (~0.28). Much later than tarmac, which is why loose surfaces reward wheelspin.",
	"slide_friction": "TYRE - grip retained once a tyre is fully sliding, as a fraction of peak. Low makes a slide punishing and hard to recover.",
	"optimal_temp": "TYRE - core temperature where grip peaks (85 C). Colder AND hotter both cost grip.",
	"tyre_heat_rate": "TYRE - how fast friction work heats the tyre.",
	"tyre_cool_rate": "TYRE - how fast airflow cools it again.",
	"tyre_wear_rate": "TYRE - how fast tyre work wears the tyre out. Wear ends in a blowout.",
	"worn_grip": "TYRE - grip multiplier at 100% wear.",
	"cold_grip": "TYRE - grip multiplier when the tyre is stone cold.",
	# --- brakes / aero / input ---
	"brake_torque": "BRAKES - maximum brake torque per wheel (N.m). Past the tyre's limit the wheels simply lock: there is no ABS.",
	"handbrake_torque": "BRAKES - torque the lever applies to each REAR wheel.",
	"handbrake_opens_centre": "BRAKES - rally hydraulic handbrake behaviour: disengages the centre diff so the rears can lock without dragging the fronts.",
	"drag_k": "AERO - air resistance; force = k x speed squared. It sets top speed AND does most of the retardation above ~300 km/h, so turning it down lengthens braking too.",
	"throttle_rise_time": "INPUT - how fast the virtual throttle pedal presses, so a binary key behaves like a foot. Analog triggers bypass this.",
	"throttle_fall_time": "INPUT - how fast the virtual throttle pedal lifts.",
	"brake_rise_time": "INPUT - how fast the virtual brake pedal presses. Long enough to trail-brake with, short enough to stop.",
	"brake_fall_time": "INPUT - how fast the virtual brake pedal releases.",
	# --- assists / HUD / damage ---
	"anti_stall": "ASSIST - keeps the engine alive at low rpm, like a real rally anti-stall. OFF means you can genuinely stall it.",
	"auto_blip": "ASSIST - rev-matches on downshift. ON is smooth; OFF gives a felt jolt and a momentary slide.",
	"overrev_guard": "ASSIST - blocks a downshift that would spin the engine past its limit. OFF lets a money shift cost real damage.",
	"launch_assist": "ASSIST - manages clutch and throttle for a consistent launch. OFF hands the clutch back to you.",
	"stability_assist": "ASSIST - brakes individual wheels to correct yaw. ON tames big dirt slides; OFF is raw.",
	"stability_gain": "ASSIST - how hard stability assist corrects. Too high and it fights you through ordinary corners.",
	"stability_margin": "ASSIST - how far past the tyre's limit a slide must go before the assist steps in. Higher = later and less intrusive.",
	"tc_enabled": "ASSIST - traction control: trims engine torque when the driven wheels exceed the slip target.",
	"tc_slip_target": "ASSIST - the slip ratio traction control holds. Higher permits more wheelspin.",
	"shift_light_frac": "HUD - fraction of redline where the cabin shift light starts flashing (0.90 = at 90% of redline).",
	"impact_threshold": "DAMAGE - horizontal deceleration (m/s2) that counts as a crash. Braking, cornering and landings stay below it.",
	"damage_gain": "DAMAGE - how much damage a hit of a given severity does.",
	"damage_power_loss": "DAMAGE - engine power lost at 100% damage.",
	"damage_steer_pull": "DAMAGE - how hard the car pulls to one side at 100% damage.",
}

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
	["Peak slip angle tarmac (M2)","peak_alpha_tarmac", 4.0,     16.0,  0.5,  func(v): return "%.1f deg" % v],
	["Peak slip angle gravel (M2)","peak_alpha_gravel", 6.0,     24.0,  0.5,  func(v): return "%.1f deg" % v],
	["Lat curve shape tarmac (M2)","Cy",           1.05,     1.70, 0.05, func(v): return "C %.2f (tail %.2f)" % [v, sin(v * PI * 0.5)]],
	["Lat curve shape gravel (M2)","cy_gravel",    1.05,     1.70, 0.05, func(v): return "C %.2f (tail %.2f)" % [v, sin(v * PI * 0.5)]],
	["Relaxation length (M2)","sigma_lat",              0.10,     1.20, 0.05, func(v): return "%.2f m" % v],
	["CoM height (M2)",      "com_height",             -0.60,    -0.10, 0.01, func(v): return "%.2f m" % v],
	["Damping bump (M2)",    "zeta_bump",              0.15,     1.30, 0.05, func(v): return "%.2f zeta" % v],
	["Damping rebound (M2)", "zeta_rebound",           0.15,     1.60, 0.05, func(v): return "%.2f zeta" % v],
	["Damper knee (M2)",     "knee_speed",             0.02,     0.40, 0.01, func(v): return "%.2f m/s" % v],
	["HS blow-off (M2)",     "hs_blowoff",             0.05,     1.00, 0.05, func(v): return "%.2f x" % v],
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

	# Help banner: pinned under the title so it never moves, and reserved at a fixed height so
	# the list below does not jump around as explanations of different lengths come and go.
	_help_lbl = Label.new()
	_help_lbl.text = "Hover any control for an explanation."
	_help_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help_lbl.custom_minimum_size = Vector2(0, 76)
	_help_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_help_lbl.add_theme_font_size_override("font_size", 12)
	_help_lbl.add_theme_color_override("font_color", Color(0.72, 0.84, 1.0))
	vbox.add_child(_help_lbl)

	# A-Z, because there are ~76 controls in one flat list and hunting for one by memory of the
	# code order is hopeless. The system tag that opens every HELP line carries the grouping that
	# alphabetical order throws away.
	var ordered := _specs.duplicate()
	ordered.sort_custom(func(a, b): return String(a[0]).naturalnocasecmp_to(String(b[0])) < 0)
	for s in ordered:
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
	_wire_help(name_lbl, prop)
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
	_wire_help(slider, prop)
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
	_wire_help(btn, prop)
	vbox.add_child(btn)
	btn.set_meta("prop", prop)

func _wire_help(ctl: Control, prop: String) -> void:
	# Hovering a control writes its explanation into the banner. Labels ignore the mouse by
	# default, so they have to be told to accept it or hovering the NAME would do nothing -
	# which is the half of the row people actually point at when they are asking "what is this?".
	var text: String = HELP.get(prop, "")
	if text == "":
		return
	ctl.mouse_filter = Control.MOUSE_FILTER_STOP
	ctl.tooltip_text = text
	ctl.mouse_entered.connect(func(): _help_lbl.text = text)
	ctl.mouse_exited.connect(func():
		if _help_lbl.text == text:
			_help_lbl.text = "Hover any control for an explanation.")

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
