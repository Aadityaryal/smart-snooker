# res://scripts/control_band.gd
# ─────────────────────────────────────────────────────────────────────────────
# Off-table control band (bottom strip of the window, below the table).
#
# This is the "hands" of the game — the human interaction layer the ML brain was
# missing. It owns everything the player sets BEFORE striking:
#   • POWER gauge     — draggable bar, 0-100 %, decoupled from aim
#   • SPIN dial       — cue-ball english (side + top/back), interactive
#   • action buttons  — Play AI Shot / Shoot (Space) / Place Cue (ball in hand)
#   • AI summary      — what the recommender suggests (target, pocket, power, conf)
#
# It is screen-space (CanvasLayer) so it never moves with the table, and every
# control STOPs its own mouse input so clicking a control never fires a shot.
# table.gd drives the felt; this drives the rail.
# ─────────────────────────────────────────────────────────────────────────────
extends CanvasLayer

signal power_changed(frac: float)
signal spin_changed(new_spin: Vector2)
signal shoot_pressed
signal play_ai_pressed
signal place_cue_pressed
signal lock_aim_pressed

const BAND_TOP: float = 720.0
const BAND_W:   float = 1280.0
const BAND_H:   float = 220.0

var _power_bar:  _PowerBar = null
var _power_lbl:  Label = null
var _spin_dial:  _SpinPad = null
var _ai_lbl:     Label = null
var _status_lbl: Label = null
var _lock_btn:   Button = null


func _ready() -> void:
	layer = 20

	var bg := Panel.new()
	bg.position = Vector2(0.0, BAND_TOP)
	bg.size = Vector2(BAND_W, BAND_H)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.11, 1.0)
	sb.border_color = Color(0.20, 0.24, 0.28, 1.0)
	sb.border_width_top = 2
	bg.add_theme_stylebox_override("panel", sb)
	add_child(bg)

	# ── Column A: POWER ──────────────────────────────────────────────────────
	_mk_caption("POWER", Vector2(24.0, BAND_TOP + 14.0))
	_power_bar = _PowerBar.new()
	_power_bar.position = Vector2(24.0, BAND_TOP + 42.0)
	_power_bar.size = Vector2(370.0, 40.0)
	_power_bar.changed.connect(func(f: float) -> void: power_changed.emit(f))
	add_child(_power_bar)

	_power_lbl = _mk_label(Vector2(24.0, BAND_TOP + 90.0), 380.0, 30)
	_power_lbl.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
	_power_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_power_lbl.text = "35%"

	var hint := _mk_label(Vector2(24.0, BAND_TOP + 128.0), 380.0, 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.66, 0.72))
	hint.text = "scroll over table • drag this bar • or pull the cue back"

	# ── Column B: SPIN ───────────────────────────────────────────────────────
	_mk_caption("SPIN  (english)", Vector2(452.0, BAND_TOP + 14.0))
	_spin_dial = _SpinPad.new()
	_spin_dial.position = Vector2(452.0, BAND_TOP + 44.0)
	_spin_dial.size = Vector2(128.0, 128.0)
	_spin_dial.spin_changed.connect(func(v: Vector2) -> void: spin_changed.emit(v))
	add_child(_spin_dial)

	# ── Column C: ACTIONS ────────────────────────────────────────────────────
	var b_ai := _mk_button("▶  Play AI Shot", Vector2(636.0, BAND_TOP + 26.0), Vector2(250.0, 40.0),
		Color(0.16, 0.45, 0.72))
	b_ai.pressed.connect(func() -> void: play_ai_pressed.emit())
	_lock_btn = _mk_button("🔓  Aim: free", Vector2(636.0, BAND_TOP + 70.0), Vector2(250.0, 40.0),
		Color(0.42, 0.30, 0.52))
	_lock_btn.pressed.connect(func() -> void: lock_aim_pressed.emit())
	var b_shoot := _mk_button("●  Shoot   (Space)", Vector2(636.0, BAND_TOP + 114.0), Vector2(250.0, 40.0),
		Color(0.20, 0.55, 0.28))
	b_shoot.pressed.connect(func() -> void: shoot_pressed.emit())
	var b_place := _mk_button("✋  Place Cue (ball in hand)", Vector2(636.0, BAND_TOP + 158.0), Vector2(250.0, 38.0),
		Color(0.42, 0.34, 0.16))
	b_place.pressed.connect(func() -> void: place_cue_pressed.emit())

	# ── Column D: AI SUMMARY ─────────────────────────────────────────────────
	_ai_lbl = _mk_label(Vector2(912.0, BAND_TOP + 14.0), 350.0, 15)
	_ai_lbl.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))
	_ai_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ai_lbl.text = "AI SUGGESTS —\nwaiting for the recommendation server…"

	# ── Status line (placement prompts, etc.) ────────────────────────────────
	_status_lbl = _mk_label(Vector2(24.0, BAND_TOP + 150.0), 590.0, 14)
	_status_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.text = ""


# ── Public API (table.gd calls these) ─────────────────────────────────────────
func set_power_display(frac: float) -> void:
	if _power_bar != null: _power_bar.set_frac(frac)
	if _power_lbl != null: _power_lbl.text = "%.0f%%" % (clampf(frac, 0.0, 1.0) * 100.0)


func set_spin_display(v: Vector2) -> void:
	if _spin_dial != null: _spin_dial.set_spin(v)


func set_status(txt: String) -> void:
	if _status_lbl != null: _status_lbl.text = txt


func set_aim_lock_display(locked: bool) -> void:
	if _lock_btn == null: return
	_lock_btn.text = "🔒  Aim LOCKED" if locked else "🔓  Aim: free"
	# Tint green when locked so the state is unmistakable at a glance.
	_lock_btn.modulate = Color(0.75, 1.35, 0.85) if locked else Color(1.0, 1.0, 1.0)


func show_recommendation(data: Dictionary) -> void:
	if _ai_lbl == null: return
	var mode := str(data.get("mode", "pot"))
	var shot_v: Variant = data.get("recommended_shot")
	if mode == "none" or typeof(shot_v) != TYPE_DICTIONARY:
		_ai_lbl.text = "AI SUGGESTS —\n" + str(data.get("coaching", "No legal shot."))
		return
	var shot: Dictionary = shot_v
	var colr := str(shot.get("target_colour", "ball")).capitalize()
	var pk := str(shot.get("pocket", "")).replace("_", " ")
	var conf := float(shot.get("confidence", 0.0))
	var pw := float(shot.get("force", 0.0)) * 100.0
	var head := "PLAY SAFE" if mode == "safety" else "POT the " + colr
	_ai_lbl.text = ("AI SUGGESTS — %s\nPocket: %s\nConfidence: %.0f%%\nPower: %.0f%%\n\n%s"
		% [head, pk, conf, pw, str(data.get("coaching", ""))])


# ── Builders ──────────────────────────────────────────────────────────────────
func _mk_caption(txt: String, pos: Vector2) -> Label:
	var l := _mk_label(pos, 380.0, 15)
	l.add_theme_color_override("font_color", Color(0.55, 0.62, 0.7))
	l.text = txt
	return l


func _mk_label(pos: Vector2, w: float, fsize: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.size = Vector2(w, 0.0)
	l.custom_minimum_size = Vector2(w, 0.0)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", fsize)
	add_child(l)
	return l


func _mk_button(txt: String, pos: Vector2, sz: Vector2, col: Color) -> Button:
	var b := Button.new()
	b.text = txt
	b.position = pos
	b.size = sz
	b.custom_minimum_size = sz
	b.focus_mode = Control.FOCUS_NONE            # so Space reaches the table, not the button
	b.add_theme_font_size_override("font_size", 17)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(6)
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = col.lightened(0.15)
	var sb_p := sb.duplicate() as StyleBoxFlat
	sb_p.bg_color = col.darkened(0.15)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb_h)
	b.add_theme_stylebox_override("pressed", sb_p)
	add_child(b)
	return b


# ═════════════════════════════════════════════════════════════════════════════
# Draggable horizontal power gauge
# ═════════════════════════════════════════════════════════════════════════════
class _PowerBar extends Control:
	signal changed(frac: float)
	var frac: float = 0.35
	var _drag: bool = false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func set_frac(f: float) -> void:
		frac = clampf(f, 0.0, 1.0)
		queue_redraw()

	func _colour(f: float) -> Color:
		# green (soft) → yellow → red (hard)
		if f < 0.5: return Color(0.3, 0.9, 0.4).lerp(Color(0.95, 0.85, 0.2), f / 0.5)
		return Color(0.95, 0.85, 0.2).lerp(Color(0.95, 0.35, 0.3), (f - 0.5) / 0.5)

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0.0, 0.0, w, h), Color(0.12, 0.14, 0.17, 1.0))
		draw_rect(Rect2(0.0, 0.0, w * frac, h), _colour(frac))
		for i: int in range(1, 10):
			var x := w * float(i) / 10.0
			draw_line(Vector2(x, 0.0), Vector2(x, h), Color(0.0, 0.0, 0.0, 0.25), 1.0)
		draw_rect(Rect2(0.0, 0.0, w, h), Color(1.0, 1.0, 1.0, 0.5), false, 1.5)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_drag = true; _set_from_x(event.position.x); accept_event()
			elif _drag:
				_drag = false; accept_event()
		elif event is InputEventMouseMotion and _drag:
			_set_from_x(event.position.x); accept_event()

	func _set_from_x(x: float) -> void:
		frac = clampf(x / size.x, 0.0, 1.0)
		changed.emit(frac)
		queue_redraw()


# ═════════════════════════════════════════════════════════════════════════════
# Interactive spin dial (cue-ball english). Emits SCREEN-space spin (y down);
# table.gd negates y so the top of the dial = follow (top spin).
# ═════════════════════════════════════════════════════════════════════════════
class _SpinPad extends Control:
	signal spin_changed(new_spin: Vector2)
	var _radius: float = 58.0
	var _spin: Vector2 = Vector2.ZERO
	var _drag: bool = false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func set_spin(v: Vector2) -> void:
		_spin = v.limit_length(1.0)
		queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		draw_circle(c, _radius, Color(0.9, 0.9, 0.95, 0.14))
		for i: int in range(64):
			var a1 := float(i) / 64.0 * TAU
			var a2 := float(i + 1) / 64.0 * TAU
			draw_line(c + Vector2(cos(a1), sin(a1)) * _radius,
					  c + Vector2(cos(a2), sin(a2)) * _radius, Color(1, 1, 1, 0.55), 1.5)
		draw_line(c + Vector2(-_radius, 0), c + Vector2(_radius, 0), Color(1, 1, 1, 0.15), 1.0)
		draw_line(c + Vector2(0, -_radius), c + Vector2(0, _radius), Color(1, 1, 1, 0.15), 1.0)
		var dot := c + _spin * _radius
		draw_circle(dot, 6.0, Color(1.0, 0.3, 0.3, 0.95))
		draw_line(dot + Vector2(-9, 0), dot + Vector2(9, 0), Color(1, 0.3, 0.3, 0.9), 2.0)
		draw_line(dot + Vector2(0, -9), dot + Vector2(0, 9), Color(1, 0.3, 0.3, 0.9), 2.0)

	func _gui_input(event: InputEvent) -> void:
		var c := size / 2.0
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			var lp: Vector2 = event.position - c
			if event.pressed and lp.length() <= _radius:
				_drag = true; _update(lp); accept_event()
			elif not event.pressed and _drag:
				_drag = false; accept_event()
		elif event is InputEventMouseMotion and _drag:
			_update(event.position - c); accept_event()

	func _update(lp: Vector2) -> void:
		_spin = lp.limit_length(_radius) / _radius
		spin_changed.emit(_spin)
		queue_redraw()
