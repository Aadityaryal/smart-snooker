extends Node2D

const TABLE_WIDTH: float = 1220.0
const TABLE_HEIGHT: float = 685.0

var _shot_overlay: Line2D
var _hud_layer: CanvasLayer
var _confidence_label: Label

func _ready() -> void:
	_shot_overlay = Line2D.new()
	_shot_overlay.name = "ShotOverlay"
	_shot_overlay.width = 4.0
	_shot_overlay.default_color = Color(1.0, 0.2, 0.2)
	_shot_overlay.z_index = 1001
	add_child(_shot_overlay)

	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "HUD"
	add_child(_hud_layer)

	_confidence_label = Label.new()
	_confidence_label.name = "ConfidenceLabel"
	_confidence_label.position = Vector2(20.0, 20.0)
	_hud_layer.add_child(_confidence_label)

func apply_recommendation(recommended_shot: Dictionary) -> void:
	_update_confidence(recommended_shot)
	_update_cue_path(recommended_shot)

func _update_confidence(recommended_shot: Dictionary) -> void:
	if recommended_shot.has("confidence"):
		var confidence: float = float(recommended_shot["confidence"])
		_confidence_label.text = "Confidence: " + str(confidence) + "%"

func _update_cue_path(recommended_shot: Dictionary) -> void:
	_shot_overlay.clear_points()
	if not recommended_shot.has("cue_path"):
		return

	var cue_path: Variant = recommended_shot["cue_path"]
	if typeof(cue_path) != TYPE_ARRAY:
		return

	for point_data in cue_path:
		if typeof(point_data) != TYPE_ARRAY:
			continue
		var point: Array = point_data
		if point.size() < 2:
			continue

		var world_point: Vector2 = Vector2(float(point[0]) * TABLE_WIDTH, float(point[1]) * TABLE_HEIGHT)
		_shot_overlay.add_point(world_point)
