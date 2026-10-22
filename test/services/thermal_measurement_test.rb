require "test_helper"

class ThermalMeasurementTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
  end

  test "入力が無ければ何も渡さず、出どころは未入力として残す" do
    measurement = ThermalMeasurement.new(@image)

    assert_equal({}, measurement.params)
    assert(measurement.record.values.all? { |e| e == { "value" => nil, "source" => "not_set" } })
  end

  test "放射率・反射温度・距離は点検の入力、湿度は気象データから渡す" do
    @inspection.update!(emissivity: 0.9, reflected_temperature_c: -5.5, object_distance_m: 25)
    @image.update_columns(humidity: 55)

    measurement = ThermalMeasurement.new(@image.reload)

    assert_equal({ "emissivity" => 0.9, "reflected_temperature_c" => -5.5, "humidity_percent" => 55.0, "distance_m" => 25.0 }, measurement.params)
    assert_equal({ "value" => 55.0, "source" => "weather" }, measurement.record["humidity_percent"])
    assert_equal "inspection", measurement.record["emissivity"]["source"]
  end

  test "解析したときの値と今の入力が違えば、再解析が要る（未解析の画像は対象外）" do
    assert ThermalMeasurement.new(@image).current?, "解析していない画像は対象外"

    @image.update_columns(measurement_params: ThermalMeasurement.new(@image).record)
    assert ThermalMeasurement.new(@image.reload).current?

    @inspection.update!(emissivity: 0.85)
    assert_not ThermalMeasurement.new(@image.reload).current?
  end

  test "ありえない値は保存しない" do
    @inspection.assign_attributes(emissivity: 1.2, reflected_temperature_c: -300, object_distance_m: 0)

    assert_not @inspection.valid?
    assert_equal %i[emissivity reflected_temperature_c object_distance_m], @inspection.errors.attribute_names
  end
end
