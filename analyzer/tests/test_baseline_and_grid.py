import numpy as np
import pytest

from analyzer.analysis.baseline import compute_baseline
from analyzer.analysis.patterns import row_runs
from analyzer.contract import DetectionParams, GridSpec
from analyzer.vision.exclusions import edge_cut
from analyzer.vision.grid import panels_from_grids, rectify
from tests.fixtures.make_synthetic import DEFAULT_RULES

DETECTION = DetectionParams.model_validate(DEFAULT_RULES["detection_params"])


def test_基準温度は外れ値を除いた中央値():
    means = {i: 40.0 + 0.1 * (i % 3) for i in range(10)} | {10: 48.0, 11: 47.5}

    baseline = compute_baseline(means, DETECTION)

    assert baseline.sufficient
    assert baseline.temp == pytest.approx(40.1)
    assert 10 not in baseline.baseline_indices and 11 not in baseline.baseline_indices


def test_必要な正常パネル数はbaseline_min_panelsとパネル数の割合の大きい方():
    means = {i: 40.0 for i in range(20)}

    assert compute_baseline(means, DETECTION).required_count == 10  # max(6, ceil(20 × 0.5))
    assert compute_baseline({i: 40.0 for i in range(8)}, DETECTION).required_count == 6


def test_パネルが無ければ基準不足():
    assert not compute_baseline({}, DETECTION).sufficient


def test_グリッドは射影変換でパネルに分ける():
    grid = GridSpec(rows=2, cols=3, corners=[(0.1, 0.1), (0.4, 0.1), (0.4, 0.3), (0.1, 0.3)])

    panels = panels_from_grids([grid], 1000, 1000)

    assert len(panels) == 6
    np.testing.assert_allclose(panels[0].quad, [[100, 100], [200, 100], [200, 200], [100, 200]], atol=1e-3)
    np.testing.assert_allclose(panels[5].quad[2], [400, 300], atol=1e-3)


def test_台形のグリッドでも4隅を通るパネルに分ける():
    grid = GridSpec(rows=1, cols=2, corners=[(0.2, 0.1), (0.8, 0.1), (0.9, 0.5), (0.1, 0.5)])

    panels = panels_from_grids([grid], 1000, 1000)

    np.testing.assert_allclose(panels[0].quad[0], [200, 100], atol=1e-3)
    np.testing.assert_allclose(panels[1].quad[2], [900, 500], atol=1e-3)


def test_整列パッチはパネルの画素をそのまま写す():
    temps = np.arange(100 * 100, dtype=np.float32).reshape(100, 100)
    quad = np.array([[10, 20], [40, 20], [40, 30], [10, 30]], dtype=np.float32)

    patch = rectify(temps, quad).patch

    assert patch.shape == (10, 30)
    assert patch[0, 0] == temps[20, 10]
    assert patch[9, 29] == temps[29, 39]


def test_画像の端に接するパネルは除外する():
    inside = np.array([[10, 10], [50, 10], [50, 40], [10, 40]], dtype=np.float32)
    touching = np.array([[0, 10], [50, 10], [50, 40], [0, 40]], dtype=np.float32)
    outside = np.array([[600, 10], [700, 10], [700, 40], [600, 40]], dtype=np.float32)

    assert edge_cut(inside, 640, 512, 1, 0.7) == (False, 1.0)
    assert edge_cut(touching, 640, 512, 1, 0.7)[0] is True
    excluded, ratio = edge_cut(outside, 640, 512, 1, 0.7)
    assert excluded and ratio == pytest.approx(0.4)


def test_隣接の並びは同じグリッドの同じ行で列が連続するものだけ():
    cells = [(0, 0, 0, 0), (0, 0, 1, 1), (0, 0, 2, 2), (0, 0, 4, 4), (0, 1, 3, 9), (1, 0, 0, 20), (1, 0, 1, 21)]

    assert row_runs(cells, 3) == [(0, 0, [0, 1, 2])]
