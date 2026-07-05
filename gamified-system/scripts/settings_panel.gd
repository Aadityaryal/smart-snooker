# res://scripts/settings_panel.gd
# ─────────────────────────────────────────────────────────────────────────────
# Reusable settings controls, built as a VBoxContainer so it can be dropped into
# BOTH the standalone Settings screen AND the in-game pause overlay (table.gd).
# Everything reads/writes the Globals autoload and persists immediately, so a change
# made mid-match takes effect on the very next recommendation.
#
# Contains: player name, on-table assist level, full-assist overlay toggles,
# AI opponent difficulty, and a two-click "reset progress".
# ─────────────────────────────────────────────────────────────────────────────
extends VBoxContainer

signal progress_reset            # emitted after XP/rank are wiped
signal name_changed(new_name: String)

var _assist_opt:   OptionButton
var _diff_opt:     OptionButton
var _name_edit:    LineEdit
var _reset_btn:    Button
var _reset_armed:  bool = false


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	custom_minimum_size = Vector2(520.0, 0.0)

	# ── Player name ───────────────────────────────────────────────────────────
	_mk_section("Player name")
	_name_edit = LineEdit.new()
	_name_edit.text = Globals.player_name
	_name_edit.placeholder_text = "Your name"
	_name_edit.max_length = 24
	_name_edit.custom_minimum_size = Vector2(320.0, 0.0)
	_name_edit.text_changed.connect(_on_name_changed)
	_name_edit.text_submitted.connect(func(_t: String) -> void: Globals.save_progress())
	_name_edit.focus_exited.connect(func() -> void: Globals.save_progress())
	add_child(_name_edit)

	# ── On-table assist level ─────────────────────────────────────────────────
	_mk_section("On-table assist")
	_assist_opt = OptionButton.new()
	_assist_opt.add_item("Off — no guidance",                    Globals.ASSIST_OFF)
	_assist_opt.add_item("Hint — aim line + confidence only",    Globals.ASSIST_HINT)
	_assist_opt.add_item("Full — heatmap, alternatives, landing", Globals.ASSIST_FULL)
	_assist_opt.selected = _assist_opt.get_item_index(Globals.assist_level)
	_assist_opt.item_selected.connect(_on_assist_selected)
	add_child(_assist_opt)

	# ── Full-assist overlay elements ──────────────────────────────────────────
	_mk_section("Full-assist overlay elements")
	_mk_check("Ball makeability heatmap",   Globals.show_heatmap,      _on_heatmap_toggled)
	_mk_check("Ranked alternative shots",   Globals.show_alternatives, _on_alts_toggled)
	_mk_check("Predicted cue-ball landing", Globals.show_landing,      _on_landing_toggled)

	# ── AI opponent difficulty ────────────────────────────────────────────────
	_mk_section("AI opponent difficulty")
	_diff_opt = OptionButton.new()
	_diff_opt.add_item("Easy",   Globals.AI_EASY)
	_diff_opt.add_item("Medium", Globals.AI_MEDIUM)
	_diff_opt.add_item("Hard",   Globals.AI_HARD)
	_diff_opt.selected = _diff_opt.get_item_index(Globals.ai_difficulty_level)
	_diff_opt.item_selected.connect(_on_diff_selected)
	add_child(_diff_opt)

	# ── Reset progress (two-click confirm) ────────────────────────────────────
	_mk_section("Progress")
	_reset_btn = Button.new()
	_reset_btn.text = "Reset progress (XP & rank)"
	_reset_btn.custom_minimum_size = Vector2(320.0, 40.0)
	_reset_btn.pressed.connect(_on_reset_pressed)
	add_child(_reset_btn)


# ── Change handlers (all persist immediately) ─────────────────────────────────
func _on_name_changed(new_text: String) -> void:
	var n := new_text.strip_edges()
	Globals.player_name = n if not n.is_empty() else "Player"
	name_changed.emit(Globals.player_name)

func _on_assist_selected(idx: int) -> void:
	Globals.assist_level = _assist_opt.get_item_id(idx)
	Globals.save_progress()

func _on_diff_selected(idx: int) -> void:
	Globals.ai_difficulty_level = _diff_opt.get_item_id(idx)
	Globals.save_progress()

func _on_heatmap_toggled(on: bool) -> void:
	Globals.show_heatmap = on
	Globals.save_progress()

func _on_alts_toggled(on: bool) -> void:
	Globals.show_alternatives = on
	Globals.save_progress()

func _on_landing_toggled(on: bool) -> void:
	Globals.show_landing = on
	Globals.save_progress()

func _on_reset_pressed() -> void:
	if not _reset_armed:
		_reset_armed = true
		_reset_btn.text = "Are you sure?  Click again to reset"
		return
	Globals.reset_progress()
	_reset_armed = false
	_reset_btn.text = "Progress reset ✓"
	progress_reset.emit()


# ── Builders ──────────────────────────────────────────────────────────────────
func _mk_section(txt: String) -> void:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	add_child(l)


func _mk_check(txt: String, on: bool, cb: Callable) -> void:
	var c := CheckBox.new()
	c.text = txt
	c.button_pressed = on
	c.add_theme_font_size_override("font_size", 16)
	c.toggled.connect(cb)
	add_child(c)
