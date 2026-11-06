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

  test "SDK が受け付ける範囲の外の値は保存しない（範囲は config/analyzer.yml）" do
    @inspection.assign_attributes(emissivity: 0.05, reflected_temperature_c: 150, object_distance_m: 0.5)

    assert_not @inspection.valid?
    assert_equal %i[emissivity reflected_temperature_c object_distance_m], @inspection.errors.attribute_names
    assert_includes @inspection.errors[:emissivity].first, "0.1〜1 の範囲"
    assert_includes @inspection.errors[:object_distance_m].first, "1 m〜300 m"

    @inspection.assign_attributes(emissivity: 0.1, reflected_temperature_c: -40, object_distance_m: 300)
    assert @inspection.valid?
  end

  test "距離は画像ごとのレーザー距離計の値を、点検の入力より優先して使う" do
    @inspection.update!(object_distance_m: 30)
    @image.update_columns(metadata: { "LRFTargetDistance" => 41.486, "LRFStatus" => "Normal" })

    assert_equal({ "value" => 41.486, "source" => "lrf" }, ThermalMeasurement.new(@image.reload).record["distance_m"])
  end

  test "レーザー距離計の値が無い・正常でない・範囲外なら点検の入力、それも無ければ未設定（画像の記録値）" do
    @inspection.update!(object_distance_m: 30)
    [ {}, { "LRFTargetDistance" => 41.0, "LRFStatus" => "Error" }, { "LRFTargetDistance" => 450.0 } ].each do |metadata|
      @image.update_columns(metadata: metadata)
      assert_equal({ "value" => 30.0, "source" => "inspection" }, ThermalMeasurement.new(@image.reload).record["distance_m"], metadata.inspect)
    end

    @inspection.update!(object_distance_m: nil)
    @image.update_columns(metadata: {})
    assert_equal({ "value" => nil, "source" => "not_set" }, ThermalMeasurement.new(@image.reload).record["distance_m"])

    @image.update_columns(metadata: { "LRFTargetDistance" => 450.0 })
    assert_equal({ "value" => nil, "source" => "out_of_range" }, ThermalMeasurement.new(@image.reload).record["distance_m"])
  end

  test "気象データの湿度が SDK の範囲外なら渡さず、範囲外と残す" do
    @image.update_columns(humidity: 0.5)

    measurement = ThermalMeasurement.new(@image.reload)

    assert_not measurement.params.key?("humidity_percent")
    assert_equal "out_of_range", measurement.record["humidity_percent"]["source"]
  end

  test "放射率を入力しなければ、未設定（カメラ既定値）と記録・表示する" do
    record = ThermalMeasurement.new(@image).record

    assert_equal({ "value" => nil, "source" => "not_set" }, record["emissivity"])
    assert_includes ThermalMeasurement.describe(record), "放射率: 未設定（カメラ既定値。画像に記録された値を使用）"
  end

  test "表示用の 1 行には値と出どころを入れる" do
    lines = ThermalMeasurement.describe({ "distance_m" => { "value" => 41.5, "source" => "lrf" } })

    assert_equal [ "距離（m）: 41.5（レーザー距離計（画像ごと））" ], lines
  end

  test "測定パラメータの範囲は、解析エンジンの設定と同じ値にしている" do
    analyzer = JSON.parse(Rails.root.join("analyzer/analyzer/config/default_params.json").read)["measurement_ranges"]

    assert_equal AnalyzerConfig.current.measurement_ranges, analyzer.except("_comment").transform_values { |r| r.map(&:to_f) }
  end
end
