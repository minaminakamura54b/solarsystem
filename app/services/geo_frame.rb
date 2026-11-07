# 緯度・経度 ↔ 発電所の原点からの東・北（m）。解析エンジンの analyzer/geo/projection.py の LocalFrame と同じ式
# （原点での子午線・卯酉線の曲率半径、WGS84。数百 m の範囲で mm 程度の誤差）
class GeoFrame
  WGS84_A = 6_378_137.0
  WGS84_E2 = 6.69437999014e-3

  attr_reader :lat0, :lng0

  def initialize(lat0, lng0)
    @lat0 = lat0.to_f
    @lng0 = lng0.to_f
    s = Math.sin(radians(@lat0))
    w = Math.sqrt(1 - WGS84_E2 * s * s)
    @m_lat = WGS84_A * (1 - WGS84_E2) / w**3
    @m_lng = WGS84_A / w * Math.cos(radians(@lat0))
  end

  def to_local(lat, lng)
    [ radians(lng.to_f - @lng0) * @m_lng, radians(lat.to_f - @lat0) * @m_lat ]
  end

  def to_latlng(east, north)
    [ @lat0 + degrees(north / @m_lat), @lng0 + degrees(east / @m_lng) ]
  end

  private

  def radians(deg) = deg * Math::PI / 180
  def degrees(rad) = rad * 180 / Math::PI
end
