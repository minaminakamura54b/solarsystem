"""発熱パターンの分類（docs/IMPROVEMENT_PLAN.md 5.7）。パラメータはすべて設定値。

module_wide はパネル平均で先に判定する（pipeline.py）。ここではパネル内の高温領域を分類する:
  - hotspot        : 領域が1つ、面積比 < hotspot_max_area_ratio、縦横比 < hotspot_max_aspect
  - multi_hotspot  : 領域が2つ以上で、どの領域も hotspot の条件を満たす
  - substring_bypass: 領域が1つで bypass_pattern に一致（モジュールのセル構成と bypass_pattern が登録されている場合だけ）
  - partial_module : 上のどれにも当てはまらない高温領域すべて（ルールセットに other の閾値が無いため other は出さない）
"""

from __future__ import annotations

import numpy as np

from analyzer.analysis.detection import HotRegion
from analyzer.contract import BypassPattern, ModuleSpec
from analyzer.params import AnalyzerParams


def classify(
    regions: list[HotRegion], patch_shape: tuple[int, int], orientation: str, module: ModuleSpec, params: AnalyzerParams
) -> tuple[str, dict]:
    total = patch_shape[0] * patch_shape[1]
    region_info = [
        {
            "area_ratio": round(r.area_px / total, 4),
            "aspect": round(r.aspect, 3),
            "hotspot_like": r.area_px / total < params.hotspot_max_area_ratio and r.aspect < params.hotspot_max_aspect,
        }
        for r in regions
    ]
    shape: dict = {"regions": len(regions), "region_details": region_info}

    if len(regions) == 1 and region_info[0]["hotspot_like"]:
        shape["criteria"] = "領域1つ・面積比と縦横比が hotspot の条件内"
        return "hotspot", shape
    if len(regions) >= 2 and all(r["hotspot_like"] for r in region_info):
        shape["criteria"] = "領域2つ以上・すべて hotspot の条件内"
        return "multi_hotspot", shape

    bypass_ready = module.cell_layout is not None and module.bypass_pattern is not None
    if len(regions) == 1 and bypass_ready:
        matched, details = bypass_match(regions[0], patch_shape, orientation, module.bypass_pattern)
        shape["bypass_match"] = details
        if matched:
            shape["criteria"] = "領域1つ・bypass_pattern に一致"
            return "substring_bypass", shape
    if not bypass_ready:
        shape["bypass_match"] = {"evaluated": False, "reason": "モジュールのセル構成または bypass_pattern が未登録"}

    shape["criteria"] = "hotspot・multi_hotspot・substring_bypass のいずれにも当てはまらない"
    return "partial_module", shape


def bypass_match(region: HotRegion, patch_shape: tuple[int, int], orientation: str, pattern: BypassPattern) -> tuple[bool, dict]:
    """band_axis の辺を bands 等分した帯と一致するか。

    パッチ上で、landscape はパネルの長辺が横（x）、portrait は縦（y）。
    short_side なら短辺を等分する（帯は長辺方向に伸びる）。一致の条件:
      - 面積比が band_area_ratio ± tolerance
      - 帯が伸びる方向に、パネルの (1 − tolerance) 以上にわたっている
      - 等分する方向の幅が、パネルの (band_area_ratio + tolerance) 以下
    """
    height, width = patch_shape
    long_axis = "x" if orientation == "landscape" else "y"
    short_axis = "y" if long_axis == "x" else "x"
    divided_axis = short_axis if pattern.band_axis == "short_side" else long_axis
    extent = {"x": region.width / width, "y": region.height / height}
    divided_extent = extent[divided_axis]
    span_extent = extent["y" if divided_axis == "x" else "x"]
    area_ratio = region.area_px / (width * height)

    checks = {
        "area_ratio": abs(area_ratio - pattern.band_area_ratio) <= pattern.tolerance,
        "spans_panel": span_extent >= 1 - pattern.tolerance,
        "band_width": divided_extent <= pattern.band_area_ratio + pattern.tolerance,
    }
    details = {
        "evaluated": True,
        "divided_axis": divided_axis,
        "area_ratio": round(area_ratio, 4),
        "span_extent": round(span_extent, 4),
        "divided_extent": round(divided_extent, 4),
        "checks": checks,
    }
    return all(checks.values()), details


def union_mask(regions: list[HotRegion]) -> np.ndarray:
    mask = np.zeros_like(regions[0].mask, dtype=bool)
    for region in regions:
        mask |= region.mask
    return mask


def union_bbox(regions: list[HotRegion]) -> tuple[int, int, int, int]:
    return (
        min(r.bbox[0] for r in regions),
        min(r.bbox[1] for r in regions),
        max(r.bbox[2] for r in regions),
        max(r.bbox[3] for r in regions),
    )


def row_runs(cells: list[tuple[int, int, int, int]], min_panels: int) -> list[tuple[int, int, list[int]]]:
    """同じグリッドの同じ行で隣接する（列が連続する）パネルの並びのうち、min_panels 枚以上のもの。

    cells: (grid_index, row, col, panel_index)。戻り値: (grid_index, row, [panel_index, ...])
    """
    runs = []
    by_row: dict[tuple[int, int], list[tuple[int, int]]] = {}
    for grid_index, row, col, panel_index in cells:
        by_row.setdefault((grid_index, row), []).append((col, panel_index))
    for (grid_index, row), items in sorted(by_row.items()):
        items.sort()
        current = [items[0]]
        for col, panel_index in items[1:]:
            if col == current[-1][0] + 1:
                current.append((col, panel_index))
            else:
                if len(current) >= min_panels:
                    runs.append((grid_index, row, [p for _, p in current]))
                current = [(col, panel_index)]
        if len(current) >= min_panels:
            runs.append((grid_index, row, [p for _, p in current]))
    return runs
