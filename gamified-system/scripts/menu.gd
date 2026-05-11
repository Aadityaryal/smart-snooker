extends Node2D

func _on_career_match_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/table.tscn")

func _on_shot_challenge_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/challenge.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()