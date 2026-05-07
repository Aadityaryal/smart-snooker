extends Node2D
@onready var xp_system: Node2D = preload("res://scripts/xp_system.gd").new()

var correct_answer_index: int = 0
var option_buttons: Array[Button] = []
var result_label: Label

const SHOT_OPTIONS: Array[String] = [
	"Pot Red → Top Left",
	"Pot Red → Top Right",
	"Pot Red → Bottom Left",
	"Pot Red → Bottom Right",
	"Pot Red → Middle Left",
	"Pot Red → Middle Right",
	"Pot Yellow → Top Left",
	"Pot Green → Bottom Right",
]

func _ready() -> void:
	add_child(xp_system)
	_build_ui()
	_generate_question()

func _build_ui() -> void:
	var hud_layer: CanvasLayer = CanvasLayer.new()
	hud_layer.name = "HUD"
	add_child(hud_layer)

	var control_root: Control = Control.new()
	control_root.name = "Control"
	control_root.anchors_preset = Control.PRESET_FULL_RECT
	control_root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	control_root.grow_vertical = Control.GROW_DIRECTION_BOTH
	hud_layer.add_child(control_root)

	var center_container: CenterContainer = CenterContainer.new()
	center_container.anchors_preset = Control.PRESET_FULL_RECT
	center_container.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center_container.grow_vertical = Control.GROW_DIRECTION_BOTH
	control_root.add_child(center_container)

	var outer_vbox: VBoxContainer = VBoxContainer.new()
	outer_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	outer_vbox.add_theme_constant_override("separation", 18)
	center_container.add_child(outer_vbox)

	var title_label: Label = Label.new()
	title_label.text = "Shot Challenge"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 36)
	outer_vbox.add_child(title_label)

	var options_grid: GridContainer = GridContainer.new()
	options_grid.columns = 2
	options_grid.add_theme_constant_override("h_separation", 16)
	options_grid.add_theme_constant_override("v_separation", 16)
	outer_vbox.add_child(options_grid)

	for i in range(4):
		var button: Button = Button.new()
		button.custom_minimum_size = Vector2(320.0, 72.0)
		button.pressed.connect(_on_option_pressed.bind(i))
		options_grid.add_child(button)
		option_buttons.append(button)

	result_label = Label.new()
	result_label.text = ""
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.add_theme_font_size_override("font_size", 28)
	outer_vbox.add_child(result_label)

func _generate_question() -> void:
	correct_answer_index = randi_range(0, 3)
	var available_options: Array[String] = SHOT_OPTIONS.duplicate()
	available_options.shuffle()

	for i in range(option_buttons.size()):
		option_buttons[i].disabled = false
		option_buttons[i].modulate = Color.WHITE
		option_buttons[i].text = available_options[i]

	result_label.text = ""

func _on_option_pressed(button_index: int) -> void:
	for button in option_buttons:
		button.disabled = true

	var is_correct: bool = button_index == correct_answer_index
	option_buttons[button_index].modulate = Color(0.2, 1.0, 0.2) if is_correct else Color(1.0, 0.2, 0.2)
	result_label.text = "Correct!" if is_correct else "Wrong!"

	if is_correct and xp_system != null and xp_system.has_method("add_xp"):
		xp_system.call("add_xp", 20)

func rank_shot_options(options: Array[Dictionary]) -> Array[Dictionary]:
	var ranked_options: Array[Dictionary] = options.duplicate()
	ranked_options.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)
	return ranked_options
