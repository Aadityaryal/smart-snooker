# recommendation-engine/train_rl.py
# ─────────────────────────────────────────────────────────────────────────────
# Smart Snooker — Full Curriculum PPO Training  (V0 → V1 → V2 → V3)
#
# The agent automatically advances to the next version when it meets the
# graduation criteria.  No manual restarts needed.  Checkpoints save at every
# version upgrade and every 50 000 steps so you can resume any time.
#
# ── INSTALL ───────────────────────────────────────────────────────────────────
#   pip install godot-rl stable-baselines3 torch tensorboard
#
# ── LOCAL RUN (development / testing) ────────────────────────────────────────
#   python train_rl.py --timesteps 500000 --n_parallel 3 --speedup 16
#
# ── KAGGLE RUN ────────────────────────────────────────────────────────────────
#   Step 1:  Export Godot project: Project → Export → Linux x86_64
#            Produces  smart_snooker.x86_64  and  smart_snooker.pck
#
#   Step 2:  Upload both files as a Kaggle Dataset named smart-snooker-bin
#
#   Step 3:  In your notebook:
#            !mkdir -p /kaggle/working/game
#            !cp /kaggle/input/smart-snooker-bin/* /kaggle/working/game/
#            !chmod +x /kaggle/working/game/smart_snooker.x86_64
#            !python train_rl.py \
#                --binary /kaggle/working/game/smart_snooker.x86_64 \
#                --timesteps 3000000 --n_parallel 4 --speedup 16
#
#   Step 4:  Download /kaggle/working/models/snooker_ppo_final.zip
#
# ── RESUME after stopping ────────────────────────────────────────────────────
#   python train_rl.py --resume models/checkpoints/snooker_ppo_v0_final.zip \
#                      --timesteps 1000000
#
# ── EVALUATE trained model ───────────────────────────────────────────────────
#   python train_rl.py --mode eval \
#                      --model models/snooker_ppo_final
# ─────────────────────────────────────────────────────────────────────────────
from __future__ import annotations

import argparse
import json
import os
from collections import deque
from pathlib import Path
from typing import Deque

try:
    from stable_baselines3 import PPO
    from stable_baselines3.common.callbacks import BaseCallback, CheckpointCallback
    from stable_baselines3.common.vec_env import VecMonitor
except ImportError:
    raise SystemExit("Run:  pip install stable-baselines3 torch")

try:
    from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv
    from godot_rl.core.godot_env import GodotEnv
except ImportError:
    raise SystemExit("Run:  pip install godot-rl")


# ── Paths ──────────────────────────────────────────────────────────────────────
_HERE      = Path(__file__).resolve().parent
MODELS_DIR = _HERE / "models"
LOGS_DIR   = _HERE / "logs"
CKPT_DIR   = MODELS_DIR / "checkpoints"
for _d in (MODELS_DIR, LOGS_DIR, CKPT_DIR):
    _d.mkdir(parents=True, exist_ok=True)


# ── PPO hyperparameters ────────────────────────────────────────────────────────
# These work across all versions.  The network is large enough to handle the
# full 73-float observation from day one.
PPO_CONFIG: dict = {
    "n_steps":       512,
    "batch_size":    64,
    "n_epochs":      10,
    "learning_rate": 1e-4,   # 3e-4 caused unstable updates (clip_fraction >0.35)
    "gamma":         0.99,
    "gae_lambda":    0.95,
    "clip_range":    0.1,    # 0.2 too loose — explained_variance went negative
    "ent_coef":      0.001,  # tiny bonus keeps std from collapsing to 0 (local minimum).
                             # NOTE: the std 0.37->0.85 runaway seen through training10 was
                             # NOT caused by this — it was the action_repeat=8 bug feeding
                             # PPO ~94% no-op-action transitions, so the gradient was noise
                             # and log_std could never concentrate. Fixed via action_repeat
                             # in table.tscn (one Python exchange == one settled shot).
    "vf_coef":       0.5,
    "max_grad_norm": 0.5,
    "verbose":       1,
}

# 3 hidden layers of 256 units.
# Larger than the default because the 73-float obs needs more capacity.
POLICY_KWARGS: dict = {
    "net_arch":      dict(pi=[256, 256, 256], vf=[256, 256, 256]),
    "log_std_init":  -1.0,   # start std≈0.37 instead of 1.0; prevents early entropy explosion
}

# ── Graduation criteria ────────────────────────────────────────────────────────
# Must be consistent with Globals.V*_GRADUATE_* constants in globals.gd.
GRADUATION = {
    0: {"metric": "reds_potted",  "threshold": 1.5,  "window": 1000},
    1: {"metric": "reds_potted",  "threshold": 10.0, "window": 500},
    2: {"metric": "score",        "threshold": 30.0, "window": 500},
}
MAX_VERSION = 3   # highest version this script trains


# ═════════════════════════════════════════════════════════════════════════════
# Curriculum callback — monitors per-episode metrics and upgrades the version
# ═════════════════════════════════════════════════════════════════════════════
class CurriculumCallback(BaseCallback):
    """
    Runs inside the SB3 training loop.
    Every episode it records reward / reds_potted / score from the Godot
    info dict (populated by rl_controller.get_info()).
    When the rolling average over the graduation window meets the threshold,
    it writes rl_config.json next to the game binary so Godot reads the new
    version on the next episode reset, then saves a version-checkpoint and
    clears the metric history.
    """

    def __init__(self, binary_path: str | None, verbose: int = 1) -> None:
        super().__init__(verbose)
        self.binary_path     = binary_path
        self.current_version = 0

        crit = GRADUATION.get(0, {})
        window = crit.get("window", 1000)
        self._rewards:      Deque[float] = deque(maxlen=window)
        self._reds_potted:  Deque[float] = deque(maxlen=window)
        self._scores:       Deque[float] = deque(maxlen=window)
        self._curriculum:   Deque[float] = deque(maxlen=window)

    # ── Called every environment step ─────────────────────────────────────────
    def _on_step(self) -> bool:
        for info in self.locals.get("infos", []):
            if "episode" not in info:
                continue
            ep = info["episode"]
            self._rewards.append(float(ep.get("r", 0.0)))
            self._reds_potted.append(float(info.get("reds_potted", 0)))
            self._scores.append(float(info.get("episode_score", 0)))
            self._curriculum.append(float(info.get("curriculum", 1.0)))

        if self.current_version < MAX_VERSION:
            self._check_graduation()

        return True

    def _check_graduation(self) -> None:
        crit      = GRADUATION.get(self.current_version, {})
        window    = crit.get("window", 1000)
        metric    = crit.get("metric", "reward")
        threshold = crit.get("threshold", 1.0)

        # Need enough episodes in the window before evaluating
        if len(self._rewards) < window:
            return

        if   metric == "reward":      avg = sum(self._rewards)     / len(self._rewards)
        elif metric == "reds_potted": avg = sum(self._reds_potted)  / len(self._reds_potted)
        elif metric == "score":       avg = sum(self._scores)       / len(self._scores)
        else:                         avg = 0.0

        # V0 uses a reverse curriculum in Godot (red spawns near a pocket at
        # difficulty 0, fully random at 1.0). Pots at easy placements must not
        # count as mastery: only graduate once the agent sustains the pot-rate
        # threshold at (near-)full difficulty.
        if self.current_version == 0 and self._curriculum:
            avg_curr = sum(self._curriculum) / len(self._curriculum)
            if avg_curr < 0.95:
                return

        if avg >= threshold:
            self._graduate()

    def _graduate(self) -> None:
        old_v = self.current_version
        new_v = old_v + 1
        self.current_version = new_v

        # ── Write config so Godot reads new version on next reset ─────────────
        config_dir = (os.path.dirname(os.path.abspath(self.binary_path))
                      if self.binary_path
                      else str(Path.home() / ".local/share/godot/app_userdata/Smart Snooker"))
        os.makedirs(config_dir, exist_ok=True)
        config_path = os.path.join(config_dir, "rl_config.json")
        with open(config_path, "w") as f:
            json.dump({"rl_version": new_v, "upgraded_at_step": self.num_timesteps}, f)

        # ── Save version checkpoint ────────────────────────────────────────────
        ckpt = str(CKPT_DIR / f"snooker_ppo_v{old_v}_final")
        self.model.save(ckpt)

        # ── Reset metric history for new version ──────────────────────────────
        crit   = GRADUATION.get(new_v, {})
        window = crit.get("window", 500)
        self._rewards     = deque(maxlen=window)
        self._reds_potted = deque(maxlen=window)
        self._scores      = deque(maxlen=window)
        self._curriculum  = deque(maxlen=window)

        if self.verbose:
            print(f"\n{'='*60}")
            print(f"  CURRICULUM UPGRADE: V{old_v} → V{new_v}")
            print(f"  Step {self.num_timesteps:,}   checkpoint: {ckpt}.zip")
            print(f"{'='*60}\n")


# ═════════════════════════════════════════════════════════════════════════════
# Environment factory
# ═════════════════════════════════════════════════════════════════════════════
def build_env(
    binary_path: str | None,
    n_parallel:  int,
    speedup:     int,
    seed:        int,
    show_window: bool | None = None,
) -> VecMonitor:
    if show_window is None:
        show_window = binary_path is None
    if show_window:
        # Windowed mode does full engine boot (OpenGL context + shader compile),
        # unlike training's --disable-render-loop --headless path which skips all
        # of that. On this laptop's integrated Intel UHD 620 that cold-start can
        # exceed the default 60s connect timeout, so the Python server gives up
        # before Godot finishes opening its window. 300s gives it headroom.
        GodotEnv.DEFAULT_TIMEOUT = 300
    env = StableBaselinesGodotEnv(
        env_path=binary_path,
        show_window=show_window,
        seed=seed,
        n_parallel=n_parallel,
        speedup=speedup,
    )
    # godot_rl 0.8.x leaves seed() as NotImplementedError; SB3 2.x calls it
    env.seed = lambda s=None: [s] * env.num_envs
    return VecMonitor(env)


# ═════════════════════════════════════════════════════════════════════════════
# Training
# ═════════════════════════════════════════════════════════════════════════════
def train(args: argparse.Namespace) -> None:
    print("=" * 60)
    print("Smart Snooker — Curriculum PPO Training")
    print(f"  Binary     : {args.binary or 'Godot editor'}")
    print(f"  Timesteps  : {args.timesteps:,}")
    print(f"  Parallel   : {args.n_parallel}")
    print(f"  Speedup    : {args.speedup}×")
    print(f"  Seed       : {args.seed}")
    print(f"  Versions   : V0 → V1 → V2 → V3  (automatic)")
    print("=" * 60)

    env = build_env(args.binary, args.n_parallel, args.speedup, args.seed)

    if args.resume and Path(args.resume).exists():
        print(f"\nResuming from: {args.resume}")
        model = PPO.load(args.resume, env=env)
        reset_ts = False
    else:
        model = PPO(
            policy="MultiInputPolicy",
            env=env,
            policy_kwargs=POLICY_KWARGS,
            tensorboard_log=str(LOGS_DIR),
            seed=args.seed,
            **PPO_CONFIG,
        )
        reset_ts = True

    # Write initial config so Godot starts at V0
    if args.binary:
        config_dir = os.path.dirname(os.path.abspath(args.binary))
        with open(os.path.join(config_dir, "rl_config.json"), "w") as f:
            json.dump({"rl_version": 0}, f)

    callbacks = [
        CurriculumCallback(binary_path=args.binary, verbose=1),
        CheckpointCallback(
            save_freq=max(50_000 // args.n_parallel, 1),
            save_path=str(CKPT_DIR),
            name_prefix="snooker_ppo",
            verbose=1,
        ),
    ]

    model.learn(
        total_timesteps=args.timesteps,
        callback=callbacks,
        progress_bar=True,
        reset_num_timesteps=reset_ts,
        tb_log_name="snooker_ppo",
    )

    save_path = str(MODELS_DIR / "snooker_ppo_final")
    model.save(save_path)
    print(f"\n✓  Final model saved → {save_path}.zip")
    print("   Copy to  recommendation-engine/models/snooker_ppo_final.zip")
    env.close()


# ═════════════════════════════════════════════════════════════════════════════
# Evaluation
# ═════════════════════════════════════════════════════════════════════════════
def evaluate(args: argparse.Namespace) -> None:
    model_file = args.model or str(MODELS_DIR / "snooker_ppo_final")
    if not Path(model_file + ".zip").exists():
        raise FileNotFoundError(f"No model at {model_file}.zip — train first.")

    # show_window=True: open a real, visible game window so you can watch the
    # trained agent play, instead of the headless mode used during training.
    env   = build_env(args.binary, n_parallel=1, speedup=1, seed=args.seed,
                       show_window=True)
    model = PPO.load(model_file, env=env)

    obs, _       = env.reset()
    total_reward = 0.0
    steps = episodes = 0
    print(f"Evaluating {model_file}  (Ctrl-C to stop)\n")
    while True:
        action, _ = model.predict(obs, deterministic=True)
        obs, reward, done, truncated, info = env.step(action)
        total_reward += float(reward); steps += 1
        if done or truncated:
            episodes += 1
            print(f"Episode {episodes:3d} | steps {steps:4d} | "
                  f"reward {total_reward:7.2f} | "
                  f"score {info.get('episode_score',0):3d} | "
                  f"reds {info.get('reds_potted',0):2d}")
            obs, _ = env.reset(); total_reward = 0.0; steps = 0


# ═════════════════════════════════════════════════════════════════════════════
# CLI
# ═════════════════════════════════════════════════════════════════════════════
def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Smart Snooker — Curriculum RL training",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--mode",       choices=["train","eval"], default="train")
    p.add_argument("--binary",     default=None,
                   help="Path to exported Godot binary. Omit = use editor.")
    p.add_argument("--timesteps",  type=int, default=3_000_000)
    p.add_argument("--n_parallel", type=int, default=1)
    p.add_argument("--speedup",    type=int, default=16)
    p.add_argument("--seed",       type=int, default=42)
    p.add_argument("--resume",     default=None,
                   help="Checkpoint .zip to resume training from.")
    p.add_argument("--model",      default=None,
                   help="Model path (no .zip) for --mode eval.")
    return p

if __name__ == "__main__":
    args = _parser().parse_args()
    train(args) if args.mode == "train" else evaluate(args)
