require "test_helper"

class WeatherReadingTest < ActiveSupport::TestCase
  setup do
    @inspection = create_session_inspection
  end

  test "日射量を入れたら種類（POA / GHI）は必須" do
    reading = @inspection.weather_readings.build(observed_at: Time.current, irradiance_w_m2: 700)

    assert_not reading.valid?
    assert reading.errors[:irradiance_type].any?
  end

  test "何かしらの値が必要" do
    reading = @inspection.weather_readings.build(observed_at: Time.current)

    assert_not reading.valid?
  end

  test "風速だけでも登録できる" do
    assert @inspection.weather_readings.build(observed_at: Time.current, wind_speed_m_s: 2).valid?
  end
end
