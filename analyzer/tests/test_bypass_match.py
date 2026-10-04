import numpy as np

from analyzer.analysis.detection import HotRegion
from analyzer.analysis.patterns import bypass_bands
from analyzer.contract import BypassPattern

PATTERN = BypassPattern(bands=3, band_axis="short_side", band_area_ratio=0.333, tolerance=0.12)


def region(shape, x1, y1, x2, y2):
    mask = np.zeros(shape, dtype=bool)
    mask[y1 : y2 + 1, x1 : x2 + 1] = True
    return HotRegion(mask=mask, area_px=int(mask.sum()), bbox=(x1, y1, x2, y2))


def test_landscapeでは短辺は縦方向で_1本の帯に一致する():
    shape = (36, 60)
    bands, details = bypass_bands(region(shape, 0, 0, 59, 11), shape, "landscape", PATTERN)

    assert bands == 1
    assert details["divided_axis"] == "y"


def test_連続した2本の帯に一致する():
    shape = (36, 60)
    bands, details = bypass_bands(region(shape, 0, 0, 59, 23), shape, "landscape", PATTERN)

    assert bands == 2
    assert details["matched_bands"] == 2


def test_portraitのパネルでは短辺は横方向():
    shape = (60, 36)  # 縦長（長辺が y）
    bands, details = bypass_bands(region(shape, 0, 0, 11, 59), shape, "portrait", PATTERN)

    assert bands == 1
    assert details["divided_axis"] == "x"


def test_long_sideなら長辺を等分した帯に一致する():
    shape = (36, 60)
    pattern = BypassPattern(bands=3, band_axis="long_side", band_area_ratio=0.333, tolerance=0.12)

    assert bypass_bands(region(shape, 0, 0, 19, 35), shape, "landscape", pattern)[0] == 1


def test_面積比が許容範囲を外れると一致しない():
    shape = (36, 60)
    bands, details = bypass_bands(region(shape, 0, 0, 59, 3), shape, "landscape", PATTERN)  # 短辺の 1/9 しかない

    assert bands is None
    assert details["checks"]["area_ratio"] is False


def test_パネル全体にわたらない領域は帯に一致しない():
    shape = (36, 60)
    bands, details = bypass_bands(region(shape, 0, 0, 29, 23), shape, "landscape", PATTERN)  # 長辺の半分まで

    assert bands is None
    assert details["checks"]["spans_panel"] is False
