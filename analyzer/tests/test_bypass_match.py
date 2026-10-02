import numpy as np

from analyzer.analysis.detection import HotRegion
from analyzer.analysis.patterns import bypass_match
from analyzer.contract import BypassPattern

PATTERN = BypassPattern(bands=3, band_axis="short_side", band_area_ratio=0.333, tolerance=0.12)


def region(shape, x1, y1, x2, y2):
    mask = np.zeros(shape, dtype=bool)
    mask[y1 : y2 + 1, x1 : x2 + 1] = True
    return HotRegion(mask=mask, area_px=int(mask.sum()), bbox=(x1, y1, x2, y2))


def test_portraitのパネルでは短辺は横方向():
    shape = (60, 36)  # 縦長（長辺が y）
    band = region(shape, 0, 0, 11, 59)  # 横幅 1/3、縦いっぱい

    matched, details = bypass_match(band, shape, "portrait", PATTERN)

    assert matched
    assert details["divided_axis"] == "x"


def test_long_sideなら長辺を等分した帯に一致する():
    shape = (36, 60)  # landscape
    pattern = BypassPattern(bands=3, band_axis="long_side", band_area_ratio=0.333, tolerance=0.12)
    band = region(shape, 0, 0, 19, 35)  # 長辺（x）の 1/3、短辺いっぱい

    assert bypass_match(band, shape, "landscape", pattern)[0]


def test_面積比が許容範囲を外れると一致しない():
    shape = (36, 60)
    band = region(shape, 0, 0, 59, 3)  # 短辺の 1/9 しかない

    matched, details = bypass_match(band, shape, "landscape", PATTERN)

    assert not matched
    assert details["checks"]["area_ratio"] is False
