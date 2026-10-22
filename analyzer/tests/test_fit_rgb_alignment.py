"""Phase S 用の位置合わせの補助スクリプト（scripts/fit_rgb_alignment.py）。合成の対応点だけを使う。"""

import importlib.util
import json

import numpy as np
import pytest

from tests.conftest import ANALYZER_ROOT

spec = importlib.util.spec_from_file_location("fit_rgb_alignment", ANALYZER_ROOT / "scripts" / "fit_rgb_alignment.py")
fit_rgb_alignment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fit_rgb_alignment)

THERMAL = (640, 512)
RGB = (4000, 3000)


def synthetic_points(transform, count=6, noise_px=0.0, seed=0):
    rng = np.random.default_rng(seed)
    thermal = rng.uniform([20, 20], [620, 490], size=(count, 2))
    normalized = thermal / np.array(THERMAL)
    rgb = np.array([transform(u, v) for u, v in normalized]) * np.array(RGB)
    return thermal, rgb + rng.normal(0, noise_px, size=rgb.shape)


def test_拡大率とずれだけの変換なら_その値を誤差ほぼ0で求める():
    thermal, rgb = synthetic_points(lambda u, v: (0.8 * u + 0.1, 0.75 * v + 0.12))

    result = fit_rgb_alignment.fit(thermal, rgb, THERMAL, RGB)

    so = result["scale_offset"]
    assert so["scale_x"] == pytest.approx(0.8, abs=1e-6)
    assert so["offset_x"] == pytest.approx(0.1, abs=1e-6)
    assert so["scale_y"] == pytest.approx(0.75, abs=1e-6)
    assert so["offset_y"] == pytest.approx(0.12, abs=1e-6)
    assert so["rms_error_px"] < 0.01


def test_回転を含む変換は_拡大率とずれでは誤差が残り_アフィン変換で小さくなる():
    angle = np.deg2rad(3)
    thermal, rgb = synthetic_points(lambda u, v: (0.8 * (np.cos(angle) * u - np.sin(angle) * v) + 0.1,
                                                  0.8 * (np.sin(angle) * u + np.cos(angle) * v) + 0.1))

    result = fit_rgb_alignment.fit(thermal, rgb, THERMAL, RGB)

    assert result["scale_offset"]["max_error_px"] > 20
    assert result["affine"]["max_error_px"] < 0.01


def test_対応点が3点未満ならエラー():
    thermal, rgb = synthetic_points(lambda u, v: (u, v), count=2)

    with pytest.raises(ValueError, match="3 点以上"):
        fit_rgb_alignment.fit(thermal, rgb, THERMAL, RGB)


def test_コマンドは結果のJSONを出す(tmp_path, capsys):
    thermal, rgb = synthetic_points(lambda u, v: (0.8 * u + 0.1, 0.75 * v + 0.12), noise_px=2.0)
    path = tmp_path / "points.json"
    path.write_text(json.dumps({"thermal_size": THERMAL, "rgb_size": RGB,
                                "points": [{"thermal": t.tolist(), "rgb": r.tolist()} for t, r in zip(thermal, rgb)]}))

    assert fit_rgb_alignment.main([str(path)]) == 0
    result = json.loads(capsys.readouterr().out)
    assert result["points"] == 6
    assert 0 < result["scale_offset"]["rms_error_px"] < 10
