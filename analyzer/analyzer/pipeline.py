"""解析の流れ（docs/IMPROVEMENT_PLAN.md 5.5〜5.7）。

温度行列 → グリッドからパネル領域 → 画像端のパネルを除外 → パネルごとの特徴量 → 基準温度
→ パネルごとに2つの判定を独立に行い、それぞれ mild 以上だけを異常として出力する
   - 基準温度からの判定: パネル平均の ΔT が module_wide の mild 以上なら、基準温度 + その mild を超える領域で
     module_wide / substring_bypass / partial_module を判定する
   - 局所的な判定: パネル自身の中央値から見た高温領域で hotspot / multi_hotspot / substring_bypass / partial_module を判定する
   - 両方に当てはまれば別々に出力する（例: 2/3 の帯 ＋ その中のホットスポット）。ただし基準温度からの判定で異常が出た
     パネルでは、局所的な判定の substring_bypass / partial_module は同じ発熱の二重計上になるため出さない
→ 同じグリッドの同じ行で隣接する module_wide を panel_row_group にまとめる。

severity は出さない（Rails がルールセットの閾値で付ける）。
"""

from __future__ import annotations

import numpy as np

from analyzer.analysis import patterns
from analyzer.analysis.baseline import compute_baseline
from analyzer.analysis.detection import MildThresholds, baseline_regions, hot_regions
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
        found = _detect_panel(panel, rectified[panel.index], stats[panel.index], base, mild, module, rules, params, width, height)
        result.anomalies.extend(found)
        if any(a.anomaly_type == "module_wide" for a in found):
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


def _detect_panel(panel, rect, stats: PanelStats, base, mild: MildThresholds, module, rules, params, width, height) -> list[AnomalyResult]:
    patch = rect.patch
    flags = [] if mild.basis == "normalized" else ["unnormalized"]
    common = {"panel_index": panel.index, "threshold_basis": mild.basis, "baseline_temp": r(base)}
    anomalies: list[AnomalyResult] = []

    # ── 基準温度からの判定 ──
    # パネル平均の ΔT が module_wide の mild 以上なら、基準温度 + その mild を超える画素で領域を取り直す
    # （パネルの大部分が温まるとパネル自身の中央値が高温側になり、局所的な判定では見つからないため）
    panel_delta = stats.t_mean - base
    if panel_delta >= mild["module_wide"]:
        above = patch > base + mild["module_wide"]
        area = float(above.mean())
        if area >= params.module_wide_min_area_ratio:
            h, w = patch.shape
            anomalies.append(AnomalyResult(
                **common, anomaly_type="module_wide", detection="baseline",
                bbox=patch_bbox_to_image((0, 0, w - 1, h - 1), rect.to_image, width, height),
                measure="panel_mean", delta_t=r(panel_delta), normalized_delta_t=r(mild.normalized(panel_delta)),
                area_ratio=r(area, 4), t_max=r(stats.t_max), t_mean=r(stats.t_mean), t_min=r(stats.t_min),
                shape={"criteria": "パネル平均の ΔT が mild 以上・基準温度から測った面積比が module_wide の条件以上", "area_ratio_basis": "baseline"},
                flags=list(flags),
            ))
        else:
            regions = baseline_regions(patch, base + mild["module_wide"], params.min_region_pixels)
            if regions:
                anomaly_type, shape, active_bands = patterns.classify_baseline(regions, patch.shape, panel.orientation, module, params)
                anomaly = _region_anomaly(regions, patch, rect, anomaly_type, shape, active_bands, "baseline", base, mild, flags, common, params, width, height)
                if anomaly:
                    anomalies.append(anomaly)

    # ── 局所的な判定（パネル自身の中央値から見た高温領域）──
    found, threshold = hot_regions(patch, rules.detection_params, params.min_region_pixels)
    if found:
        anomaly_type, shape, active_bands = patterns.classify_local(found, patch.shape, panel.orientation, module, params)
        duplicate = anomalies and anomaly_type in ("substring_bypass", "partial_module")
        if not duplicate:
            shape["region_threshold_c"] = r(threshold)
            anomaly = _region_anomaly(found, patch, rect, anomaly_type, shape, active_bands, "local", base, mild, flags, common, params, width, height)
            if anomaly:
                anomalies.append(anomaly)
    return anomalies


def _region_anomaly(regions, patch, rect, anomaly_type, shape, active_bands, detection, base, mild, flags, common, params, width, height):
    """高温領域から異常を作る。ΔT が mild 未満なら None。"""
    mask = patterns.union_mask(regions)
    values = patch[mask].astype(np.float64)
    if anomaly_type in ("hotspot", "multi_hotspot"):
        measure, delta = "region_max", float(values.max()) - base
    else:
        measure, delta = "region_mean", float(values.mean()) - base
    if delta < mild[anomaly_type]:
        return None

    total = patch.size
    region_flags = list(flags)
    if any(region.area_px / total < params.glare_max_area_ratio for region in regions):
        region_flags.append("glare_suspect")

    return AnomalyResult(
        **common, anomaly_type=anomaly_type, detection=detection, active_bands=active_bands,
        bbox=patch_bbox_to_image(patterns.union_bbox(regions), rect.to_image, width, height),
        measure=measure, delta_t=r(delta), normalized_delta_t=r(mild.normalized(delta)),
        area_ratio=r(int(mask.sum()) / total, 4),
        t_max=r(values.max()), t_mean=r(values.mean()), t_min=r(values.min()),
        shape=shape, flags=region_flags,
    )
