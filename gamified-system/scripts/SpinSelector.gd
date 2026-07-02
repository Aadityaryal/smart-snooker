# res://scripts/SpinSelector.gd
# ─────────────────────────────────────────────────────────────────────────────
# Standalone SpinSelector Control for cue ball English (spin) selection.
# Emits spin_changed(Vector2) where x = side spin (−1..+1), y = top/back (−1..+1)
#
# Can be added to any scene via the editor.  table.gd also embeds a copy of
# this as an inner class; both are kept in sync and use identical Godot 4 syntax.
#
# FIXES (G1–G4 + extras):
#   G1  export var  →  @export var                          (3 properties)
#   G2  emit_signal("spin_changed", v)  →  spin_changed.emit(v)
#   G3  update()  →  queue_redraw()                         (2 calls)
#   G3  set_process_input(true)  →  removed (Godot 4 auto)
#   G4  BUTTON_LEFT  →  MOUSE_BUTTON_LEFT
#   +   to_local(event.position) removed — in Godot 4 _gui_input the
#       position is already in the Control's local coordinate space
#   +   local_pos.clamped(radius) → local_pos.limit_length(radius)
#       (Vector2.clamped was renamed to limit_length in Godot 4)
#   +   _draw() now draws at  size / 2.0  not  Vector2.ZERO  so the circle
#       appears centred inside the Control rect at any size
# ─────────────────────────────────────────────────────────────────────────────
extends Control

signal spin_changed(new_spin: Vector2)

@export var radius:          float = 50.0                    # G1 fix
@export var crosshair_color: Color = Color(1.0, 0.15, 0.15, 1.0)  # G1 fix
@export var circle_color:    Color = Color(1.0, 1.0, 1.0, 0.25)   # G1 fix

var _dragging:     bool    = false
var _current_spin: Vector2 = Vector2.ZERO


func _ready() -> void:
	# Godot 4: input processing for Controls is automatic — no set_process_input() needed
	# Ensure the control is large enough to contain the circle
	custom_minimum_size = Vector2(radius * 2.0 + 10.0, radius * 2.0 + 10.0)
	queue_redraw()   # G3 fix — was update()


func _draw() -> void:
	# Draw relative to the centre of this Control's rect (not Vector2.ZERO)
	var c: Vector2 = size / 2.0

	# Outer semi-transparent circle (cue ball face)
	draw_circle(c, radius, circle_color)

	# Border ring
	var segments: int = 64
	for i: int in range(segments):
		var a1: float = (float(i)   / segments) * TAU
		var a2: float = (float(i+1) / segments) * TAU
		draw_line(
			c + Vector2(cos(a1), sin(a1)) * radius,
			c + Vector2(cos(a2), sin(a2)) * radius,
			Color(1.0, 1.0, 1.0, 0.6), 1.5
		)

	# Faint centre crosshair guides
	draw_line(c + Vector2(-radius, 0.0), c + Vector2(radius, 0.0),  Color(1,1,1,0.15), 1.0)
	draw_line(c + Vector2(0.0, -radius), c + Vector2(0.0,  radius), Color(1,1,1,0.15), 1.0)

	# Crosshair dot at current spin position
	var cross_pos: Vector2 = c + _current_spin * radius
	draw_circle(cross_pos, 5.0, crosshair_color)
	draw_line(cross_pos + Vector2(-8, 0), cross_pos + Vector2(8, 0),  crosshair_color, 2.0)
	draw_line(cross_pos + Vector2(0,-8), cross_pos + Vector2(0, 8),   crosshair_color, 2.0)


func _gui_input(event: InputEvent) -> void:
	# In Godot 4 _gui_input, event.position is ALREADY in the Control's local
	# coordinate space — no to_local() call needed (that was a Godot 3 pattern).
	var c: Vector2 = size / 2.0

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:  # G4 fix
		var local_pos: Vector2 = event.position - c
		if event.pressed and local_pos.length() <= radius:
			_dragging = true
			_update_spin(local_pos)
			accept_event()
		elif not event.pressed and _dragging:
			_dragging = false
			accept_event()

	elif event is InputEventMouseMotion and _dragging:
		_update_spin(event.position - c)
		accept_event()


func _update_spin(local_pos: Vector2) -> void:
	# limit_length() is the Godot 4 name for the old clamped() method on Vector2
	_current_spin = local_pos.limit_length(radius) / radius  # G4 extra fix
	spin_changed.emit(_current_spin)   # G2 fix — was emit_signal("spin_changed", _current_spin)
	queue_redraw()                     # G3 fix — was update()
