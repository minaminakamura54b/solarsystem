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

  test "雲量（オクタ）は 0〜8 の整数。雲量だけでも登録でき、画像に割り当てる値は持たない" do
    reading = @inspection.weather_readings.build(observed_at: Time.current, cloud_cover_okta: 2)
    assert reading.valid?
    assert_not reading.affects_images?

    [ -1, 9, 2.5 ].each do |value|
      assert_not @inspection.weather_readings.build(observed_at: Time.current, cloud_cover_okta: value).valid?, value.to_s
    end
  end

  test "風速だけでも登録できる" do
    assert @inspection.weather_readings.build(observed_at: Time.current, wind_speed_m_s: 2).valid?
  end
end
