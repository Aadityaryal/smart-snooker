from pathlib import Path

import numpy as np
import pandas as pd


TABLE_LENGTH = 2.84
TABLE_WIDTH = 1.42
TABLE_MARGIN = 0.03

BALL_COLOURS = np.array(["red", "yellow", "green", "brown", "blue", "pink", "black"])
BALL_COLOUR_WEIGHTS = np.array([0.64, 0.06, 0.06, 0.07, 0.08, 0.05, 0.04])

SHOT_CONTEXTS = np.array(["open", "break_build", "colour_clearance", "long_pot", "safety", "rescue"])
SHOT_CONTEXT_WEIGHTS = np.array([0.30, 0.18, 0.14, 0.16, 0.14, 0.08])

POCKETS = np.array(
	[
		[0.0, 0.0],
		[TABLE_LENGTH / 2, 0.0],
		[TABLE_LENGTH, 0.0],
		[0.0, TABLE_WIDTH],
		[TABLE_LENGTH / 2, TABLE_WIDTH],
		[TABLE_LENGTH, TABLE_WIDTH],
	],
	dtype=float,
)

COLOR_SPOTS = {
	"yellow": np.array([0.40, 0.28]),
	"green": np.array([0.40, 1.14]),
	"brown": np.array([0.71, 0.71]),
	"blue": np.array([1.42, 0.71]),
	"pink": np.array([2.12, 0.71]),
	"black": np.array([2.52, 0.71]),
}


def _clip_table(values_x: np.ndarray, values_y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
	return (
		np.clip(values_x, TABLE_MARGIN, TABLE_LENGTH - TABLE_MARGIN),
		np.clip(values_y, TABLE_MARGIN, TABLE_WIDTH - TABLE_MARGIN),
	)


def _softmax_choice(rng: np.random.Generator, scores: np.ndarray) -> np.ndarray:
	shifted = scores - scores.max(axis=1, keepdims=True)
	weights = np.exp(shifted)
	weights /= weights.sum(axis=1, keepdims=True)
	random_values = rng.random(weights.shape[0])[:, None]
	return (random_values > np.cumsum(weights, axis=1)).sum(axis=1)


def _sample_cue_positions(rng: np.random.Generator, shot_context: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
	num_rows = shot_context.size
	cue_x = np.empty(num_rows, dtype=float)
	cue_y = np.empty(num_rows, dtype=float)

	context_masks = {
		"open": shot_context == "open",
		"break_build": shot_context == "break_build",
		"colour_clearance": shot_context == "colour_clearance",
		"long_pot": shot_context == "long_pot",
		"safety": shot_context == "safety",
		"rescue": shot_context == "rescue",
	}

	for context, mask in context_masks.items():
		count = int(mask.sum())
		if count == 0:
			continue
		if context == "open":
			x = rng.beta(2.0, 2.0, count) * TABLE_LENGTH
			y = rng.beta(2.1, 2.1, count) * TABLE_WIDTH
		elif context == "break_build":
			x = rng.beta(1.8, 4.2, count) * TABLE_LENGTH
			y = rng.beta(2.0, 2.0, count) * TABLE_WIDTH
		elif context == "colour_clearance":
			x = np.clip(rng.normal(1.8, 0.32, count), TABLE_MARGIN, TABLE_LENGTH - TABLE_MARGIN)
			y = np.clip(rng.normal(TABLE_WIDTH / 2, 0.18, count), TABLE_MARGIN, TABLE_WIDTH - TABLE_MARGIN)
		elif context == "long_pot":
			x = np.clip(rng.normal(1.95, 0.45, count), TABLE_MARGIN, TABLE_LENGTH - TABLE_MARGIN)
			y = np.clip(rng.normal(TABLE_WIDTH / 2, 0.28, count), TABLE_MARGIN, TABLE_WIDTH - TABLE_MARGIN)
		elif context == "safety":
			edge_bias = rng.choice([0, 1, 2, 3], size=count)
			x = rng.beta(0.9, 3.0, count) * TABLE_LENGTH
			y = rng.beta(0.9, 3.0, count) * TABLE_WIDTH
			x = np.where(edge_bias == 1, TABLE_LENGTH - x, x)
			y = np.where(edge_bias == 2, TABLE_WIDTH - y, y)
		elif context == "rescue":
			x = np.clip(rng.normal(0.8, 0.40, count), TABLE_MARGIN, TABLE_LENGTH - TABLE_MARGIN)
			y = np.clip(rng.normal(TABLE_WIDTH / 2, 0.30, count), TABLE_MARGIN, TABLE_WIDTH - TABLE_MARGIN)
		else:
			x = rng.uniform(0, TABLE_LENGTH, count)
			y = rng.uniform(0, TABLE_WIDTH, count)

		cue_x[mask] = x
		cue_y[mask] = y

	return cue_x, cue_y


def _sample_target_positions(
	rng: np.random.Generator,
	ball_colour: np.ndarray,
	shot_context: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
	num_rows = ball_colour.size
	target_x = np.empty(num_rows, dtype=float)
	target_y = np.empty(num_rows, dtype=float)

	for colour in BALL_COLOURS:
		mask = ball_colour == colour
		count = int(mask.sum())
		if count == 0:
			continue

		if colour == "red":
			context_shift = np.where(
				shot_context[mask] == "long_pot",
				0.18,
				np.where(shot_context[mask] == "break_build", -0.10, 0.0),
			)
			x = rng.normal(2.06 + context_shift, 0.20, count)
			y = rng.normal(TABLE_WIDTH / 2, 0.13, count)
		else:
			spot = COLOR_SPOTS[colour]
			jitter_x = 0.05 if colour in {"yellow", "green", "brown"} else 0.07
			jitter_y = 0.04 if colour in {"blue", "pink", "black"} else 0.06
			context_shaper = np.where(shot_context[mask] == "safety", 1.5, 1.0)
			x = rng.normal(spot[0], jitter_x * context_shaper, count)
			y = rng.normal(spot[1], jitter_y * context_shaper, count)

		target_x[mask], target_y[mask] = _clip_table(x, y)

	return target_x, target_y


def _pick_pockets(
	rng: np.random.Generator,
	target_x: np.ndarray,
	target_y: np.ndarray,
	shot_context: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
	distances = np.sqrt((target_x[:, None] - POCKETS[None, :, 0]) ** 2 + (target_y[:, None] - POCKETS[None, :, 1]) ** 2)
	temperature = np.where(
		shot_context == "safety",
		1.35,
		np.where(shot_context == "rescue", 1.15, np.where(shot_context == "long_pot", 0.72, 0.90)),
	)
	scores = -distances / temperature[:, None]
	selected_index = _softmax_choice(rng, scores)
	selected_pockets = POCKETS[selected_index]
	pocket_x = np.clip(selected_pockets[:, 0] + rng.uniform(-0.035, 0.035, target_x.size), TABLE_MARGIN, TABLE_LENGTH - TABLE_MARGIN)
	pocket_y = np.clip(selected_pockets[:, 1] + rng.uniform(-0.035, 0.035, target_x.size), TABLE_MARGIN, TABLE_WIDTH - TABLE_MARGIN)
	return pocket_x, pocket_y


def generate_shot_data(num_rows: int = 1_000_000, seed: int = 42) -> pd.DataFrame:
	rng = np.random.default_rng(seed)

	shot_context = rng.choice(SHOT_CONTEXTS, size=num_rows, p=SHOT_CONTEXT_WEIGHTS)
	ball_colour = rng.choice(BALL_COLOURS, size=num_rows, p=BALL_COLOUR_WEIGHTS)

	cue_x, cue_y = _sample_cue_positions(rng, shot_context)
	target_x, target_y = _sample_target_positions(rng, ball_colour, shot_context)
	pocket_x, pocket_y = _pick_pockets(rng, target_x, target_y, shot_context)

	distance_cue_to_target = np.sqrt((cue_x - target_x) ** 2 + (cue_y - target_y) ** 2)
	distance_target_to_pocket = np.sqrt((target_x - pocket_x) ** 2 + (target_y - pocket_y) ** 2)
	distance_cue_to_pocket = np.sqrt((cue_x - pocket_x) ** 2 + (cue_y - pocket_y) ** 2)

	cue_to_target_angle = np.degrees(np.arctan2(target_y - cue_y, target_x - cue_x))
	target_to_pocket_angle = np.degrees(np.arctan2(pocket_y - target_y, pocket_x - target_x))

	angle_to_pocket = target_to_pocket_angle
	cut_angle = np.abs(cue_to_target_angle - angle_to_pocket)
	cut_angle = np.mod(cut_angle, 180.0)
	cut_angle = np.where(cut_angle > 90.0, 180.0 - cut_angle, cut_angle)

	cue_near_cushion = (
		(cue_x < 0.18)
		| (cue_x > TABLE_LENGTH - 0.18)
		| (cue_y < 0.13)
		| (cue_y > TABLE_WIDTH - 0.13)
	)

	base_path_pressure = (
		0.9 * (distance_cue_to_target / TABLE_LENGTH)
		+ 1.0 * (distance_target_to_pocket / TABLE_LENGTH)
		+ 0.012 * cut_angle
		+ np.where(shot_context == "safety", 0.75, 0.0)
		+ np.where(shot_context == "rescue", 0.55, 0.0)
	)
	num_balls_in_path = np.clip(rng.poisson(np.clip(base_path_pressure, 0.05, 3.5)), 0, 6)

	snooker_probability = 1.0 / (1.0 + np.exp(-(-2.3 + 0.9 * num_balls_in_path + 0.025 * cut_angle + 0.7 * cue_near_cushion.astype(float))))
	is_snookered = rng.random(num_rows) < snooker_probability

	path_clearance = np.clip(
		1.0
		- 0.15 * num_balls_in_path
		- 0.005 * cut_angle
		- np.where(cue_near_cushion, 0.10, 0.0)
		+ rng.normal(0, 0.04, num_rows),
		0.0,
		1.0,
	)

	potting_difficulty = np.clip(
		0.18 * distance_cue_to_target
		+ 0.16 * distance_target_to_pocket
		+ 0.012 * cut_angle
		+ 0.22 * num_balls_in_path
		+ 0.45 * is_snookered.astype(float)
		+ np.where(shot_context == "long_pot", 0.14, 0.0)
		+ np.where(shot_context == "safety", 0.22, 0.0),
		0.0,
		4.0,
	)

	shot_score = (
		100
		- 16.0 * distance_cue_to_target
		- 13.0 * distance_target_to_pocket
		- 0.75 * cut_angle
		- 11.0 * num_balls_in_path
		- 15.0 * is_snookered.astype(float)
		- 8.0 * cue_near_cushion.astype(float)
		- 6.0 * potting_difficulty
		+ np.where(shot_context == "open", 4.0, 0.0)
		+ np.where(shot_context == "break_build", 2.0, 0.0)
		+ rng.normal(0, 5.0, num_rows)
	)
	shot_score = np.clip(shot_score, 0, 100)

	is_recommended = shot_score >= np.where(shot_context == "safety", 55, 62)

	shot_type = np.where(
		(cut_angle < 10) & (distance_target_to_pocket < 1.25),
		"straight",
		np.where(
			cut_angle < 28,
			"thin_cut",
			np.where(cut_angle < 58, "medium_cut", "heavy_cut"),
		),
	)

	return pd.DataFrame(
		{
			"cue_x": cue_x,
			"cue_y": cue_y,
			"target_x": target_x,
			"target_y": target_y,
			"pocket_x": pocket_x,
			"pocket_y": pocket_y,
			"angle_to_pocket": angle_to_pocket,
			"cut_angle": cut_angle,
			"distance_cue_to_target": distance_cue_to_target,
			"distance_target_to_pocket": distance_target_to_pocket,
			"distance_cue_to_pocket": distance_cue_to_pocket,
			"num_balls_in_path": num_balls_in_path,
			"ball_colour": ball_colour,
			"is_snookered": is_snookered,
			"shot_context": shot_context,
			"path_clearance": path_clearance,
			"potting_difficulty": potting_difficulty,
			"shot_score": shot_score,
			"is_recommended": is_recommended,
			"shot_type": shot_type,
		}
	)


def main() -> None:
	output_path = Path(__file__).resolve().parent / "shots.csv"
	data = generate_shot_data()
	data.to_csv(output_path, index=False)
	print(f"Saved {len(data)} rows to {output_path}")


if __name__ == "__main__":
	main()
