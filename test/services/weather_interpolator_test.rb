require "test_helper"

class WeatherInterpolatorTest < ActiveSupport::TestCase
  def reading(time, **attrs)
    WeatherReading.new({ observed_at: jst(time) }.merge(attrs))
  end

  test "前後の観測値があれば線形補間する" do
    readings = [
      reading("2026-09-20 10:00", irradiance_w_m2: 700, irradiance_type: "poa", air_temp_c: 20),
      reading("2026-09-20 10:20", irradiance_w_m2: 800, irradiance_type: "poa", air_temp_c: 24)
    ]

    attrs = WeatherInterpolator.new(readings).attributes_for(jst("2026-09-20 10:05"))

    assert_equal 725, attrs[:irradiance_w_m2]
    assert_equal 21, attrs[:air_temp_c]
    assert_equal "poa", attrs[:irradiance_type]
  end

  test "片側にしか観測値が無ければ近い方の値を使う" do
    readings = [ reading("2026-09-20 10:00", irradiance_w_m2: 700, irradiance_type: "poa") ]

    attrs = WeatherInterpolator.new(readings).attributes_for(jst("2026-09-20 10:10"))

    assert_equal 700, attrs[:irradiance_w_m2]
  end

  test "撮影時刻から30分を超えて離れた観測値は使わない" do
    readings = [ reading("2026-09-20 10:00", irradiance_w_m2: 700, irradiance_type: "poa") ]

    attrs = WeatherInterpolator.new(readings).attributes_for(jst("2026-09-20 10:31"))

    assert_nil attrs[:irradiance_w_m2]
    assert_nil attrs[:irradiance_type]
  end

  test "補間に使った観測値の日射量の種類が食い違えば unknown" do
    readings = [
      reading("2026-09-20 10:00", irradiance_w_m2: 700, irradiance_type: "poa"),
      reading("2026-09-20 10:20", irradiance_w_m2: 500, irradiance_type: "ghi")
    ]

    attrs = WeatherInterpolator.new(readings).attributes_for(jst("2026-09-20 10:10"))

    assert_equal "unknown", attrs[:irradiance_type]
  end

  test "項目ごとに、値のある観測値だけを使う" do
    readings = [
      reading("2026-09-20 10:00", irradiance_w_m2: 700, irradiance_type: "poa"),
      reading("2026-09-20 10:10", wind_speed_m_s: 2.5)
    ]

    attrs = WeatherInterpolator.new(readings).attributes_for(jst("2026-09-20 10:05"))

    assert_equal 700, attrs[:irradiance_w_m2]
    assert_equal 2.5, attrs[:wind_speed_m_s]
  end

  test "撮影時刻が無ければすべて nil" do
    readings = [ reading("2026-09-20 10:00", irradiance_w_m2: 700, irradiance_type: "poa") ]

    attrs = WeatherInterpolator.new(readings).attributes_for(nil)

    assert attrs.values.all?(&:nil?)
  end
end
