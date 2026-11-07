require "test_helper"

# 緯度経度と平面の変換（解析エンジンの analyzer/geo/projection.py の LocalFrame と同じ式・同じ確認）
class GeoFrameTest < ActiveSupport::TestCase
  test "北緯 43° の 1 度は約 111.1 km。行き来が一致する" do
    frame = GeoFrame.new(43.2, 141.35)
    e, n = frame.to_local(43.2009, 141.3512)

    assert_in_delta 0.0009 * 111_136, n, 0.0009 * 111_136 * 2e-3
    assert_in_delta 0.0012 * 111_320 * Math.cos(43.2 * Math::PI / 180), e, 0.3
    lat, lng = frame.to_latlng(e, n)
    assert_in_delta 43.2009, lat, 1e-9
    assert_in_delta 141.3512, lng, 1e-9
  end
end
