# res://scripts/drills.gd
# ─────────────────────────────────────────────────────────────────────────────
# FIX S1 — VBoxContainer had size_flags_vertical = SIZE_EXPAND_FILL inside a
#           ScrollContainer.  The child always equalled the container height,
#           so no overflow existed and scrolling never activated.
#           Removed the vertical flag so the VBoxContainer shrinks to its
#           content size; the ScrollContainer scrolls once content grows past it.
# ─────────────────────────────────────────────────────────────────────────────
extends Node2D

const DRILLS: Array[Dictionary] = [
	{
		"name":        "Straight Pot",
		"description": "Pot the red ball straight — zero cut angle. Build your basic technique.",
		"xp_reward":   10,
		"difficulty":  "Easy",
		"colour":      Color(0.35, 0.85, 0.35),
	},
	{
		"name":        "Thin Cut",
		"description": "Pot the red with a cut angle under 28°. Judge the contact point precisely.",
		"xp_reward":   20,
		"difficulty":  "Medium",
		"colour":      Color(0.85, 0.85, 0.25),
	},
	{
		"name":        "Medium Cut",
		"description": "Pot the red at 28–58° cut angle. Read the ghost-ball position.",
		"xp_reward":   30,
		"difficulty":  "Hard",
		"colour":      Color(0.95, 0.55, 0.15),
	},
	{
		"name":        "Heavy Cut",
		"description": "Pot the red at over 58° cut. Maximum precision required.",
		"xp_reward":   50,
		"difficulty":  "Expert",
		"colour":      Color(0.90, 0.25, 0.25),
	},
	{
		"name":        "Long Pot",
		"description": "Pot a red from more than half the table away. Control your pace.",
		"xp_reward":   40,
		"difficulty":  "Hard",
		"colour":      Color(0.95, 0.55, 0.15),
	},
]

const STREAK_BONUS_PER_POT: int = 5

var score:  int = 0
var streak: int = 0

var _score_label:  Label = null
var _rank_label:   Label = null
var _active_drill: int   = -1


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	var hud: CanvasLayer = CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)

	var root: Control = Control.new()
	# set_anchors_AND_OFFSETS_preset: anchors_preset alone sets anchors but leaves
	# offsets at 0, collapsing the root to size (0,0) so all content dumps at the
	# top-left, clipped. Setting offsets too makes it truly fill the window.
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	root.grow_vertical   = Control.GROW_DIRECTION_BOTH
	hud.add_child(root)

	# Dim charcoal backdrop so the drill list reads as a real screen, not floating text.
	var bg: ColorRect = ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.07, 0.09, 0.11, 1.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.grow_horizontal = Control.GROW_DIRECTION_BOTH
	scroll.grow_vertical   = Control.GROW_DIRECTION_BOTH
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var outer: VBoxContainer = VBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# FIX S1 — SIZE_EXPAND_FILL on vertical axis was removed.
	# VBoxContainer now shrinks to its content height; ScrollContainer
	# activates its vertical scrollbar once content exceeds the visible area.
	outer.alignment           = BoxContainer.ALIGNMENT_CENTER
	outer.add_theme_constant_override("separation", 14)
	outer.custom_minimum_size = Vector2(0, 600)
	scroll.add_child(outer)

	var title: Label = Label.new()
	title.text                = "Drills"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 38)
	outer.add_child(title)

	_score_label                      = Label.new()
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_score_label.add_theme_font_size_override("font_size", 18)
	_score_label.text = _score_text()
	outer.add_child(_score_label)

	_rank_label                      = Label.new()
	_rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rank_label.add_theme_font_size_override("font_size", 15)
	_rank_label.text = "Rank: " + Globals.get_rank()
	_rank_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.2))
	outer.add_child(_rank_label)

	var sep: HSeparator = HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 8)
	outer.add_child(sep)

	for i: int in range(DRILLS.size()):
		var d:   Dictionary    = DRILLS[i]
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		outer.add_child(row)

		var diff_lbl: Label = Label.new()
		diff_lbl.text                = "[%s]" % d["difficulty"]
		diff_lbl.custom_minimum_size = Vector2(80, 0)
		diff_lbl.add_theme_color_override("font_color", d["colour"])
		diff_lbl.vertical_alignment  = VERTICAL_ALIGNMENT_CENTER
		row.add_child(diff_lbl)

		var btn: Button = Button.new()
		btn.text                  = "%s   (+%d XP)" % [d["name"], d["xp_reward"]]
		btn.tooltip_text          = d["description"]
		btn.custom_minimum_size   = Vector2(460, 58)
		btn.pressed.connect(_on_drill_selected.bind(i))
		row.add_child(btn)

		var desc_lbl: Label = Label.new()
		desc_lbl.text               = d["description"]
		desc_lbl.custom_minimum_size = Vector2(380, 0)
		desc_lbl.autowrap_mode      = TextServer.AUTOWRAP_WORD
		desc_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		desc_lbl.add_theme_font_size_override("font_size", 13)
		desc_lbl.add_theme_color_override("font_color", Color(0.62, 0.67, 0.72))
		row.add_child(desc_lbl)

	var sep2: HSeparator = HSeparator.new()
	sep2.custom_minimum_size = Vector2(0, 8)
	outer.add_child(sep2)

	var back_btn: Button = Button.new()
	back_btn.text                = "← Back to Menu"
	back_btn.custom_minimum_size = Vector2(220, 50)
	back_btn.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/menu.tscn")
	)
	outer.add_child(back_btn)


func _on_drill_selected(drill_idx: int) -> void:
	_active_drill = drill_idx
	# table.gd reads Globals.active_drill on load and sets up that specific practice
	# shot (cue + one red) instead of a full Career rack. Cleared back to -1 when the
	# player leaves the drill to the menu, so Career play is never affected.
	Globals.active_drill = drill_idx
	Globals.sandbox_mode = false
	get_tree().change_scene_to_file("res://scenes/table.tscn")


func record_attempt(success: bool) -> void:
	if success:
		streak += 1
		var xp: int = _xp_for_active_drill() + (streak - 1) * STREAK_BONUS_PER_POT
		score  += xp
		Globals.add_xp(xp)
	else:
		streak = 0
	if _score_label != null:
		_score_label.text = _score_text()
	if _rank_label != null:
		_rank_label.text = "Rank: " + Globals.get_rank()


func _xp_for_active_drill() -> int:
	if _active_drill >= 0 and _active_drill < DRILLS.size():
		return int(DRILLS[_active_drill]["xp_reward"])
	return 10


func _score_text() -> String:
	return "Session score: %d   |   Streak: %d   |   Total XP: %d" % [score, streak, Globals.total_xp]
