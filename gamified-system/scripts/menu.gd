# res://scripts/menu.gd
# ─────────────────────────────────────────────────────────────────────────────
# Main menu scene controller. Routes to each mode / screen.
# Buttons (wired in menu.tscn): Career Match, Shot Challenge, Drills,
# Scenario Sandbox, Settings, Quit.
# ─────────────────────────────────────────────────────────────────────────────
extends Node2D

func _ready() -> void:
	# When launched as a headless binary (RL training), skip the menu and load
	# the table directly so the Sync node can connect to Python immediately.
	if DisplayServer.get_name() == "headless":
		get_tree().change_scene_to_file.call_deferred("res://scenes/table.tscn")
		return
	_polish_menu()


# Dress the plain scene up as a real game main menu: dark backdrop, an accented
# title, a subtitle, and consistent button widths. Everything else (routing) is
# unchanged — this only touches presentation.
func _polish_menu() -> void:
	var control: Control = $CanvasLayer/Control
	var bg: ColorRect = ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.06, 0.08, 0.1)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.add_child(bg)
	control.move_child(bg, 0)

	# A soft green felt band behind the title, so it reads as a snooker game.
	var band: ColorRect = ColorRect.new()
	band.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	band.offset_top = 0.0
	band.offset_bottom = 6.0
	band.color = Color(0.12, 0.5, 0.28)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.add_child(band)
	control.move_child(band, 1)

	var vbox: VBoxContainer = $CanvasLayer/Control/CenterContainer/VBoxContainer
	vbox.add_theme_constant_override("separation", 14)

	var title: Label = vbox.get_node_or_null("TitleLabel") as Label
	if title != null:
		title.add_theme_font_size_override("font_size", 58)
		title.add_theme_color_override("font_color", Color(0.55, 0.95, 0.7))

	var subtitle: Label = Label.new()
	subtitle.name = "SubtitleLabel"
	subtitle.text = "AI-coached snooker  •  potting, position & practice"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", Color(0.6, 0.68, 0.75))
	vbox.add_child(subtitle)
	vbox.move_child(subtitle, 1)   # directly under the title

	# Player greeting, top-right — makes the local "account" visible. Editable in Settings.
	var greeting: Label = Label.new()
	greeting.name = "GreetingLabel"
	greeting.text = "Signed in as  %s   •   %s" % [Globals.player_name, Globals.get_rank()]
	greeting.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	greeting.position = Vector2(-360.0, 16.0)
	greeting.custom_minimum_size = Vector2(340.0, 24.0)
	greeting.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	greeting.mouse_filter = Control.MOUSE_FILTER_IGNORE
	greeting.add_theme_font_size_override("font_size", 15)
	greeting.add_theme_color_override("font_color", Color(1.0, 0.82, 0.3))
	control.add_child(greeting)

	# If a Career frame was saved, offer to resume it (and to start fresh instead).
	var career_btn: Button = vbox.get_node_or_null("CareerMatchButton") as Button
	if Globals.has_career_save() and career_btn != null:
		career_btn.text = "Resume Career"
		var new_career := Button.new()
		new_career.name = "NewCareerButton"
		new_career.text = "New Career"
		new_career.pressed.connect(_on_new_career_pressed)
		vbox.add_child(new_career)
		vbox.move_child(new_career, career_btn.get_index() + 1)

	# Uniform, comfortable button width.
	for child: Node in vbox.get_children():
		if child is Button:
			(child as Button).custom_minimum_size = Vector2(320.0, 0.0)

func _on_career_match_pressed() -> void:
	Globals.active_drill = -1        # ensure a full Career rack, never a drill setup
	Globals.sandbox_mode = false
	# Resume the saved frame if one exists (the button reads "Resume Career" then);
	# otherwise this is a fresh match.
	Globals.career_resume = Globals.has_career_save()
	get_tree().change_scene_to_file("res://scenes/table.tscn")


func _on_new_career_pressed() -> void:
	Globals.active_drill = -1
	Globals.sandbox_mode = false
	Globals.clear_career_save()      # discard the saved frame — start fresh
	Globals.career_resume = false
	get_tree().change_scene_to_file("res://scenes/table.tscn")

func _on_shot_challenge_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/challenge.tscn")

func _on_drills_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/drills.tscn")

func _on_sandbox_pressed() -> void:
	# Sandbox is now the real physics table in free-play mode (see table.gd), so you
	# can actually shoot, spin, and watch the cue land — not just view a static suggestion.
	Globals.sandbox_mode = true
	Globals.active_drill = -1
	get_tree().change_scene_to_file("res://scenes/table.tscn")

func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/settings.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()
