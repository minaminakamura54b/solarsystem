"""入出力の約束（docs/IMPROVEMENT_PLAN.md 5.2 / 5.3）。schema_version を持ち、Rails はこれに沿って検証する。

座標はすべて画像サイズで正規化した 0〜1。Python は severity を出さない。
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from analyzer import ANALYZER_VERSION, SCHEMA_VERSION

ANOMALY_TYPES = ("hotspot", "multi_hotspot", "substring_bypass", "module_wide", "partial_module", "panel_row_group")
Measure = Literal["region_max", "region_mean", "panel_mean"]
ThresholdBasis = Literal["normalized", "raw"]


# ── 入力 ─────────────────────────────────────────────


class GridSpec(BaseModel):
    """パネル配列のグリッド。corners は左上・右上・右下・左下の順（0〜1 正規化）。"""

    model_config = ConfigDict(extra="ignore")

    rows: int = Field(gt=0)
    cols: int = Field(gt=0)
    corners: list[tuple[float, float]]
    panel_orientation: Literal["portrait", "landscape"] = "landscape"

    @field_validator("corners")
    @classmethod
    def four_normalized_corners(cls, value):
        if len(value) != 4:
            raise ValueError("corners は4点（左上・右上・右下・左下）にしてください")
        for x, y in value:
            if not (-1.0 <= x <= 2.0 and -1.0 <= y <= 2.0):
                raise ValueError("corners は画像サイズで正規化した座標にしてください")
        return value


class BypassPattern(BaseModel):
    """バイパスダイオード作動時の発熱パターン（Site.bypass_pattern）。

    band_axis の辺を bands 等分した帯として扱う（例: short_side → 短辺を等分し、長辺方向に伸びる帯）。
    """

    model_config = ConfigDict(extra="ignore")

    layout: str | None = None
    bands: int = Field(gt=0)
    band_axis: Literal["short_side", "long_side"]
    band_area_ratio: float = Field(gt=0, lt=1)
    tolerance: float = Field(ge=0, lt=1)


class ModuleSpec(BaseModel):
    model_config = ConfigDict(extra="ignore")

    cell_layout: Literal["full_cell", "half_cut", "other"] | None = None
    substring_count: int = Field(default=3, gt=0)
    bypass_pattern: BypassPattern | None = None


class DetectionParams(BaseModel):
    """ルールセットの detection_params（docs/IMPROVEMENT_PLAN.md 4.5 / 5.6）。"""

    model_config = ConfigDict(extra="ignore")

    panel_mad_k: float = Field(gt=0)
    panel_mad_floor_c: float = Field(ge=0)
    min_region_offset_c: float = Field(ge=0)
    baseline_mad_k: float = Field(gt=0)
    baseline_mad_floor_c: float = Field(ge=0)
    baseline_min_panels: int = Field(gt=0)
    baseline_min_ratio: float = Field(ge=0, le=1)
    row_group_min_panels: int = Field(gt=1)


class SeverityRuleInput(BaseModel):
    """ルールセットの閾値。解析エンジンは mild（検出の最小値）だけを使う。"""

    model_config = ConfigDict(extra="ignore")

    anomaly_type: str
    measure: Measure
    normalized_mild: float = Field(gt=0)
    raw_mild: float = Field(gt=0)


class RulesInput(BaseModel):
    """--rules で渡すルールセット（Rails が active なルールセットから書き出す）。"""

    model_config = ConfigDict(extra="ignore")

    version: str
    detection_params: DetectionParams
    severity_rules: list[SeverityRuleInput]

    @model_validator(mode="after")
    def all_types_present(self):
        types = [r.anomaly_type for r in self.severity_rules]
        missing = [t for t in ANOMALY_TYPES if t not in types]
        if missing:
            raise ValueError(f"閾値が未設定の種類があります: {', '.join(missing)}")
        return self

    def rule_for(self, anomaly_type: str) -> SeverityRuleInput:
        return next(r for r in self.severity_rules if r.anomaly_type == anomaly_type)


class IrradianceInput(BaseModel):
    value: float | None = None
    type: Literal["poa", "ghi", "unknown"] | None = None

    @property
    def normalizable(self) -> bool:
        """正規化ΔT を計算できるか（POA の日射量があるときだけ）。"""
        return self.type == "poa" and self.value is not None and self.value > 0


# ── 出力 ─────────────────────────────────────────────


class BBox(BaseModel):
    x1: float
    y1: float
    x2: float
    y2: float


class ImageInfo(BaseModel):
    width: int
    height: int
    is_radiometric: bool
    source: str
    t_min: float | None = None
    t_max: float | None = None
    blur_score: float | None = None


class BaselineInfo(BaseModel):
    temp: float | None
    method: str = "median_of_normal_panels"
    panel_count: int
    required_count: int
    mad: float | None
    mad_used: float | None


class PanelResult(BaseModel):
    index: int
    grid_index: int
    row: int
    col: int
    polygon: list[tuple[float, float]]
    bbox: BBox
    t_max: float | None = None
    t_mean: float | None = None
    t_min: float | None = None
    p95: float | None = None
    excluded: bool = False
    exclude_reason: str | None = None
    inside_ratio: float | None = None
    is_baseline: bool = False


class AnomalyResult(BaseModel):
    panel_index: int
    anomaly_type: str
    # どちらの判定で見つけたか。local = パネル自身の中央値から見た高温領域 / baseline = 基準温度 + module_wide の mild を超える領域
    detection: Literal["local", "baseline"]
    # substring_bypass のときだけ、作動した帯（サブストリング）の本数。Phase 7 の損失計算で使う
    active_bands: int | None = None
    bbox: BBox
    measure: Measure
    delta_t: float
    normalized_delta_t: float | None
    threshold_basis: ThresholdBasis
    area_ratio: float
    t_max: float
    t_mean: float
    t_min: float
    baseline_temp: float
    shape: dict
    flags: list[str]


class GroupResult(BaseModel):
    type: Literal["panel_row_group"] = "panel_row_group"
    grid_index: int
    row: int
    panel_indices: list[int]
    measure: Measure = "panel_mean"
    delta_t: float
    normalized_delta_t: float | None
    threshold_basis: ThresholdBasis


class AnalysisResult(BaseModel):
    schema_version: str = SCHEMA_VERSION
    analyzer_version: str = ANALYZER_VERSION
    status: Literal["completed", "needs_review", "failed"]
    review_reason: str | None = None
    message: str | None = None
    image: ImageInfo | None = None
    irradiance: IrradianceInput | None = None
    rule_version: str | None = None
    baseline: BaselineInfo | None = None
    panels: list[PanelResult] = []
    anomalies: list[AnomalyResult] = []
    groups: list[GroupResult] = []


class GridProposal(BaseModel):
    rows: int
    cols: int
    corners: list[tuple[float, float]]
    panel_orientation: Literal["portrait", "landscape"]
    panel_count: int


class ProposalResult(BaseModel):
    schema_version: str = SCHEMA_VERSION
    analyzer_version: str = ANALYZER_VERSION
    status: Literal["proposed", "needs_review", "failed"]
    review_reason: str | None = None
    message: str | None = None
    image: ImageInfo | None = None
    grid_proposal: GridProposal | None = None
