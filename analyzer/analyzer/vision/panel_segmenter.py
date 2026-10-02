"""温度行列からパネル配列を自動で見つけ、グリッドを提案する（propose-grid 専用。解析には使わない）。

古典的な画像処理: 8bit に正規化 → 平滑化 → 二値化（大津の方法。明暗両方を試す）→ 長方形の輪郭を抽出
→ 大きさのそろった長方形を行に分ける → 行ごとの枚数がそろっていればグリッドとして提案する。
精度は低くてよい。グリッドの整合性がとれなければ GridError（終了コード 3）にする。
"""

from __future__ import annotations

import cv2
import numpy as np

from analyzer.contract import GridProposal
from analyzer.errors import GridError
from analyzer.params import AnalyzerParams


def propose_grid(temps: np.ndarray, params: AnalyzerParams) -> GridProposal:
    height, width = temps.shape
    image = _to_uint8(temps)
    blurred = cv2.GaussianBlur(image, (3, 3), 0)
    _, binary = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)

    for candidate in (binary, cv2.bitwise_not(binary)):
        proposal = _grid_from_binary(candidate, width, height, params)
        if proposal is not None:
            return proposal
    raise GridError("panel_extraction_failed", "パネル配列を見つけられませんでした（グリッドを手動で指定してください）")


def _to_uint8(temps: np.ndarray) -> np.ndarray:
    low, high = np.percentile(temps, [1, 99])
    if high - low < 1e-6:
        return np.zeros(temps.shape, dtype=np.uint8)
    scaled = np.clip((temps - low) / (high - low), 0, 1)
    return (scaled * 255).astype(np.uint8)


def _grid_from_binary(binary: np.ndarray, width: int, height: int, params: AnalyzerParams) -> GridProposal | None:
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    min_area = params.segmenter_min_area_ratio * width * height
    rects = []
    for contour in contours:
        area = cv2.contourArea(contour)
        if area < min_area:
            continue
        rect = cv2.minAreaRect(contour)
        (cx, cy), (rw, rh), _ = rect
        if rw * rh <= 0 or area / (rw * rh) < params.segmenter_min_rectangularity:
            continue
        x, y, w, h = cv2.boundingRect(contour)
        if x <= 0 or y <= 0 or x + w >= width or y + h >= height:
            continue  # 画像の端に接している領域は背景とみなす
        rects.append({"cx": cx, "cy": cy, "w": w, "h": h, "area": area, "points": contour.reshape(-1, 2)})

    if len(rects) < params.segmenter_min_panels:
        return None

    median_area = float(np.median([r["area"] for r in rects]))
    tol = params.segmenter_size_tolerance
    rects = [r for r in rects if (1 - tol) * median_area <= r["area"] <= (1 + tol) * median_area]
    if len(rects) < params.segmenter_min_panels:
        return None

    median_h = float(np.median([r["h"] for r in rects]))
    rows: list[list[dict]] = []
    for rect in sorted(rects, key=lambda r: r["cy"]):
        if rows and abs(rect["cy"] - np.mean([r["cy"] for r in rows[-1]])) <= 0.5 * median_h:
            rows[-1].append(rect)
        else:
            rows.append([rect])

    counts = {len(row) for row in rows}
    if len(counts) != 1 or counts.pop() < 2:
        return None  # 行ごとの枚数がそろわない、または1列しかない

    points = np.vstack([r["points"] for r in rects]).astype(np.float32)
    box = cv2.boxPoints(cv2.minAreaRect(points))
    corners = _order_corners(box)
    median_w = float(np.median([r["w"] for r in rects]))
    return GridProposal(
        rows=len(rows),
        cols=len(rows[0]),
        corners=[(round(float(x) / width, 6), round(float(y) / height, 6)) for x, y in corners],
        panel_orientation="landscape" if median_w >= median_h else "portrait",
        panel_count=len(rects),
    )


def _order_corners(points: np.ndarray) -> np.ndarray:
    """4点を左上・右上・右下・左下の順に並べる。"""
    s = points.sum(axis=1)
    d = np.diff(points, axis=1).ravel()
    return np.array([points[np.argmin(s)], points[np.argmin(d)], points[np.argmax(s)], points[np.argmax(d)]])
