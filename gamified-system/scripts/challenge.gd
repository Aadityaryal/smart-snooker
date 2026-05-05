extends Node2D

func rank_shot_options(options: Array[Dictionary]) -> Array[Dictionary]:
	var ranked_options: Array[Dictionary] = options.duplicate()
	ranked_options.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)
	return ranked_options
