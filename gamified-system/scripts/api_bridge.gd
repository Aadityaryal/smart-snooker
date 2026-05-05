extends Node

signal recommendation_ready(recommended_shot: Dictionary)
signal recommendation_failed(reason: String)

const TABLE_WIDTH: float = 1220.0
const TABLE_HEIGHT: float = 685.0
const API_URL: String = "http://127.0.0.1:8000/recommend"

var _http_request: HTTPRequest
var _request_in_flight: bool = false

func _ready() -> void:
	_http_request = HTTPRequest.new()
	_http_request.name = "HTTPRequest"
	_http_request.request_completed.connect(_on_request_completed)
	add_child(_http_request)

func request_recommendation(cue_position: Vector2, target_position: Vector2) -> void:
	if _request_in_flight:
		return

	var cue_x_norm: float = clamp(cue_position.x / TABLE_WIDTH, 0.0, 1.0)
	var cue_y_norm: float = clamp(cue_position.y / TABLE_HEIGHT, 0.0, 1.0)
	var target_x_norm: float = clamp(target_position.x / TABLE_WIDTH, 0.0, 1.0)
	var target_y_norm: float = clamp(target_position.y / TABLE_HEIGHT, 0.0, 1.0)

	var headers: PackedStringArray = ["Content-Type: application/json"]
	var body: String = JSON.stringify({
		"cue_x": cue_x_norm,
		"cue_y": cue_y_norm,
		"target_x": target_x_norm,
		"target_y": target_y_norm,
		"pocket_x": 0.0,
		"pocket_y": 0.0,
		"angle_to_pocket": 0.0,
		"cut_angle": 0.0,
		"distance_cue_to_target": 0.0,
		"distance_target_to_pocket": 0.0,
		"num_balls_in_path": 0,
		"ball_colour": "red",
		"is_snookered": false
	})

	var request_error: int = _http_request.request(API_URL, headers, HTTPClient.METHOD_POST, body)
	if request_error != OK:
		emit_signal("recommendation_failed", "Request failed to start")
		return

	_request_in_flight = true

func _on_request_completed(_result: int, _response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_request_in_flight = false

	var response_text: String = body.get_string_from_utf8()
	print(response_text)

	var parsed_response: Variant = JSON.parse_string(response_text)
	if typeof(parsed_response) != TYPE_DICTIONARY:
		emit_signal("recommendation_failed", "Response is not a JSON object")
		return

	var response_data: Dictionary = parsed_response
	if not response_data.has("recommended_shot"):
		emit_signal("recommendation_failed", "recommended_shot is missing")
		return

	var recommended_shot: Variant = response_data["recommended_shot"]
	if typeof(recommended_shot) != TYPE_DICTIONARY:
		emit_signal("recommendation_failed", "recommended_shot is invalid")
		return

	emit_signal("recommendation_ready", recommended_shot)
