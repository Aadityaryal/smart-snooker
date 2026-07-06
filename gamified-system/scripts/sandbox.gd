# res://scripts/sandbox.gd
# ─────────────────────────────────────────────────────────────────────────────
# Scenario Sandbox — "Ask the Coach".
#
# Place / drag any balls into any position, then press Recommend. The full table
# state is sent to the SAME recommendation server the game uses, and the SAME
# overlay draws the answer (aim line, ghost ball, pocket, cue-landing, heatmap,
# ranked alternatives, coaching). Zero new ML — it reuses api_bridge.gd + overlay.gd
# and just lets you build arbitrary positions to interrogate the recommender.
#
# It draws its own simple table in the SAME coordinate space (0,0 → TABLE_W×TABLE_H)
# the overlay maps into, so the overlay lines land exactly on the balls.
# ─────────────────────────────────────────────────────────────────────────────
extends Node2D

const BALL_R: float = 15.0
const COLOUR_CYCLE: Array[String] = ["yellow", "green", "brown", "blue", "pink", "black"]

var _api_bridge: Node = null
var _overlay:    Node = null

var _balls: Array = []            # every ball incl. cue (each a _BallNode)
var _next_id: int = 1
var _dragging: Node = null
var _colour_idx: int = 0
var _must_pot_colour: bool = false

var _status_lbl: Label = null
var _info_lbl:   Label = null
var _mpc_btn:    Button = null


func _ready() -> void:
	# Reuse the real recommendation bridge + overlay.
	_api_bridge = preload("res://scripts/api_bridge.gd").new()
	_api_bridge.name = "ApiBridge"
	_api_bridge.recommendation_ready.connect(_on_recommendation_ready)
	_api_bridge.recommendation_failed.connect(_on_recommendation_failed)
	add_child(_api_bridge)

	_overlay = preload("res://scripts/overlay.gd").new()
	_overlay.name = "Overlay"
	_overlay.force_full = true          # sandbox always shows the whole picture
	add_child(_overlay)

	_build_ui()
	_reset_default_layout()
	queue_redraw()


# ── Table drawing (same space the overlay maps into) ──────────────────────────
func _draw() -> void:
	var w := Globals.TABLE_W
	var h := Globals.TABLE_H
	# Full-window dark backdrop so the area outside the felt isn't default gray.
	draw_rect(Rect2(-40.0, -40.0, w + 400.0, h + 400.0), Color(0.07, 0.09, 0.11))
	# Felt + cushion frame.
	draw_rect(Rect2(-14.0, -14.0, w + 28.0, h + 28.0), Color(0.19, 0.12, 0.06))     # rail
	draw_rect(Rect2(0.0, 0.0, w, h), Color(0.08, 0.45, 0.22))                        # felt
	# Baulk line + D.
	draw_line(Vector2(Globals.BAULK_X, 0.0), Vector2(Globals.BAULK_X, h), Color(1, 1, 1, 0.25), 1.5)
	draw_arc(Vector2(Globals.BAULK_X, Globals.D_CENTER_Y), Globals.D_RADIUS,
			 PI * 0.5, PI * 1.5, 32, Color(1, 1, 1, 0.25), 1.5)
	# Pockets.
	for p: Vector2 in Globals.POCKET_POSITIONS:
		draw_circle(p, Globals.POCKET_RADIUS, Color(0.02, 0.02, 0.02, 0.95))


# ── Default rack: cue in the D + a few reds + colours to interrogate ──────────
func _reset_default_layout() -> void:
	_clear_all_balls()
	_add_ball("cue", Vector2(Globals.BAULK_X - 40.0, Globals.D_CENTER_Y))
	_add_ball("red", Vector2(820.0, 330.0))
	_add_ball("red", Vector2(850.0, 360.0))
	_add_ball("red", Vector2(820.0, 390.0))
	_add_ball("black", Vector2(1085.0, 360.0))
	_add_ball("pink", Vector2(915.0, 360.0))
	_add_ball("blue", Vector2(610.0, 360.0))
	_refresh_info()


func _clear_all_balls() -> void:
	for b: Node in _balls:
		b.queue_free()
	_balls.clear()
	_next_id = 1
	if _overlay != null and _overlay.has_method("apply_recommendation"):
		_overlay.apply_recommendation({"mode": "none", "recommended_shot": null})


func _add_ball(colour: String, pos: Vector2) -> void:
	var b := _BallNode.new()
	b.colour = colour
	b.col = _colour_of(colour)
	b.radius = BALL_R
	b.ball_id = _next_id
	_next_id += 1
	b.position = pos
	add_child(b)
	_balls.append(b)


func _colour_of(colour: String) -> Color:
	match colour:
		"cue":    return Color(0.96, 0.96, 0.96)
		"red":    return Color(0.85, 0.15, 0.12)
		"yellow": return Color(0.95, 0.85, 0.20)
		"green":  return Color(0.15, 0.60, 0.25)
		"brown":  return Color(0.50, 0.32, 0.15)
		"blue":   return Color(0.20, 0.42, 0.85)
		"pink":   return Color(0.95, 0.55, 0.62)
		"black":  return Color(0.10, 0.10, 0.12)
	return Color.WHITE


# ── Dragging ──────────────────────────────────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = _ball_at(get_global_mouse_position())
		else:
			_dragging = null
	elif event is InputEventMouseMotion and _dragging != null:
		var p := get_global_mouse_position()
		p.x = clampf(p.x, BALL_R, Globals.TABLE_W - BALL_R)
		p.y = clampf(p.y, BALL_R, Globals.TABLE_H - BALL_R)
		_dragging.position = p


func _ball_at(p: Vector2) -> Node:
	var hit: Node = null
	for b: Node in _balls:
		if p.distance_to(b.position) <= BALL_R + 6.0:
			hit = b          # later entries draw on top, so keep the last match
	return hit


# ── Ask the recommender ───────────────────────────────────────────────────────
func _on_recommend_pressed() -> void:
	var cue_pos := Vector2(Globals.BAULK_X, Globals.D_CENTER_Y)
	var objects: Array = []
	var reds := 0
	for b: Node in _balls:
		if b.colour == "cue":
			cue_pos = b.position
			continue
		if b.colour == "red":
			reds += 1
		objects.append({"pos": b.position, "colour": b.colour, "id": b.ball_id})
	if objects.is_empty():
		_status_lbl.text = "Add at least one object ball, then Recommend."
		return
	_status_lbl.text = "Asking the coach…"
	_api_bridge.request_full_recommendation(cue_pos, objects, reds, _must_pot_colour)


func _on_recommendation_ready(data: Dictionary) -> void:
	if _overlay != null:
		_overlay.apply_recommendation(data)
	var mode := str(data.get("mode", "pot"))
	var coaching := str(data.get("coaching", ""))
	_status_lbl.text = ("[%s]  %s" % [mode.to_upper(), coaching]) if coaching != "" else ("Mode: " + mode)


func _on_recommendation_failed(reason: String) -> void:
	_status_lbl.text = "⚠ ML server offline — run ./run_smart_snooker.sh (see server.log).  [" + reason + "]"


# ── UI ────────────────────────────────────────────────────────────────────────
func _build_ui() -> void:
	var ui := CanvasLayer.new()
	ui.layer = 20
	add_child(ui)

	var y := Globals.TABLE_H + 18.0

	var title := _mk_label(ui, Vector2(20.0, y - 8.0), 900.0, 24)
	title.add_theme_color_override("font_color", Color(0.55, 0.95, 0.7))
	title.text = "Scenario Sandbox"

	var subtitle := _mk_label(ui, Vector2(20.0, y + 22.0), 1000.0, 15)
	subtitle.add_theme_color_override("font_color", Color(0.7, 0.78, 0.85))
	subtitle.text = "Drag any ball to build a position, then press Recommend to see the AI's suggested shot, its reasoning, and the makeability of every ball."
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.custom_minimum_size = Vector2(1000.0, 0.0)

	var by := y + 52.0
	_mk_button(ui, "🎯  Recommend", Vector2(20.0, by), Vector2(180.0, 44.0),
		Color(0.16, 0.45, 0.72), _on_recommend_pressed)
	_mk_button(ui, "+ Red", Vector2(212.0, by), Vector2(96.0, 44.0),
		Color(0.55, 0.18, 0.16), _on_add_red)
	_mk_button(ui, "+ Colour", Vector2(316.0, by), Vector2(120.0, 44.0),
		Color(0.30, 0.45, 0.30), _on_add_colour)
	_mk_button(ui, "Clear", Vector2(444.0, by), Vector2(96.0, 44.0),
		Color(0.35, 0.30, 0.16), _on_clear_pressed)
	_mk_button(ui, "Reset", Vector2(548.0, by), Vector2(96.0, 44.0),
		Color(0.30, 0.32, 0.38), _on_reset_pressed)
	_mpc_btn = _mk_button(ui, "Must-pot colour: OFF", Vector2(652.0, by), Vector2(220.0, 44.0),
		Color(0.36, 0.30, 0.50), _on_toggle_mpc)
	_mk_button(ui, "←  Menu", Vector2(884.0, by), Vector2(120.0, 44.0),
		Color(0.28, 0.30, 0.34), _on_menu_pressed)

	_info_lbl = _mk_label(ui, Vector2(20.0, by + 52.0), 500.0, 14)
	_info_lbl.add_theme_color_override("font_color", Color(0.70, 0.78, 0.85))

	_status_lbl = _mk_label(ui, Vector2(20.0, by + 74.0), 1000.0, 15)
	_status_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.7))
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.custom_minimum_size = Vector2(1000.0, 0.0)
	_status_lbl.text = "Drag any ball. Add balls with the buttons. Then press Recommend."


func _on_add_red() -> void:
	_add_ball("red", Vector2(Globals.TABLE_W * 0.5, Globals.TABLE_H * 0.5))
	_refresh_info()

func _on_add_colour() -> void:
	var c := COLOUR_CYCLE[_colour_idx % COLOUR_CYCLE.size()]
	_colour_idx += 1
	_add_ball(c, Vector2(Globals.TABLE_W * 0.5, Globals.TABLE_H * 0.5 + 40.0))
	_refresh_info()

func _on_clear_pressed() -> void:
	_clear_all_balls()
	_add_ball("cue", Vector2(Globals.BAULK_X - 40.0, Globals.D_CENTER_Y))
	_refresh_info()
	_status_lbl.text = "Cleared. Add object balls, then Recommend."

func _on_reset_pressed() -> void:
	_reset_default_layout()
	if _overlay != null:
		_overlay.apply_recommendation({"mode": "none", "recommended_shot": null})
	_status_lbl.text = "Reset to the default position."

func _on_toggle_mpc() -> void:
	_must_pot_colour = not _must_pot_colour
	if _mpc_btn != null:
		_mpc_btn.text = "Must-pot colour: " + ("ON" if _must_pot_colour else "OFF")

func _on_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _refresh_info() -> void:
	var reds := 0
	var others := 0
	for b: Node in _balls:
		if b.colour == "red": reds += 1
		elif b.colour != "cue": others += 1
	if _info_lbl != null:
		_info_lbl.text = "On table:  %d red  •  %d colour  (reds_remaining sent = %d)" % [reds, others, reds]


func _mk_label(parent: Node, pos: Vector2, w: float, fsize: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.custom_minimum_size = Vector2(w, 0.0)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", fsize)
	parent.add_child(l)
	return l


func _mk_button(parent: Node, txt: String, pos: Vector2, sz: Vector2,
		col: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = txt
	b.position = pos
	b.size = sz
	b.custom_minimum_size = sz
	b.add_theme_font_size_override("font_size", 15)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(6)
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = col.lightened(0.15)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb_h)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


# ═════════════════════════════════════════════════════════════════════════════
# A draggable ball: a coloured disc drawn in its own local space.
# ═════════════════════════════════════════════════════════════════════════════
class _BallNode extends Node2D:
	var colour: String = "red"
	var ball_id: int = 0
	var radius: float = 15.0
	var col: Color = Color.WHITE

	func _ready() -> void:
		z_index = 500
		queue_redraw()

	func _draw() -> void:
		draw_circle(Vector2.ZERO, radius, col)
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 24, Color(0, 0, 0, 0.45), 1.5)
		draw_circle(Vector2(-radius * 0.3, -radius * 0.3), radius * 0.28, Color(1, 1, 1, 0.35))
		# Label the cue ball so it's unmistakable which one the shot starts from.
		if colour == "cue":
			var font := ThemeDB.fallback_font
			if font != null:
				draw_string(font, Vector2(-13.0, -radius - 6.0), "CUE",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.9, 0.95, 1.0))
