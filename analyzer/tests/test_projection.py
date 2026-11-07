"""画像の画素と地上の座標の対応（analyzer/geo/projection.py）。合成の値だけを使う。"""

import math

import pytest

from analyzer.geo.projection import LocalFrame, NadirCamera


def camera(up=0.0, alt=67.6):
    return NadirCamera(east=10.0, north=20.0, abs_alt=alt, up_azimuth_deg=up, ifov_rad=0.975e-3, width=640, height=512)


def test_北が上なら画像の右は東_上は北():
    cam = camera()
    e, n = cam.pixel_to_ground(cam.cx + 100, cam.cy, 30.5)
    assert e == pytest.approx(10.0 + 100 * 0.975e-3 * (67.6 - 30.5))
    assert n == pytest.approx(20.0)
    e, n = cam.pixel_to_ground(cam.cx, cam.cy - 100, 30.5)
    assert n > 20.0 and e == pytest.approx(10.0)


def test_画像の上が東なら画像の右は南():
    cam = camera(up=90.0)
    e, n = cam.pixel_to_ground(cam.cx + 100, cam.cy, 30.5)
    assert e == pytest.approx(10.0, abs=1e-9)
    assert n < 20.0


@pytest.mark.parametrize("up", [0.0, 37.0, 179.5, 359.5])
def test_画素と地上の行き来が一致する(up):
    cam = camera(up=up)
    for u, v, z in [(0, 0, 28.0), (639, 511, 31.6), (123.4, 400.2, 30.5)]:
        e, n = cam.pixel_to_ground(u, v, z)
        u2, v2 = cam.ground_to_pixel(e, n, z)
        assert (u2, v2) == pytest.approx((u, v), abs=1e-6)


def test_高い面ほど縮尺が小さい_パネルの上端と下端の違い():
    cam = camera()
    low = cam.pixel_to_ground(cam.cx + 300, cam.cy, 29.4)
    high = cam.pixel_to_ground(cam.cx + 300, cam.cy, 31.6)
    # 画像の端（中心から 300 画素）で、高さ 2.2 m の違いは約 0.64 m のずれになる
    assert low[0] - high[0] == pytest.approx(300 * 0.975e-3 * 2.2)


def test_カメラより高い面はエラー():
    with pytest.raises(ValueError):
        camera(alt=20.0).gsd(30.0)


def test_緯度経度と平面の行き来():
    frame = LocalFrame(43.2, 141.35)
    e, n = frame.to_local(43.2009, 141.3512)
    assert n == pytest.approx(0.0009 * 111_136, rel=2e-3)  # 北緯 43° の 1 度は約 111.1 km
    assert e == pytest.approx(0.0012 * 111_320 * math.cos(math.radians(43.2)), rel=3e-3)
    lat, lon = frame.to_latlon(e, n)
    assert (lat, lon) == pytest.approx((43.2009, 141.3512), abs=1e-9)
