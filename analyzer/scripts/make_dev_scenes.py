"""開発用の合成シーンを作る（Rails の bin/rails dev:synthetic_inspection から呼ぶ）。顧客の実画像は使わない。

出力先に、シーンごとの温度行列（.npy）・表示用のプレビュー（.png）と、全シーンのメタデータ（scenes.json）を書く。
  uv run python scripts/make_dev_scenes.py --out ../tmp/dev_scenes
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tests.fixtures.make_synthetic import make_gapped_scene, make_scene  # noqa: E402


def preview(temps: np.ndarray) -> np.ndarray:
    """温度行列を疑似カラーの画像にする（表示専用。解析には使わない）。"""
    low, high = np.percentile(temps, [1, 99])
    scaled = np.clip((temps - low) / max(high - low, 1e-6), 0, 1)
    return cv2.applyColorMap((scaled * 255).astype(np.uint8), cv2.COLORMAP_INFERNO)


def scenes():
    hotspot = make_scene(seed=1).heat_rect(0, 1, 2, 0.4, 0.33, 0.5, 0.5, 15.0)
    band = make_scene(seed=2).heat_rect(0, 2, 3, 0.0, 0.0, 1.0, 2 / 3, 6.0).heat_rect(0, 2, 3, 0.4, 0.17, 0.5, 0.33, 10.0)
    row = make_scene(seed=3)
    for col in range(1, 5):
        row.heat_panel(0, 0, col, 3.0)
    gapped = make_gapped_scene(seed=4)
    gapped[110 + 36 : 110 + 36 + 6, 120 + 2 * 56 + 20 : 120 + 2 * 56 + 26] += 12.0  # 2行3列目のパネルにホットスポット

    return [
        ("DEV_0001_T", hotspot.temps, "単セルのホットスポット", hotspot.grids),
        ("DEV_0002_T", band.temps, "2/3 の帯 ＋ その中のホットスポット", band.grids),
        ("DEV_0003_T", row.temps, "同じ行で連続する4枚のモジュール全体の発熱", row.grids),
        ("DEV_0004_T", gapped, "パネルの間に隙間がある配列（グリッドの自動提案を試せる）＋ ホットスポット", None),
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    metadata = []
    for i, (name, temps, description, grids) in enumerate(scenes()):
        np.save(out / f"{name}.npy", temps.astype(np.float32))
        cv2.imwrite(str(out / f"{name}.png"), preview(temps))
        height, width = temps.shape
        metadata.append({
            "name": name, "description": description, "width": width, "height": height,
            "captured_at_offset_s": i * 20, "gps_lat": 35.6625 + i * 0.0001, "gps_lng": 138.5683,
            "altitude_m": 30.0, "gimbal_pitch": -90.0, "gimbal_yaw": 10.0,
            "expected_grids": grids,
        })
    (out / "scenes.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{len(metadata)} scenes -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
