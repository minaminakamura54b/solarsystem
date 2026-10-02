"""解析の流れ（docs/IMPROVEMENT_PLAN.md 5.5〜5.7）。

温度行列 → グリッドからパネル領域 → 画像端のパネルを除外 → パネルごとの特徴量 → 基準温度
→ パネルごとに module_wide を先に判定 → パネル内の高温領域を分類 → mild 以上だけを異常として出力
→ 同じグリッドの同じ行で隣接する module_wide を panel_row_group にまとめる。

severity は出さない（Rails がルールセットの閾値で付ける）。
"""

from __future__ import annotations

import numpy as np

from analyzer.analysis import patterns
from analyzer.analysis.baseline import compute_baseline
from analyzer.analysis.detection import MildThresholds, hot_regions
from analyzer.analysis.features import PanelStats, panel_stats
from analyzer.contract import (
    AnalysisResult,
    AnomalyResult,
    BaselineInfo,
    GridSpec,
    GroupResult,
    ImageInfo,
    IrradianceInput,
    ModuleSpec,
    PanelResult,
    RulesInput,
)
from analyzer.errors import EXIT_INSUFFICIENT_BASELINE, EXIT_OK, GridError
from analyzer.params import AnalyzerParams
from analyzer.thermal import quality
from analyzer.vision.exclusions import edge_cut
from analyzer.vision.grid import PanelRegion, panels_from_grids, patch_bbox_to_image, rectify


def r(value: float | None, digits: int = 3) -> float | None:
    return None if value is None else round(float(value), digits)


def image_info(temps: np.ndarray, source: str) -> ImageInfo:
    t_min, t_max = quality.temperature_range(temps)
    height, width = temps.shape
    return ImageInfo(
        width=width, height=height, is_radiometric=True, source=source,
        t_min=r(t_min), t_max=r(t_max), blur_score=r(quality.blur_score(temps), 4),
    )


def analyze(
    temps: np.ndarray,
    source: str,
    grids: list[GridSpec],
    module: ModuleSpec,
    rules: RulesInput,
    irradiance: IrradianceInput,
    params: AnalyzerParams,
) -> tuple[AnalysisResult, int]:
    if not grids:
        raise GridError("grid_required", "グリッドが指定されていません（解析にはグリッドが必要です）")

    height, width = temps.shape
    detection = rules.detection_params
    mild = MildThresholds.build(rules, irradiance)
    regions = panels_from_grids(grids, width, height)

    # 画像端のパネルを除外し、残りのパネルの特徴量を出す
    rectified = {}
    stats: dict[int, PanelStats] = {}
    exclusion: dict[int, tuple[bool, float]] = {}
    for panel in regions:
        excluded, inside = edge_cut(panel.quad, width, height, params.edge_margin_px, params.edge_min_inside_ratio)
        exclusion[panel.index] = (excluded, inside)
        if excluded:
            continue
        rectified[panel.index] = rectify(temps, panel.quad)
        stats[panel.index] = panel_stats(rectified[panel.index].patch)

    baseline = compute_baseline({i: s.t_mean for i, s in stats.items()}, detection)
    result = AnalysisResult(
        status="completed",
        image=image_info(temps, source),
        irradiance=irradiance,
        rule_version=rules.version,
        baseline=BaselineInfo(
            temp=r(baseline.temp), panel_count=baseline.panel_count, required_count=baseline.required_count,
            mad=r(baseline.mad, 4), mad_used=r(baseline.mad_used, 4),
        ),
        panels=[_panel_result(p, stats.get(p.index), exclusion[p.index], baseline.baseline_indices, width, height) for p in regions],
    )

    if not baseline.sufficient:
        result.status = "needs_review"
        result.review_reason = "insufficient_baseline"
        result.message = (
            f"基準温度を出すための正常パネルが足りません（{baseline.panel_count}枚 / 必要 {baseline.required_count}枚）。"
            "パネル群全体が温まっている可能性があります"
        )
        return result, EXIT_INSUFFICIENT_BASELINE

    base = baseline.temp
    module_wide_cells = []
    for panel in regions:
        if panel.index not in stats:
            continue
        anomaly = _detect_panel(panel, rectified[panel.index], stats[panel.index], base, mild, module, rules, params, width, height)
        if anomaly is None:
            continue
        result.anomalies.append(anomaly)
        if anomaly.anomaly_type == "module_wide":
            module_wide_cells.append((panel.grid_index, panel.row, panel.col, panel.index))

    deltas = {a.panel_index: a.delta_t for a in result.anomalies if a.anomaly_type == "module_wide"}
    for grid_index, row, indices in patterns.row_runs(module_wide_cells, detection.row_group_min_panels):
        delta = float(np.median([deltas[i] for i in indices]))
        if delta < mild["panel_row_group"]:
            continue
        result.groups.append(
            GroupResult(
                grid_index=grid_index, row=row, panel_indices=indices,
                delta_t=r(delta), normalized_delta_t=r(mild.normalized(delta)), threshold_basis=mild.basis,
            )
        )
    return result, EXIT_OK


def _panel_result(panel: PanelRegion, stats: PanelStats | None, exclusion, baseline_indices, width, height) -> PanelResult:
    excluded, inside = exclusion
    return PanelResult(
        index=panel.index, grid_index=panel.grid_index, row=panel.row, col=panel.col,
        polygon=panel.normalized_polygon(width, height), bbox=panel.normalized_bbox(width, height),
        t_max=r(stats.t_max) if stats else None, t_mean=r(stats.t_mean) if stats else None,
        t_min=r(stats.t_min) if stats else None, p95=r(stats.p95) if stats else None,
        excluded=excluded, exclude_reason="edge_cut" if excluded else None, inside_ratio=inside,
        is_baseline=panel.index in baseline_indices,
    )


def _detect_panel(panel, rect, stats: PanelStats, base, mild: MildThresholds, module, rules, params, width, height):
    patch = rect.patch
    flags = [] if mild.basis == "normalized" else ["unnormalized"]

    # module_wide を先に判定する。面積比は「基準温度 + mild を超える画素の割合」（パネル自身の中央値ではなく基準温度から測る）
    panel_delta = stats.t_mean - base
    module_wide_area = float((patch > base + mild["module_wide"]).mean())
    if panel_delta >= mild["module_wide"] and module_wide_area >= params.module_wide_min_area_ratio:
        h, w = patch.shape
        return AnomalyResult(
            panel_index=panel.index, anomaly_type="module_wide",
            bbox=patch_bbox_to_image((0, 0, w - 1, h - 1), rect.to_image, width, height),
            measure="panel_mean", delta_t=r(panel_delta), normalized_delta_t=r(mild.normalized(panel_delta)),
            threshold_basis=mild.basis, area_ratio=r(module_wide_area, 4),
            t_max=r(stats.t_max), t_mean=r(stats.t_mean), t_min=r(stats.t_min), baseline_temp=r(base),
            shape={"criteria": "パネル平均の ΔT が mild 以上・基準温度から測った面積比が module_wide の条件以上", "area_ratio_basis": "baseline"},
            flags=flags,
        )

    found, threshold = hot_regions(patch, rules.detection_params)
    if not found:
        return None

    anomaly_type, shape = patterns.classify(found, patch.shape, panel.orientation, module, params)
    mask = patterns.union_mask(found)
    values = patch[mask].astype(np.float64)
    if anomaly_type in ("hotspot", "multi_hotspot"):
        measure, delta = "region_max", float(values.max()) - base
    else:
        measure, delta = "region_mean", float(values.mean()) - base
    if delta < mild[anomaly_type]:
        return None

    total = patch.size
    if any(region.area_px / total < params.glare_max_area_ratio for region in found):
        flags.append("glare_suspect")
    shape["region_threshold_c"] = r(threshold)

    return AnomalyResult(
        panel_index=panel.index, anomaly_type=anomaly_type,
        bbox=patch_bbox_to_image(patterns.union_bbox(found), rect.to_image, width, height),
        measure=measure, delta_t=r(delta), normalized_delta_t=r(mild.normalized(delta)), threshold_basis=mild.basis,
        area_ratio=r(int(mask.sum()) / total, 4),
        t_max=r(values.max()), t_mean=r(values.mean()), t_min=r(values.min()), baseline_temp=r(base),
        shape=shape, flags=flags,
    )
