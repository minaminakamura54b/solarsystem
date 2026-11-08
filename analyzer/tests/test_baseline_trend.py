"""基準温度の取り方 position_trend（画像内の位置の傾向。2026-11-08 ユーザー承認・暫定）。合成の温度行列だけを使う。"""

import numpy as np
import pytest

from analyzer.analysis.baseline import compute_baseline_trend
from analyzer.contract import DetectionParams, RulesInput
from tests.fixtures.make_synthetic import DEFAULT_RULES, GridLayout, make_scene

TREND = DetectionParams.model_validate({**DEFAULT_RULES["detection_params"], "baseline_method": "position_trend"})


def gradient_scene(per_height=5.0):
    """画像の上から下へ per_height ℃ 温かく見えるパネル（見る角度の影響を模したもの）"""
    scene = make_scene(layouts=[GridLayout(rows=6, cols=8, x0=40, y0=40)], panel_w=70, panel_h=70)
    ramp = np.linspace(0, per_height, scene.temps.shape[0], dtype=np.float32)[:, None]
    scene.temps += ramp
    return scene


def trend_rules():
    data = {**DEFAULT_RULES, "detection_params": {**DEFAULT_RULES["detection_params"], "baseline_method": "position_trend"}}
    return RulesInput.model_validate(data)


def test_省略時は従来の画像全体の中央値():
    assert DetectionParams.model_validate(DEFAULT_RULES["detection_params"]).baseline_method == "image_median"


def test_位置の傾向を平面で表し_外れ値のパネルを除く():
    means, pos = {}, {}
    for i in range(30):
        x, y = (i % 6) / 5, (i // 6) / 4
        pos[i] = (x, y)
        means[i] = 30 + 2.0 * y + 0.5 * x
    means[7] += 5.0  # 異常のパネル

    b = compute_baseline_trend(means, pos, TREND)

    assert b.sufficient and b.trend["shape"] == "plane"
    assert 7 not in b.baseline_indices
    assert b.temp_for(29) == pytest.approx(30 + 2.0 + 0.5, abs=0.05)
    assert b.temp_for(0) == pytest.approx(30.0, abs=0.05)


def test_位置の広がりが足りなければ直線_さらに足りなければ定数():
    line = compute_baseline_trend({i: 30 + i * 0.1 for i in range(10)}, {i: (0.5, i / 9) for i in range(10)}, TREND)
    assert line.trend["shape"] == "line"
    const = compute_baseline_trend({i: 30.0 for i in range(10)}, {i: (0.5, 0.5) for i in range(10)}, TREND)
    assert const.trend["shape"] == "constant" and const.temp == pytest.approx(30.0)


def test_正常パネルが足りなければ基準不足():
    b = compute_baseline_trend({i: 30.0 for i in range(4)}, {i: (i / 3, i / 3) for i in range(4)}, TREND)
    assert not b.sufficient


def test_画像の下側ほど温かく見えても_位置の傾向なら候補にしない(run_analysis, rules):
    scene = gradient_scene()
    current, _ = run_analysis(scene)
    trend, _ = run_analysis(scene, rules_override=trend_rules())

    assert len(current.anomalies) > 0, "従来の方法では、画像の下側のパネルが候補になる"
    assert trend.anomalies == []
    assert trend.baseline.method == "position_trend"
    assert trend.baseline.trend["shape"] in ("plane", "line")


def test_位置の傾向でも_本物の発熱は残る(run_analysis):
    scene = gradient_scene()
    scene.heat_panel(0, 0, 3, 3.0)  # 上側（傾向で冷たく見える側）のパネル全体 +3℃
    scene.heat_pixels(0, 5, 5, 30, 30, 3, 8.0)  # 下側のパネルの点 +8℃
    result, _ = run_analysis(scene, rules_override=trend_rules())

    found = {(a.panel_index, a.anomaly_type) for a in result.anomalies}
    assert (3, "module_wide") in found
    assert any(i == 5 * 8 + 5 and t in ("hotspot", "multi_hotspot") for i, t in found)
