"""合成の温度行列（℃）を作る（docs/IMPROVEMENT_PLAN.md 5.8）。顧客の実画像は使わない。

パネルはグリッド内で隙間なく並べる（グリッドの4隅 = パネル配列の外周）。背景はパネルより低温。
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

# Rails のシード（db/seeds/rule_sets.rb の 2026-09-initial）と同じ値
DEFAULT_RULES = {
    "version": "test-initial",
    "detection_params": {
        "panel_mad_k": 4, "panel_mad_floor_c": 0.3, "min_region_offset_c": 1.0,
        "baseline_mad_k": 3, "baseline_mad_floor_c": 0.5,
        "baseline_min_panels": 6, "baseline_min_ratio": 0.5,
        "row_group_min_panels": 3,
    },
    "severity_rules": [
        {"anomaly_type": t, "measure": m, "normalized_mild": mild, "normalized_warning": w, "normalized_critical": c,
         "raw_mild": mild, "raw_warning": w, "raw_critical": c}
        for t, m, mild, w, c in [
            ("hotspot", "region_max", 2.0, 5.0, 15.0),
            ("multi_hotspot", "region_max", 1.0, 2.5, 7.5),
            ("substring_bypass", "region_mean", 1.5, 3.0, 8.0),
            ("module_wide", "panel_mean", 1.5, 3.0, 8.0),
            ("partial_module", "region_mean", 1.5, 3.0, 8.0),
            ("panel_row_group", "panel_mean", 1.5, 2.0, 5.0),
        ]
    ],
}

# フルセル・3サブストリング（landscape のパネルで、短辺を3等分した帯）
FULL_CELL_MODULE = {
    "cell_layout": "full_cell",
    "substring_count": 3,
    "bypass_pattern": {"layout": "full_cell", "bands": 3, "band_axis": "short_side", "band_area_ratio": 0.333, "tolerance": 0.12},
}


@dataclass
class GridLayout:
    rows: int
    cols: int
    x0: int  # グリッド左上の画素位置
    y0: int
    orientation: str = "landscape"


@dataclass
class Scene:
    temps: np.ndarray
    panel_w: int
    panel_h: int
    layouts: list[GridLayout]
    grids: list[dict] = field(default_factory=list)

    def panel_rect(self, grid: int, row: int, col: int) -> tuple[int, int, int, int]:
        layout = self.layouts[grid]
        x = layout.x0 + col * self.panel_w
        y = layout.y0 + row * self.panel_h
        return x, y, self.panel_w, self.panel_h

    def heat_panel(self, grid: int, row: int, col: int, delta: float) -> "Scene":
        return self.heat_rect(grid, row, col, 0, 0, 1, 1, delta)

    def heat_rect(self, grid: int, row: int, col: int, fx0: float, fy0: float, fx1: float, fy1: float, delta: float) -> "Scene":
        """パネル内の範囲（パネル幅・高さに対する割合）を delta ℃ だけ温める。"""
        x, y, w, h = self.panel_rect(grid, row, col)
        xa, xb = x + int(round(fx0 * w)), x + int(round(fx1 * w))
        ya, yb = y + int(round(fy0 * h)), y + int(round(fy1 * h))
        self.temps[ya:yb, xa:xb] += delta
        return self

    def heat_pixels(self, grid: int, row: int, col: int, px: int, py: int, size: int, delta: float) -> "Scene":
        x, y, _, _ = self.panel_rect(grid, row, col)
        self.temps[y + py : y + py + size, x + px : x + px + size] += delta
        return self


def make_scene(
    layouts: list[GridLayout] | None = None,
    panel_w: int = 60,
    panel_h: int = 36,
    width: int = 640,
    height: int = 512,
    background: float = 30.0,
    panel_temp: float = 40.0,
    noise: float = 0.2,
    noise_kind: str = "normal",
    seed: int = 0,
) -> Scene:
    layouts = layouts or [GridLayout(rows=4, cols=6, x0=100, y0=100)]
    rng = np.random.default_rng(seed)
    if noise_kind == "uniform":
        temps = rng.uniform(-noise, noise, size=(height, width))
    else:
        temps = rng.normal(0.0, noise, size=(height, width))
    temps = temps.astype(np.float32) + background

    grids = []
    for layout in layouts:
        x1 = layout.x0 + layout.cols * panel_w
        y1 = layout.y0 + layout.rows * panel_h
        temps[layout.y0 : y1, layout.x0 : x1] += panel_temp - background
        grids.append({
            "rows": layout.rows, "cols": layout.cols,
            "corners": [[layout.x0 / width, layout.y0 / height], [x1 / width, layout.y0 / height],
                        [x1 / width, y1 / height], [layout.x0 / width, y1 / height]],
            "panel_orientation": layout.orientation,
        })
    return Scene(temps=temps, panel_w=panel_w, panel_h=panel_h, layouts=layouts, grids=grids)


def make_gapped_scene(rows: int = 3, cols: int = 5, panel_w: int = 50, panel_h: int = 30, gap: int = 6, seed: int = 0) -> np.ndarray:
    """パネルの間に低温の隙間がある画像（propose-grid 用。グリッドの構造がはっきりしている）。"""
    rng = np.random.default_rng(seed)
    temps = (rng.normal(0.0, 0.2, size=(512, 640)) + 30.0).astype(np.float32)
    x0, y0 = 120, 110
    for row in range(rows):
        for col in range(cols):
            x = x0 + col * (panel_w + gap)
            y = y0 + row * (panel_h + gap)
            temps[y : y + panel_h, x : x + panel_w] += 10.0
    return temps
