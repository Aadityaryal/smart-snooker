# res://scripts/api_bridge.gd
# ─────────────────────────────────────────────────────────────────────────────
# FIX F3 — Dictionary.get() always returns Variant, not Vector2.
#           Appending a Variant into Array[Vector2] throws a runtime type error
#           in Godot 4 whenever any other ball exists on the table.
#           Both call sites now use  ...as Vector2  to make the cast explicit.
# ─────────────────────────────────────────────────────────────────────────────
extends Node

signal recommendation_ready(recommended_shot: Dictionary)
signal recommendation_failed(reason: String)
signal placement_ready(placement: Dictionary)

const API_URL:        String = "http://127.0.0.1:8000/recommend"
const PLACE_URL:      String = "http://127.0.0.1:8000/place_cue"
# Without a timeout, HTTPRequest waits forever: if the server accepts the connection but
# never answers, request_completed never fires, _request_in_flight stays true and EVERY
# later recommendation is skipped for the rest of the session — the feature dies silently.
const HTTP_TIMEOUT: float = 5.0
# Positions are normalised by TABLE_W/TABLE_H, which are NOT the play-area bounds: a ball
# resting on the right cushion sits at x=1233 → 1.011. Clamping to 1.0 (as this used to)
# silently shifted right-rail balls 13 px for the model. The engine's own pocket coords
# exceed 1.0 too, so allow a little headroom and only clamp genuine garbage.
const NORM_MIN: float = 0.0
const NORM_MAX: float = 1.05

var _http_request:      HTTPRequest = null
var _http_place:        HTTPRequest = null   # separate channel for /place_cue
var _request_in_flight: bool        = false
var _place_in_flight:   bool        = false
var _table:             Node        = null


func _ready() -> void:
	_table        = get_parent()
	_http_request = HTTPRequest.new()
	_http_request.name = "HTTPRequest"
	_http_request.timeout = HTTP_TIMEOUT
	_http_request.request_completed.connect(_on_request_completed)
	add_child(_http_request)

	_http_place = HTTPRequest.new()
	_http_place.name = "HTTPPlace"
	_http_place.timeout = HTTP_TIMEOUT
	_http_place.request_completed.connect(_on_place_completed)
	add_child(_http_place)


# Ball-in-hand: ask the server where to put the cue ball (break / after a foul).
# balls = Array of {"pos": Vector2, "colour": String, "id": int} (cue excluded).
func request_cue_placement(balls: Array, reds_remaining: int, must_pot_colour: bool) -> void:
	if _place_in_flight:
		return
	var balls_json: Array = []
	for b: Dictionary in balls:
		var p := b.get("pos", Vector2.ZERO) as Vector2
		balls_json.append({
			"x": clampf(p.x / Globals.TABLE_W, NORM_MIN, NORM_MAX),
			"y": clampf(p.y / Globals.TABLE_H, NORM_MIN, NORM_MAX),
			"colour": b.get("colour", "red"),
			"id": int(b.get("id", 0)),
		})
	var headers: PackedStringArray = ["Content-Type: application/json"]
	var body: String = JSON.stringify({
		"reds_remaining": reds_remaining,
		"must_pot_colour": must_pot_colour,
		"balls": balls_json,
	})
	var err: int = _http_place.request(PLACE_URL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		recommendation_failed.emit("place_cue request failed: error " + str(err))
		return
	_place_in_flight = true


func _on_place_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_place_in_flight = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		recommendation_failed.emit("place_cue HTTP error " + str(response_code))
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		recommendation_failed.emit("place_cue: bad response")
		return
	placement_ready.emit(parsed)


# New flow: send the FULL table state and let the server CHOOSE the shot (target,
# pocket, aim, force). balls = Array of {"pos": Vector2, "colour": String, "id": int}.
func request_full_recommendation(cue_position: Vector2, balls: Array,
		reds_remaining: int, must_pot_colour: bool) -> void:
	# A request already running describes an OLDER table. Dropping the new one (what this
	# used to do) left the previous turn's recommendation on screen, so "Play AI Shot"
	# could aim at a layout that no longer exists. Cancel the stale one and ask again.
	if _request_in_flight:
		_http_request.cancel_request()
		_request_in_flight = false
	var balls_json: Array = []
	for b: Dictionary in balls:
		var p := b.get("pos", Vector2.ZERO) as Vector2
		balls_json.append({
			"x": clampf(p.x / Globals.TABLE_W, NORM_MIN, NORM_MAX),
			"y": clampf(p.y / Globals.TABLE_H, NORM_MIN, NORM_MAX),
			"colour": b.get("colour", "red"),
			"id": int(b.get("id", 0)),
		})
	var headers: PackedStringArray = ["Content-Type: application/json"]
	var body: String = JSON.stringify({
		"cue_x": clampf(cue_position.x / Globals.TABLE_W, NORM_MIN, NORM_MAX),
		"cue_y": clampf(cue_position.y / Globals.TABLE_H, NORM_MIN, NORM_MAX),
		"reds_remaining": reds_remaining,
		"must_pot_colour": must_pot_colour,
		"balls": balls_json,
	})
	var err: int = _http_request.request(API_URL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		recommendation_failed.emit("HTTPRequest.request() failed: error " + str(err))
		return
	_request_in_flight = true


func _on_request_completed(
	result:        int,
	response_code: int,
	_headers:      PackedStringArray,
	body:          PackedByteArray
) -> void:
	_request_in_flight = false
	if result != HTTPRequest.RESULT_SUCCESS:
		recommendation_failed.emit("HTTP transport error, code: " + str(result))
		return
	if response_code != 200:
		recommendation_failed.emit("API returned HTTP " + str(response_code))
		return
	var text: String = body.get_string_from_utf8()
	if text.is_empty():
		recommendation_failed.emit("Empty response body")
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		recommendation_failed.emit("Response is not a JSON object")
		return
	var data: Dictionary = parsed
	# Emit the FULL response (mode, recommended_shot, coaching, alternatives,
	# safety) so the overlay can draw the strategic picture. recommended_shot may
	# be null in safety/none modes — the overlay handles that.
	recommendation_ready.emit(data)
