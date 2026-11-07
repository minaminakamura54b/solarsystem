"""画像の画素と地上の座標（発電所の原点からの東・北 m、高さは標高 m）の対応（docs/LAYOUT_OVERLAY_DESIGN.md の B-1）。

- 真下向き（ジンバル -90°）の画像だけを扱う。カメラはピンホールとし、画素の角度 ifov（rad/画素）で
  画像中心からのずれを視線の傾き（tan）に直す。レンズのゆがみは補正しない
- 地上の点の高さ z（標高）ごとに、カメラからの高さ（絶対高度 − z）で縮尺が変わる。パネルは傾いているので、
  パネルの上端と下端では z が違う（2026-11 の検証: 地面より約 3 m 高く、上端と下端で ±約 1.1 m）
- 画像の上が向く方位 up_azimuth_deg（北から時計回り）。DJI の真下向きの画像では「ジンバルの yaw − roll」
  （飛行 008 で北が上になることを確認。Rails の ImageGeoref が記録する）
- 緯度・経度と平面の変換は、原点での子午線・卯酉線の曲率半径（WGS84）を使う（数百 m の範囲で mm 程度の誤差）
"""

from __future__ import annotations

import math
from dataclasses import dataclass

WGS84_A = 6378137.0
WGS84_E2 = 6.69437999014e-3


@dataclass(frozen=True)
class LocalFrame:
    """緯度・経度 ↔ 原点からの東・北（m）"""

    lat0: float
    lon0: float

    def _radii(self) -> tuple[float, float]:
        s = math.sin(math.radians(self.lat0))
        w = math.sqrt(1 - WGS84_E2 * s * s)
        meridian = WGS84_A * (1 - WGS84_E2) / w ** 3
        prime = WGS84_A / w
        return meridian, prime * math.cos(math.radians(self.lat0))

    def to_local(self, lat: float, lon: float) -> tuple[float, float]:
        m_lat, m_lon = self._radii()
        return math.radians(lon - self.lon0) * m_lon, math.radians(lat - self.lat0) * m_lat

    def to_latlon(self, east: float, north: float) -> tuple[float, float]:
        m_lat, m_lon = self._radii()
        return self.lat0 + math.degrees(north / m_lat), self.lon0 + math.degrees(east / m_lon)


@dataclass(frozen=True)
class NadirCamera:
    """真下向きのカメラ 1 枚分（撮影位置は LocalFrame の東・北 m、高さは標高 m）"""

    east: float
    north: float
    abs_alt: float
    up_azimuth_deg: float
    ifov_rad: float
    width: int
    height: int

    @property
    def cx(self) -> float:
        return (self.width - 1) / 2

    @property
    def cy(self) -> float:
        return (self.height - 1) / 2

    def _axes(self) -> tuple[tuple[float, float], tuple[float, float]]:
        a = math.radians(self.up_azimuth_deg)
        up = (math.sin(a), math.cos(a))  # 画像の上（東, 北）
        right = (math.cos(a), -math.sin(a))  # 画像の右
        return up, right

    def height_above(self, z: float) -> float:
        h = self.abs_alt - z
        if h <= 0:
            raise ValueError(f"カメラが高さ {z} m の面より上にありません（絶対高度 {self.abs_alt} m）")
        return h

    def pixel_to_ground(self, u: float, v: float, z: float) -> tuple[float, float]:
        h = self.height_above(z)
        up, right = self._axes()
        dx = (u - self.cx) * self.ifov_rad * h  # 画像の右向き（m）
        dy = -(v - self.cy) * self.ifov_rad * h  # 画像の上向き（m）。v は下向き
        return self.east + dx * right[0] + dy * up[0], self.north + dx * right[1] + dy * up[1]

    def ground_to_pixel(self, east: float, north: float, z: float) -> tuple[float, float]:
        h = self.height_above(z)
        up, right = self._axes()
        de, dn = east - self.east, north - self.north
        dx = de * right[0] + dn * right[1]
        dy = de * up[0] + dn * up[1]
        return self.cx + dx / (self.ifov_rad * h), self.cy - dy / (self.ifov_rad * h)

    def gsd(self, z: float) -> float:
        """高さ z の面での 1 画素の大きさ（m）"""
        return self.ifov_rad * self.height_above(z)
