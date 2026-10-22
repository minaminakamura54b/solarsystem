"""Phase S 用: サーモと RGB の対応点から、サーモ座標 → RGB 座標の変換を求める（docs/PHASE_S_RUNBOOK.md 手順 6）。

サーモ画像と RGB 画像の両方で同じ対象（パネルの角など）を指定した点の組を JSON で渡す。
座標は各画像のピクセル座標。結果はアプリが使う正規化座標（0〜1）の変換と、RGB 画像上の誤差（ピクセル）を出す。
合格・不合格は判定しない（誤差を見て、固定値で足りるかを人が決める）。

  uv run python scripts/fit_rgb_alignment.py points.json

points.json の例:
  {"thermal_size": [640, 512], "rgb_size": [4000, 3000],
   "points": [{"thermal": [102, 88], "rgb": [655, 540]}, ...]}
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np


def load(path: Path) -> tuple[np.ndarray, np.ndarray, tuple[float, float], tuple[float, float]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    thermal_size = tuple(float(v) for v in data["thermal_size"])
    rgb_size = tuple(float(v) for v in data["rgb_size"])
    thermal = np.array([p["thermal"] for p in data["points"]], dtype=float)
    rgb = np.array([p["rgb"] for p in data["points"]], dtype=float)
    return thermal, rgb, thermal_size, rgb_size


def fit(thermal: np.ndarray, rgb: np.ndarray, thermal_size, rgb_size) -> dict:
    """正規化座標で「拡大率＋ずれ」（軸ごと）と「アフィン変換」を最小二乗で求める。"""
    if len(thermal) < 3:
        raise ValueError("対応点は 3 点以上必要です（画像の四隅付近に広げて 4 点以上を推奨）")
    t = thermal / np.array(thermal_size)
    r = rgb / np.array(rgb_size)

    scale_offset = {}
    predicted_so = np.zeros_like(r)
    for axis, name in ((0, "x"), (1, "y")):
        a = np.column_stack([t[:, axis], np.ones(len(t))])
        (scale, offset), *_ = np.linalg.lstsq(a, r[:, axis], rcond=None)
        scale_offset[f"scale_{name}"] = float(scale)
        scale_offset[f"offset_{name}"] = float(offset)
        predicted_so[:, axis] = a @ np.array([scale, offset])

    a = np.column_stack([t, np.ones(len(t))])
    matrix, *_ = np.linalg.lstsq(a, r, rcond=None)  # (3, 2)
    predicted_affine = a @ matrix

    return {
        "points": len(t),
        "scale_offset": {**scale_offset, **residuals(predicted_so, r, rgb_size)},
        "affine": {"matrix": matrix.T.round(6).tolist(), **residuals(predicted_affine, r, rgb_size)},
        "note": "matrix は [[a, b, c], [d, e, f]] で u_rgb = a*u + b*v + c、v_rgb = d*u + e*v + f（正規化座標）。"
                "誤差は RGB 画像上のピクセル。固定値で足りるかは、誤差と切り出しの大きさを比べて人が決める",
    }


def residuals(predicted: np.ndarray, actual: np.ndarray, rgb_size) -> dict:
    errors = np.linalg.norm((predicted - actual) * np.array(rgb_size), axis=1)
    return {"rms_error_px": round(float(np.sqrt((errors**2).mean())), 2), "max_error_px": round(float(errors.max()), 2)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="サーモ → RGB の座標変換を対応点から求める")
    parser.add_argument("points", type=Path, help="対応点の JSON")
    args = parser.parse_args(argv)
    try:
        result = fit(*load(args.points))
    except (KeyError, ValueError, OSError) as e:
        print(f"対応点を読めません: {e}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
