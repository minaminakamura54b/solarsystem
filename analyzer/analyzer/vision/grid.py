"""グリッド（4隅と行数・列数）からパネル領域を作る（docs/IMPROVEMENT_PLAN.md 5.5）。

- corners は左上・右上・右下・左下の順（0〜1 正規化）。射影変換でグリッドを rows × cols に分ける
- パネル番号は grid 順・各グリッド内は左上から行優先の連番
- 座標は連続座標（画素 i は [i, i+1) を占める）。パネルの温度は、パネルを長方形に引き伸ばした
  「整列パッチ」で扱う（形状の向き・帯の判定をパネルの辺に沿って行うため）
"""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from analyzer.contract import BBox, GridSpec


@dataclass
class PanelRegion:
    index: int
    grid_index: int
    row: int
    col: int
    quad: np.ndarray  # (4, 2) 画素座標。左上・右上・右下・左下
    orientation: str  # landscape = パネルの長辺がグリッドの横方向 / portrait = 縦方向

    def normalized_polygon(self, width: int, height: int) -> list[tuple[float, float]]:
        return [(round(float(x) / width, 6), round(float(y) / height, 6)) for x, y in self.quad]

    def normalized_bbox(self, width: int, height: int) -> BBox:
        xs = self.quad[:, 0]
        ys = self.quad[:, 1]
        return clip_bbox(xs.min() / width, ys.min() / height, xs.max() / width, ys.max() / height)


def panels_from_grids(grids: list[GridSpec], width: int, height: int) -> list[PanelRegion]:
    panels: list[PanelRegion] = []
    for grid_index, grid in enumerate(grids):
        corners_px = np.array([[x * width, y * height] for x, y in grid.corners], dtype=np.float32)
        unit = np.array([[0, 0], [grid.cols, 0], [grid.cols, grid.rows], [0, grid.rows]], dtype=np.float32)
        homography = cv2.getPerspectiveTransform(unit, corners_px)
        for row in range(grid.rows):
            for col in range(grid.cols):
                cell = np.array([[col, row], [col + 1, row], [col + 1, row + 1], [col, row + 1]], dtype=np.float32)
                quad = cv2.perspectiveTransform(cell.reshape(-1, 1, 2), homography).reshape(4, 2)
                panels.append(PanelRegion(len(panels), grid_index, row, col, quad, grid.panel_orientation))
    return panels


@dataclass
class RectifiedPanel:
    patch: np.ndarray  # (h, w) float32。パネルを長方形に引き伸ばした温度
    to_image: np.ndarray  # パッチ座標 → 画像座標の射影変換行列


def rectify(temps: np.ndarray, quad: np.ndarray) -> RectifiedPanel:
    """パネル領域を、辺の長さ（画素）に合わせた長方形のパッチに引き伸ばす。"""
    tl, tr, br, bl = quad
    width = max(2, int(round((np.linalg.norm(tr - tl) + np.linalg.norm(br - bl)) / 2)))
    height = max(2, int(round((np.linalg.norm(bl - tl) + np.linalg.norm(br - tr)) / 2)))
    target = np.array([[0, 0], [width, 0], [width, height], [0, height]], dtype=np.float32)
    to_patch = cv2.getPerspectiveTransform(quad.astype(np.float32), target)
    patch = cv2.warpPerspective(
        temps, to_patch, (width, height), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE
    )
    return RectifiedPanel(patch=patch, to_image=np.linalg.inv(to_patch))


def patch_bbox_to_image(bbox: tuple[int, int, int, int], to_image: np.ndarray, width: int, height: int) -> BBox:
    """パッチ上の画素範囲（x1, y1, x2, y2。両端を含む）を、画像の正規化 bbox にする。"""
    x1, y1, x2, y2 = bbox
    corners = np.array([[x1, y1], [x2 + 1, y1], [x2 + 1, y2 + 1], [x1, y2 + 1]], dtype=np.float32)
    mapped = cv2.perspectiveTransform(corners.reshape(-1, 1, 2), to_image).reshape(4, 2)
    return clip_bbox(
        mapped[:, 0].min() / width, mapped[:, 1].min() / height, mapped[:, 0].max() / width, mapped[:, 1].max() / height
    )


def clip_bbox(x1: float, y1: float, x2: float, y2: float) -> BBox:
    def clip(v: float) -> float:
        return round(min(1.0, max(0.0, float(v))), 6)

    return BBox(x1=clip(x1), y1=clip(y1), x2=clip(x2), y2=clip(y2))
