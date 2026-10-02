"""解析から除外するパネルの判定（docs/IMPROVEMENT_PLAN.md 5.5）。

- 画像の端に接している、または画像内に入っている面積が期待値の 70% 未満のパネル → edge_cut（隣の画像で拾う前提）
- グレア疑い（glare_suspect）は除外ではなく異常のフラグ。analysis/patterns.py で付ける
- 影は低温側なので検出対象外（高温側しか検出しない）
"""

from __future__ import annotations

import cv2
import numpy as np


def edge_cut(quad: np.ndarray, width: int, height: int, margin_px: float, min_inside_ratio: float) -> tuple[bool, float]:
    """(除外するか, 画像内に入っている面積の割合) を返す。"""
    xs = quad[:, 0]
    ys = quad[:, 1]
    touches_edge = bool(
        (xs < margin_px).any() or (xs > width - margin_px).any() or (ys < margin_px).any() or (ys > height - margin_px).any()
    )
    inside = inside_ratio(quad, width, height)
    return touches_edge or inside < min_inside_ratio, inside


def inside_ratio(quad: np.ndarray, width: int, height: int) -> float:
    polygon = quad.astype(np.float32)
    area = abs(cv2.contourArea(polygon))
    if area <= 0:
        return 0.0
    image_rect = np.array([[0, 0], [width, 0], [width, height], [0, height]], dtype=np.float32)
    intersection, _ = cv2.intersectConvexConvex(polygon, image_rect)
    return round(min(1.0, float(intersection) / area), 4)
