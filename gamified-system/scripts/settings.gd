# res://scripts/settings.gd
# ─────────────────────────────────────────────────────────────────────────────
# Standalone Settings screen. The actual controls live in the reusable
# settings_panel.gd (shared with the in-game pause overlay in table.gd); this
# screen just frames it with a title, a scroll area, and a Back button.
# The .tscn is a Control root with this script attached.
# ─────────────────────────────────────────────────────────────────────────────
extends Control


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.08, 0.1, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Scroll so the panel is reachable even on a short window.
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(0.0, 0.0)
	# Left padding via a margin container keeps the layout tidy without absolute coords.
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 80)
	margin.add_theme_constant_override("margin_top", 48)
	margin.add_theme_constant_override("margin_right", 80)
	margin.add_theme_constant_override("margin_bottom", 40)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color(0.55, 0.95, 0.7))
	vb.add_child(title)

	var panel: VBoxContainer = preload("res://scripts/settings_panel.gd").new()
	vb.add_child(panel)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 12.0)
	vb.add_child(spacer)

	var back := Button.new()
	back.text = "←  Back to Menu"
	back.custom_minimum_size = Vector2(220.0, 44.0)
	back.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/menu.tscn")
	)
	vb.add_child(back)
