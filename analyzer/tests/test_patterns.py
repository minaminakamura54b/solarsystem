"""合成データで、発熱パターンの分類・除外・基準温度が仕様どおりになることを確認する（5.8）。"""

import pytest

from tests.fixtures.make_synthetic import FULL_CELL_MODULE, GridLayout, make_scene


def anomaly_types(result):
    return [a.anomaly_type for a in result.anomalies]


def test_正常な画像では異常ゼロ(run_analysis):
    result, code = run_analysis(make_scene())

    assert code == 0
    assert result.status == "completed"
    assert result.anomalies == []
    assert result.baseline.temp == pytest.approx(40.0, abs=0.1)
    assert result.baseline.panel_count == 24


def test_温度がほぼ均一な画像でもMADの下限が効き誤検出しない(run_analysis):
    scene = make_scene(noise=0.05, noise_kind="uniform")

    result, code = run_analysis(scene)

    assert code == 0
    assert result.anomalies == []
    assert result.baseline.mad_used == 0.5, "基準温度用の MAD の下限（0.5℃）が使われる"


def test_単セルのホットスポット(run_analysis):
    scene = make_scene().heat_rect(0, 1, 2, 0.4, 0.33, 0.5, 0.5, 15.0)  # パネルの 1/10 × 1/6

    result, _ = run_analysis(scene)

    [a] = result.anomalies
    assert a.anomaly_type == "hotspot"
    assert a.measure == "region_max"
    assert a.delta_t == pytest.approx(15.0, abs=1.0)
    assert a.area_ratio < 0.10
    assert a.panel_index == 1 * 6 + 2
    assert "glare_suspect" not in a.flags
    assert a.shape["regions"] == 1


def test_複数のホットスポット(run_analysis):
    scene = make_scene().heat_rect(0, 2, 1, 0.1, 0.1, 0.2, 0.3, 8.0).heat_rect(0, 2, 1, 0.7, 0.6, 0.8, 0.8, 8.0)

    result, _ = run_analysis(scene)

    [a] = result.anomalies
    assert a.anomaly_type == "multi_hotspot"
    assert a.shape["regions"] == 2


def test_短辺の1_3の帯はbypass_patternがあればsubstring_bypass(run_analysis):
    scene = make_scene().heat_rect(0, 1, 1, 0.0, 0.0, 1.0, 1 / 3, 6.0)  # 長辺方向に伸び、短辺の 1/3 の帯

    result, _ = run_analysis(scene, module=FULL_CELL_MODULE)

    [a] = result.anomalies
    assert a.anomaly_type == "substring_bypass"
    assert a.measure == "region_mean"
    assert a.delta_t == pytest.approx(6.0, abs=0.5)
    assert a.area_ratio == pytest.approx(1 / 3, abs=0.05)
    assert a.shape["bypass_match"]["checks"] == {"area_ratio": True, "spans_panel": True, "band_width": True}


def test_モジュール構成が未登録なら帯でもpartial_module(run_analysis):
    scene = make_scene().heat_rect(0, 1, 1, 0.0, 0.0, 1.0, 1 / 3, 6.0)

    result, _ = run_analysis(scene, module={})

    assert anomaly_types(result) == ["partial_module"]
    assert result.anomalies[0].shape["bypass_match"]["evaluated"] is False


def test_セル構成が不明ならbypass_patternがあってもpartial_module(run_analysis):
    scene = make_scene().heat_rect(0, 1, 1, 0.0, 0.0, 1.0, 1 / 3, 6.0)
    module = {**FULL_CELL_MODULE, "cell_layout": None}

    result, _ = run_analysis(scene, module=module)

    assert anomaly_types(result) == ["partial_module"]


def test_向きの違う帯はbypass_patternに一致せずpartial_module(run_analysis):
    scene = make_scene().heat_rect(0, 1, 1, 0.0, 0.0, 1 / 3, 1.0, 6.0)  # 短辺方向に伸びる帯（長辺を等分）

    result, _ = run_analysis(scene, module=FULL_CELL_MODULE)

    assert anomaly_types(result) == ["partial_module"]
    assert result.anomalies[0].shape["bypass_match"]["checks"]["spans_panel"] is False


def test_モジュール全体が2度高いとmodule_wideで面積比は0_8以上(run_analysis):
    scene = make_scene().heat_panel(0, 2, 3, 2.0)

    result, _ = run_analysis(scene)

    [a] = result.anomalies
    assert a.anomaly_type == "module_wide"
    assert a.measure == "panel_mean"
    assert a.delta_t == pytest.approx(2.0, abs=0.2)
    assert a.area_ratio >= 0.80
    assert a.shape["area_ratio_basis"] == "baseline"


def test_module_wideに該当したパネルはパネル内の高温領域を判定しない(run_analysis):
    scene = make_scene().heat_panel(0, 2, 3, 3.0).heat_rect(0, 2, 3, 0.4, 0.4, 0.5, 0.6, 10.0)

    result, _ = run_analysis(scene)

    assert anomaly_types(result) == ["module_wide"]


def test_同じ行で連続する4枚はpanel_row_groupになる(run_analysis):
    scene = make_scene()
    for col in range(1, 5):
        scene.heat_panel(0, 0, col, 3.0)

    result, code = run_analysis(scene)

    assert code == 0
    assert anomaly_types(result) == ["module_wide"] * 4, "構成パネルは anomalies にも module_wide として出す"
    [group] = result.groups
    assert group.panel_indices == [1, 2, 3, 4]
    assert group.delta_t == pytest.approx(3.0, abs=0.2)


def test_正常パネルが足りなければ基準不足で終了コード4(run_analysis):
    scene = make_scene([GridLayout(rows=2, cols=4, x0=100, y0=100)])
    for col in range(4):
        scene.heat_panel(0, 0, col, 3.0)
    scene.heat_panel(0, 1, 0, 3.0)  # 8枚中5枚が温まっている

    result, code = run_analysis(scene)

    assert code == 4
    assert result.status == "needs_review"
    assert result.review_reason == "insufficient_baseline"
    assert result.anomalies == []
    assert result.baseline.required_count == 6


def test_画像の端で切れたパネルはedge_cutで除外する(run_analysis):
    scene = make_scene([GridLayout(rows=4, cols=6, x0=300, y0=100)])  # 右端の列は画像の外にはみ出す
    scene.heat_panel(0, 0, 5, 10.0)  # はみ出したパネルが温まっていても検出しない

    result, code = run_analysis(scene)

    assert code == 0
    excluded = [p for p in result.panels if p.excluded]
    assert {p.col for p in excluded} == {5}
    assert all(p.exclude_reason == "edge_cut" and p.t_mean is None for p in excluded)
    assert result.anomalies == []


def test_極小の高温点はglare_suspectのフラグを付けるが検出は残す(run_analysis):
    scene = make_scene().heat_pixels(0, 1, 1, 30, 18, 2, 20.0)  # 2×2 画素 = パネルの 0.19%

    result, _ = run_analysis(scene)

    [a] = result.anomalies
    assert a.anomaly_type == "hotspot"
    assert "glare_suspect" in a.flags


def test_通路をはさむ2つのグリッドでは群がつながらない(run_analysis):
    layouts = [GridLayout(rows=3, cols=4, x0=40, y0=100), GridLayout(rows=3, cols=4, x0=340, y0=100)]
    scene = make_scene(layouts)
    scene.heat_panel(0, 0, 2, 3.0).heat_panel(0, 0, 3, 3.0)  # 左のグリッドの右端2枚
    scene.heat_panel(1, 0, 0, 3.0).heat_panel(1, 0, 1, 3.0)  # 右のグリッドの左端2枚（画面上は4枚連続）

    result, _ = run_analysis(scene)

    assert anomaly_types(result) == ["module_wide"] * 4
    assert result.groups == []


def test_パネル番号はグリッド順で各グリッド内は行優先(run_analysis):
    layouts = [GridLayout(rows=3, cols=4, x0=40, y0=100), GridLayout(rows=3, cols=4, x0=340, y0=100)]

    result, _ = run_analysis(make_scene(layouts))

    assert [(p.grid_index, p.row, p.col) for p in result.panels[:5]] == [(0, 0, 0), (0, 0, 1), (0, 0, 2), (0, 0, 3), (0, 1, 0)]
    assert (result.panels[12].grid_index, result.panels[12].row, result.panels[12].col) == (1, 0, 0)


def test_日射量がGHIなら正規化しない(run_analysis):
    scene = make_scene().heat_rect(0, 1, 2, 0.4, 0.33, 0.5, 0.5, 15.0)

    result, _ = run_analysis(scene, irradiance={"value": 800, "type": "ghi"})

    [a] = result.anomalies
    assert a.normalized_delta_t is None
    assert a.threshold_basis == "raw"
    assert "unnormalized" in a.flags


def test_日射量がPOAなら正規化ΔTを出す(run_analysis):
    scene = make_scene().heat_rect(0, 1, 2, 0.4, 0.33, 0.5, 0.5, 15.0)

    result, _ = run_analysis(scene, irradiance={"value": 800, "type": "poa"})

    [a] = result.anomalies
    assert a.threshold_basis == "normalized"
    assert a.normalized_delta_t == pytest.approx(a.delta_t * 1000 / 800, abs=0.01)
    assert "unnormalized" not in a.flags


def test_POAの日射量が低いと正規化ΔTが大きくなり生ΔTでは届かない温度差も検出する(run_analysis):
    scene = make_scene().heat_panel(0, 2, 3, 1.0)  # 生ΔT 1.0℃ < mild 1.5℃

    raw_result, _ = run_analysis(scene, irradiance={"value": 500, "type": "ghi"})
    poa_result, _ = run_analysis(scene, irradiance={"value": 500, "type": "poa"})  # 正規化ΔT 2.0 ≥ 1.5

    assert raw_result.anomalies == []
    assert anomaly_types(poa_result) == ["module_wide"]


def test_低温側の影は検出しない(run_analysis):
    scene = make_scene().heat_rect(0, 1, 1, 0.0, 0.0, 0.5, 1.0, -5.0)

    result, _ = run_analysis(scene)

    assert result.anomalies == []


def test_mild未満の温度差は出力しない(run_analysis):
    scene = make_scene().heat_rect(0, 1, 2, 0.4, 0.33, 0.5, 0.5, 1.5)  # hotspot の mild は 2.0℃

    result, _ = run_analysis(scene)

    assert result.anomalies == []


def test_異常のbboxはパネル内の高温領域の位置を指す(run_analysis):
    scene = make_scene().heat_rect(0, 0, 0, 0.5, 0.5, 0.6, 0.67, 15.0)
    x, y, w, h = scene.panel_rect(0, 0, 0)

    result, _ = run_analysis(scene)

    bbox = result.anomalies[0].bbox
    assert bbox.x1 == pytest.approx((x + 30) / 640, abs=0.003)
    assert bbox.y1 == pytest.approx((y + 18) / 512, abs=0.003)
    assert bbox.x2 == pytest.approx((x + 36) / 640, abs=0.003)


@pytest.mark.xfail(
    strict=True,
    reason="仕様のすき間（既知の問題 O）: パネルの 50〜80% が温まると module_wide にならず、"
    "パネル中央値が高温側になるため高温領域も見つからない。補う判定の追加はユーザーの確認待ち",
)
def test_パネルの2_3が温まった場合も検出する(run_analysis):
    scene = make_scene().heat_rect(0, 1, 1, 0.0, 0.0, 1.0, 2 / 3, 6.0)

    result, _ = run_analysis(scene, module=FULL_CELL_MODULE)

    assert result.anomalies != []
