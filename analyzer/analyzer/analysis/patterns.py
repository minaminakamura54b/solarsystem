"""発熱パターンの分類（docs/IMPROVEMENT_PLAN.md 5.7）。パラメータはすべて設定値。

パネルごとに2つの判定を独立に行い、それぞれの結果を出力する（pipeline.py）:

  局所的な判定（パネル自身の中央値から見た高温領域）→ classify_local
  - hotspot        : 領域が1つ、面積比 < hotspot_max_area_ratio、縦横比 < hotspot_max_aspect
  - multi_hotspot  : 領域が2つ以上で、どの領域も hotspot の条件を満たす
  - substring_bypass: 領域が1つで bypass_pattern の帯に一致（セル構成と bypass_pattern が登録されている場合だけ）
  - partial_module : 上のどれにも当てはまらない高温領域すべて（ルールセットに other の閾値が無いため other は出さない）

  基準温度からの判定（パネル平均の ΔT が module_wide の mild 以上のとき、基準温度 + その mild を超える領域）
  - module_wide    : 面積比 ≥ module_wide_min_area_ratio（pipeline.py で判定）
  - substring_bypass: すべての領域が bypass_pattern の帯（1本以上の連続した帯）に一致し、帯の合計が bands 未満 → classify_baseline
  - partial_module : それ以外

帯の向き（band_axis）は「その辺を bands 等分した帯」と解釈する（実画像で確認するまでの仮の解釈）。
"""

from __future__ import annotations

import numpy as np

from analyzer.analysis.detection import HotRegion
from analyzer.contract import BypassPattern, ModuleSpec
from analyzer.params import AnalyzerParams


def _region_info(regions: list[HotRegion], total: int, params: AnalyzerParams) -> list[dict]:
    return [
        {
            "area_ratio": round(r.area_px / total, 4),
            "aspect": round(r.aspect, 3),
            "hotspot_like": r.area_px / total < params.hotspot_max_area_ratio and r.aspect < params.hotspot_max_aspect,
        }
        for r in regions
    ]


def _bypass_ready(module: ModuleSpec) -> bool:
    return module.cell_layout is not None and module.bypass_pattern is not None


NOT_EVALUATED = {"evaluated": False, "reason": "モジュールのセル構成または bypass_pattern が未登録"}


def classify_local(
    regions: list[HotRegion], patch_shape: tuple[int, int], orientation: str, module: ModuleSpec, params: AnalyzerParams
) -> tuple[str, dict, int | None]:
    """局所的な判定の高温領域を分類する。戻り値: (種類, 分類根拠, 作動した帯の本数)"""
    total = patch_shape[0] * patch_shape[1]
    region_info = _region_info(regions, total, params)
    shape: dict = {"regions": len(regions), "region_details": region_info}

    if len(regions) == 1 and region_info[0]["hotspot_like"]:
        shape["criteria"] = "領域1つ・面積比と縦横比が hotspot の条件内"
        return "hotspot", shape, None
    if len(regions) >= 2 and all(r["hotspot_like"] for r in region_info):
        shape["criteria"] = "領域2つ以上・すべて hotspot の条件内"
        return "multi_hotspot", shape, None

    if not _bypass_ready(module):
        shape["bypass_match"] = NOT_EVALUATED
    elif len(regions) == 1:
        bands, details = bypass_bands(regions[0], patch_shape, orientation, module.bypass_pattern)
        shape["bypass_match"] = {"evaluated": True, "active_bands": bands, "bands_total": module.bypass_pattern.bands, "regions": [details]}
        if bands is not None:
            shape["criteria"] = f"領域1つ・bypass_pattern の帯 {bands} 本に一致"
            return "substring_bypass", shape, bands

    shape["criteria"] = "hotspot・multi_hotspot・substring_bypass のいずれにも当てはまらない"
    return "partial_module", shape, None


def classify_baseline(
    regions: list[HotRegion], patch_shape: tuple[int, int], orientation: str, module: ModuleSpec, params: AnalyzerParams
) -> tuple[str, dict, int | None]:
    """基準温度からの判定の領域（module_wide に当たらないもの）を分類する。戻り値: (種類, 分類根拠, 作動した帯の本数)"""
    total = patch_shape[0] * patch_shape[1]
    shape: dict = {"regions": len(regions), "region_details": _region_info(regions, total, params), "area_ratio_basis": "baseline"}

    if not _bypass_ready(module):
        shape["bypass_match"] = NOT_EVALUATED
    else:
        pattern = module.bypass_pattern
        matches = [bypass_bands(region, patch_shape, orientation, pattern) for region in regions]
        counts = [bands for bands, _ in matches]
        active = sum(counts) if all(c is not None for c in counts) else None
        if active is not None and active >= pattern.bands:
            active = None  # すべての帯が作動しているなら帯ではない（module_wide の面積比に届かない場合は partial_module）
        shape["bypass_match"] = {
            "evaluated": True, "active_bands": active, "bands_total": pattern.bands, "regions": [d for _, d in matches],
        }
        if active is not None:
            shape["criteria"] = f"基準温度から測った領域が bypass_pattern の帯（合計 {active} 本）に一致"
            return "substring_bypass", shape, active

    shape["criteria"] = "基準温度から測った領域が module_wide・substring_bypass のいずれにも当てはまらない"
    return "partial_module", shape, None


def bypass_bands(region: HotRegion, patch_shape: tuple[int, int], orientation: str, pattern: BypassPattern) -> tuple[int | None, dict]:
    """領域が、連続した k 本の帯（k = 1 〜 bands − 1）と一致するか。一致すれば k を返す。

    band_axis の辺を bands 等分した帯として扱う（short_side なら短辺を等分し、帯は長辺方向に伸びる）。
    パッチ上で、landscape はパネルの長辺が横（x）、portrait は縦（y）。k 本の帯との一致の条件:
      - 面積比が k × band_area_ratio ± tolerance
      - 帯が伸びる方向に、パネルの (1 − tolerance) 以上にわたっている
      - 等分する方向の幅が、パネルの (k × band_area_ratio + tolerance) 以下
    一致しない場合の checks は、面積比がいちばん近い k に対する結果。
    """
    height, width = patch_shape
    long_axis = "x" if orientation == "landscape" else "y"
    short_axis = "y" if long_axis == "x" else "x"
    divided_axis = short_axis if pattern.band_axis == "short_side" else long_axis
    extent = {"x": region.width / width, "y": region.height / height}
    divided_extent = extent[divided_axis]
    span_extent = extent["y" if divided_axis == "x" else "x"]
    area_ratio = region.area_px / (width * height)

    candidates = range(1, pattern.bands)
    results = {}
    for k in candidates:
        expected = k * pattern.band_area_ratio
        results[k] = {
            "area_ratio": abs(area_ratio - expected) <= pattern.tolerance,
            "spans_panel": span_extent >= 1 - pattern.tolerance,
            "band_width": divided_extent <= expected + pattern.tolerance,
        }
    matched = next((k for k in candidates if all(results[k].values())), None)
    nearest = matched or min(candidates, key=lambda k: abs(area_ratio - k * pattern.band_area_ratio), default=None)
    details = {
        "evaluated": True,
        "matched_bands": matched,
        "divided_axis": divided_axis,
        "area_ratio": round(area_ratio, 4),
        "span_extent": round(span_extent, 4),
        "divided_extent": round(divided_extent, 4),
        "compared_bands": nearest,
        "checks": results.get(nearest, {}),
    }
    return matched, details


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
