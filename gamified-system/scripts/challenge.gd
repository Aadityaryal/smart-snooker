# res://scripts/challenge.gd
# ─────────────────────────────────────────────────────────────────────────────
# SHOT CHALLENGE — a VISUAL snooker-reading quiz.
#
# The player sees a real felt table with the cue ball and a target red placed at
# random positions, and must pick which of four pockets gives the highest-percentage
# pot. On answering, the correct line is drawn on the table and the reasoning shown.
#
# Preserved from the earlier version (still the heart of the quiz):
#   • correct_answer is GEOMETRIC, not random — _compute_best_pocket_idx derives it
#     from the cue/red geometry (old FIX L1). The weighting was CORRECTED this pass so
#     the cut angle properly dominates distance (the old formula could call a 60° cut
#     "best" over a near-straight pot); see that function's note. It now scores
#     independently of api_bridge, which still carries the old weak weighting.
#   • XP goes through Globals.add_xp() so it persists across scenes (old FIX L2).
#
# Rebuilt (this pass): the abstract "(34%, 62%)" text became a drawn felt table with
# the balls, pockets, and — after answering — the target→pocket line and pocket
# highlights. The old runtime-anchor bug that clipped everything to the top-left is
# gone (this scene now draws in world space + a bottom control strip).
# ─────────────────────────────────────────────────────────────────────────────
extends Node2D

# ── Pocket names aligned with Globals.POCKET_POSITIONS indices ────────────────
const POCKET_DISPLAY_NAMES: Array[String] = [
	"Top Left",     # index 0 — Globals.POCKET_POSITIONS[0]  (35, 35)
	"Top Middle",   # index 1 — (640, 35)
	"Top Right",    # index 2 — (1245, 35)
	"Bottom Left",  # index 3 — (35, 685)
	"Bottom Middle",# index 4 — (640, 685)
	"Bottom Right", # index 5 — (1245, 685)
]

const XP_PER_CORRECT: int = 20

# ── Table drawing transform (scaled to leave room for the control strip) ──────
const T_ORIGIN: Vector2 = Vector2(196.0, 46.0)
const T_SCALE:  float   = 0.72
const BALL_R:   float   = 13.0

var correct_answer_index: int = 0
var option_buttons: Array[Button] = []
var _option_pocket_idx: Array[int] = []
var result_label:   Label = null
var _question_label: Label = null
var _stats_label:    Label = null
var _next_btn:       Button = null

# Current question state
var _cue_pos:            Vector2 = Vector2.ZERO
var _target_pos:         Vector2 = Vector2.ZERO
var _correct_pocket_idx: int     = 0
var _answered:           bool    = false
var _chosen_pocket_idx:  int     = -1


# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_build_ui()
	_generate_question()


# ── World transform: table coords (0..TABLE_W, 0..TABLE_H) → screen ───────────
func _t(p: Vector2) -> Vector2:
	return T_ORIGIN + p * T_SCALE


# ═════════════════════════════════════════════════════════════════════════════
# Drawing — felt table, balls, and (once answered) the answer line + pockets
# ═════════════════════════════════════════════════════════════════════════════
func _draw() -> void:
	# Full-window dark backdrop so nothing shows the default gray.
	draw_rect(Rect2(0.0, 0.0, 1280.0, 940.0), Color(0.07, 0.09, 0.11))

	var w := Globals.TABLE_W * T_SCALE
	var h := Globals.TABLE_H * T_SCALE
	# Rail + felt.
	draw_rect(Rect2(T_ORIGIN - Vector2(16.0, 16.0), Vector2(w + 32.0, h + 32.0)), Color(0.19, 0.12, 0.06))
	draw_rect(Rect2(T_ORIGIN, Vector2(w, h)), Color(0.08, 0.45, 0.22))
	# Baulk line + D.
	var baulk_top := _t(Vector2(Globals.BAULK_X, 0.0))
	var baulk_bot := _t(Vector2(Globals.BAULK_X, Globals.TABLE_H))
	draw_line(baulk_top, baulk_bot, Color(1, 1, 1, 0.22), 1.5)
	draw_arc(_t(Vector2(Globals.BAULK_X, Globals.D_CENTER_Y)), Globals.D_RADIUS * T_SCALE,
			 PI * 0.5, PI * 1.5, 32, Color(1, 1, 1, 0.22), 1.5)
	# Pockets, numbered so the player can map them to the option buttons.
	var font := ThemeDB.fallback_font
	for i: int in range(Globals.POCKET_POSITIONS.size()):
		var pk := _t(Globals.POCKET_POSITIONS[i])
		draw_circle(pk, Globals.POCKET_RADIUS * T_SCALE, Color(0.02, 0.02, 0.02, 0.95))

	# The answer overlay (only after the player has picked).
	if _answered:
		var tgt := _t(_target_pos)
		var correct_pk := _t(Globals.POCKET_POSITIONS[_correct_pocket_idx])
		# Faint red line to the pocket the player chose, if they were wrong.
		if _chosen_pocket_idx >= 0 and _chosen_pocket_idx != _correct_pocket_idx:
			var chosen_pk := _t(Globals.POCKET_POSITIONS[_chosen_pocket_idx])
			draw_line(tgt, chosen_pk, Color(1.0, 0.35, 0.3, 0.55), 2.0)
			draw_arc(chosen_pk, 15.0, 0.0, TAU, 28, Color(1.0, 0.35, 0.3, 0.9), 3.0)
		# The correct line, bright green.
		draw_line(tgt, correct_pk, Color(0.3, 1.0, 0.45, 0.9), 3.0)
		draw_arc(correct_pk, 17.0, 0.0, TAU, 32, Color(0.3, 1.0, 0.45, 0.95), 3.5)
		draw_circle(correct_pk, 6.0, Color(0.3, 1.0, 0.45, 0.95))

	# Cue ball (white) + target red, with small labels.
	var cue_s := _t(_cue_pos)
	var red_s := _t(_target_pos)
	draw_circle(cue_s, BALL_R, Color(0.97, 0.97, 0.97))
	draw_arc(cue_s, BALL_R, 0.0, TAU, 24, Color(0, 0, 0, 0.4), 1.5)
	draw_circle(red_s, BALL_R, Color(0.85, 0.15, 0.12))
	draw_arc(red_s, BALL_R, 0.0, TAU, 24, Color(0, 0, 0, 0.4), 1.5)
	if font != null:
		draw_string(font, cue_s + Vector2(-14.0, -BALL_R - 6.0), "CUE",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.9, 0.95, 1.0))
		draw_string(font, red_s + Vector2(-14.0, -BALL_R - 6.0), "RED",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.7, 0.65))


# ═════════════════════════════════════════════════════════════════════════════
# UI construction — a bottom control strip below the table
# ═════════════════════════════════════════════════════════════════════════════
func _build_ui() -> void:
	var ui: CanvasLayer = CanvasLayer.new()
	ui.name = "HUD"
	add_child(ui)

	# Title.
	var title: Label = Label.new()
	title.text = "Shot Challenge"
	title.position = Vector2(0.0, 8.0)
	title.size = Vector2(1280.0, 34.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.55, 0.95, 0.7))
	ui.add_child(title)

	# XP / rank, top-right.
	_stats_label = Label.new()
	_stats_label.position = Vector2(940.0, 12.0)
	_stats_label.size = Vector2(320.0, 24.0)
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_stats_label.add_theme_font_size_override("font_size", 15)
	_stats_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.3))
	ui.add_child(_stats_label)

	# Question / instruction, just below the table.
	_question_label = Label.new()
	_question_label.position = Vector2(140.0, 574.0)
	_question_label.size = Vector2(1000.0, 30.0)
	_question_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_question_label.add_theme_font_size_override("font_size", 19)
	_question_label.add_theme_color_override("font_color", Color(0.9, 0.94, 0.98))
	ui.add_child(_question_label)

	# Four pocket-option buttons in a centred row.
	var row: HBoxContainer = HBoxContainer.new()
	row.position = Vector2(140.0, 616.0)
	row.size = Vector2(1000.0, 64.0)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	ui.add_child(row)
	for i: int in range(4):
		var button: Button = Button.new()
		button.custom_minimum_size = Vector2(232.0, 60.0)
		button.pressed.connect(_on_option_pressed.bind(i))
		row.add_child(button)
		option_buttons.append(button)
		_option_pocket_idx.append(0)

	# Result / reasoning.
	result_label = Label.new()
	result_label.position = Vector2(140.0, 700.0)
	result_label.size = Vector2(1000.0, 60.0)
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result_label.add_theme_font_size_override("font_size", 18)
	ui.add_child(result_label)

	# Next + Back, centred at the bottom.
	var nav: HBoxContainer = HBoxContainer.new()
	nav.position = Vector2(140.0, 772.0)
	nav.size = Vector2(1000.0, 52.0)
	nav.alignment = BoxContainer.ALIGNMENT_CENTER
	nav.add_theme_constant_override("separation", 20)
	ui.add_child(nav)

	_next_btn = Button.new()
	_next_btn.text = "Next Question  →"
	_next_btn.custom_minimum_size = Vector2(240.0, 48.0)
	_next_btn.pressed.connect(_generate_question)
	nav.add_child(_next_btn)

	var back_btn: Button = Button.new()
	back_btn.text = "←  Back to Menu"
	back_btn.custom_minimum_size = Vector2(240.0, 48.0)
	back_btn.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/menu.tscn")
	)
	nav.add_child(back_btn)


# ═════════════════════════════════════════════════════════════════════════════
# Question generation — correct answer from geometry (old FIX L1)
# ═════════════════════════════════════════════════════════════════════════════
func _generate_question() -> void:
	_answered = false
	_chosen_pocket_idx = -1

	# Random positions — cue on the left half, target on the right half. Retry until
	# the best pocket is a genuinely makeable pot (never quiz an impossible shot).
	for _try: int in range(24):
		_cue_pos = Vector2(
			randf_range(90.0, Globals.TABLE_W * 0.5),
			randf_range(90.0, Globals.TABLE_H - 90.0)
		)
		_target_pos = Vector2(
			randf_range(Globals.TABLE_W * 0.45, Globals.TABLE_W - 90.0),
			randf_range(90.0, Globals.TABLE_H - 90.0)
		)
		_correct_pocket_idx = _compute_best_pocket_idx(_cue_pos, _target_pos)
		if _cut_angle(_cue_pos, _target_pos, Globals.POCKET_POSITIONS[_correct_pocket_idx]) < 78.0:
			break
	var correct_text: String = "→ " + POCKET_DISPLAY_NAMES[_correct_pocket_idx]

	# Build a pool of 3 wrong pockets and shuffle into 4 total options.
	var wrong_idxs: Array[int] = []
	for i: int in range(POCKET_DISPLAY_NAMES.size()):
		if i != _correct_pocket_idx:
			wrong_idxs.append(i)
	wrong_idxs.shuffle()

	var option_pockets: Array[int] = [_correct_pocket_idx]
	for i: int in range(3):
		option_pockets.append(wrong_idxs[i])
	option_pockets.shuffle()

	# Assign to buttons; record where the correct option landed.
	for i: int in range(option_buttons.size()):
		var pidx: int = option_pockets[i]
		_option_pocket_idx[i] = pidx
		option_buttons[i].text     = "→ " + POCKET_DISPLAY_NAMES[pidx]
		option_buttons[i].disabled = false
		_clear_button_tint(option_buttons[i])
		if pidx == _correct_pocket_idx:
			correct_answer_index = i

	_question_label.text = "Which pocket gives the cue ball the highest-percentage pot on the red?"
	result_label.text = ""
	result_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	if _next_btn != null:
		_next_btn.disabled = true
	_refresh_stats()
	queue_redraw()


# ═════════════════════════════════════════════════════════════════════════════
# Answer handling
# ═════════════════════════════════════════════════════════════════════════════
func _on_option_pressed(button_index: int) -> void:
	if _answered:
		return
	_answered = true
	_chosen_pocket_idx = _option_pocket_idx[button_index]

	for button: Button in option_buttons:
		button.disabled = true

	var is_correct: bool = button_index == correct_answer_index
	_tint_button(option_buttons[button_index],
		Color(0.16, 0.45, 0.22) if is_correct else Color(0.5, 0.16, 0.14))
	# Always reveal the correct answer in green so the player learns.
	if not is_correct:
		_tint_button(option_buttons[correct_answer_index], Color(0.16, 0.45, 0.22))

	var reason := _reason_text(_correct_pocket_idx)
	if is_correct:
		result_label.text = "✓ Correct!   +%d XP\n%s" % [XP_PER_CORRECT, reason]
		result_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
		Globals.add_xp(XP_PER_CORRECT)   # persists across scenes (FIX L2)
	else:
		result_label.text = "✗ Best was %s.\n%s" % [POCKET_DISPLAY_NAMES[_correct_pocket_idx], reason]
		result_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.5))

	if _next_btn != null:
		_next_btn.disabled = false
	_refresh_stats()
	queue_redraw()


# A short, snooker-literate justification for the best pocket.
func _reason_text(pocket_idx: int) -> String:
	var p: Vector2 = Globals.POCKET_POSITIONS[pocket_idx]
	var dist: float = _target_pos.distance_to(p)
	var cut: float = _cut_angle(_cue_pos, _target_pos, p)
	var shape := "nearly straight"
	if cut >= 55.0:
		shape = "a thin cut"
	elif cut >= 35.0:
		shape = "a half-ball cut"
	elif cut >= 12.0:
		shape = "a shallow cut"
	return "%.0f px away, %s (%.0f°) — a shallower cut pots more reliably than a shorter but thinner one." % [dist, shape, cut]


func _refresh_stats() -> void:
	if _stats_label != null:
		_stats_label.text = "XP: %d   •   %s" % [Globals.total_xp, Globals.get_rank()]


# ── Button tinting via a stylebox override (survives the disabled state) ───────
func _tint_button(btn: Button, col: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10.0)
	sb.set_border_width_all(1)
	sb.border_color = col.lightened(0.25)
	for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(state, sb)
	btn.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.95))


func _clear_button_tint(btn: Button) -> void:
	for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
		btn.remove_theme_stylebox_override(state)
	btn.remove_theme_color_override("font_disabled_color")


# ═════════════════════════════════════════════════════════════════════════════
# Best-pocket scorer — picks the genuinely highest-percentage pot from the
# cue + red geometry.
#
# Pot difficulty is dominated by the CUT ANGLE, not distance: a shallow cut pots far
# more reliably than a thin one, and a thin cut (→90°) is essentially impossible. So
# the score is distance scaled by a STEEP, super-linear cut penalty (∝ 1-cos(cut)),
# and cuts near 90° are rejected outright.
#
# This deliberately weights the cut angle harder than the old `dist*0.6 + cut*2.0`
# formula, which could tie a 60° cut with a near-straight pot at longer range and
# then pick the 60° cut — a wrong, un-snooker-like "best pocket". (The same weak
# weighting still lives in api_bridge._find_best_pocket on the ML side; aligning it
# would be an engine change, so the quiz now scores independently and correctly.)
# Returns the index into Globals.POCKET_POSITIONS (and POCKET_DISPLAY_NAMES).
# ═════════════════════════════════════════════════════════════════════════════
func _compute_best_pocket_idx(cue_pos: Vector2, target_pos: Vector2) -> int:
	var best_idx:   int   = 0
	var best_score: float = INF
	for i: int in range(Globals.POCKET_POSITIONS.size()):
		var p:    Vector2 = Globals.POCKET_POSITIONS[i]
		var dist: float   = target_pos.distance_to(p)
		var cut:  float   = _cut_angle(cue_pos, target_pos, p)
		# Makeability falls off with cos(cut); scale distance by that steep penalty.
		var cut_factor: float = 1.0 + 4.0 * (1.0 - cos(deg_to_rad(cut)))
		var score: float = dist * cut_factor
		# A cut of ~85°+ (incl. anything the object ball would have to travel BACKWARD
		# relative to the cue's push) cannot be potted at all — take it off the table.
		if cut >= 85.0:
			score += 1.0e9
		if score < best_score:
			best_score = score
			best_idx   = i
	return best_idx


# TRUE cut angle in [0, 180]: the angle between the cue-ball travel line (cue→red)
# and the direction the object ball must travel (red→pocket). 0° = dead straight;
# 90° = the limit of a makeable pot; >90° means the pocket is "behind" the red
# relative to the cue's push, i.e. physically impossible. (The old code folded this
# into [0,90] with `180-cut`, which turned an impossible 163° shot into a fake easy
# 17° — the bug that made the quiz pick a pocket behind the red.)
func _cut_angle(cue_pos: Vector2, target_pos: Vector2, pocket: Vector2) -> float:
	var v1: Vector2 = target_pos - cue_pos          # cue-ball travel direction
	var v2: Vector2 = pocket - target_pos           # object-ball travel direction
	if v1.length() < 0.001 or v2.length() < 0.001:
		return 90.0
	var d: float = clampf(v1.normalized().dot(v2.normalized()), -1.0, 1.0)
	return rad_to_deg(acos(d))


# ─────────────────────────────────────────────────────────────────────────────
# Utility — ranks a list of shot option dicts by descending score.
# Kept unchanged for future RL integration.
# ─────────────────────────────────────────────────────────────────────────────
func rank_shot_options(options: Array[Dictionary]) -> Array[Dictionary]:
	var ranked: Array[Dictionary] = options.duplicate()
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)
	return ranked
