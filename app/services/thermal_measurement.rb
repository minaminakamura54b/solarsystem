# 解析エンジンに渡す測定パラメータ（放射率・反射温度・湿度・距離）を画像ごとに組み立てる（2026-10-22 ユーザー指示）。
# - 放射率・反射温度・距離は点検ごとの入力、湿度は撮影時刻に合わせて割り当てた気象データ
# - 値が無い項目は渡さない（SDK・R-JPEG の既定のまま。どの値が使われるかと、SDK への渡し方は Phase S で確定する）
# - 渡した値と出どころを inspection_images.measurement_params に残す（報告書への記載と、再解析が要るかの表示に使う）
class ThermalMeasurement
  SOURCES = { "inspection" => "点検で入力", "weather" => "気象データ", "not_set" => "未入力（SDK・画像の既定）" }.freeze
  LABELS = { "emissivity" => "放射率", "reflected_temperature_c" => "反射温度（℃）",
             "humidity_percent" => "湿度（%）", "distance_m" => "距離（m）" }.freeze

  def initialize(image)
    @image = image
  end

  # 解析エンジンの --measurement に渡す値（値がある項目だけ）
  def params
    record.filter_map { |key, entry| [ key, entry["value"] ] unless entry["value"].nil? }.to_h
  end

  # 値と出どころ。inspection_images.measurement_params にこのまま保存する
  def record
    inspection = @image.inspection
    {
      "emissivity" => entry(inspection.emissivity, "inspection"),
      "reflected_temperature_c" => entry(inspection.reflected_temperature_c, "inspection"),
      "humidity_percent" => entry(@image.humidity, "weather"),
      "distance_m" => entry(inspection.object_distance_m, "inspection")
    }
  end

  # 解析したときの測定パラメータが、今の入力と同じか（違えば再解析で反映する）
  def current?
    @image.measurement_params.nil? || @image.measurement_params == record
  end

  private

  def entry(value, source)
    value.nil? ? { "value" => nil, "source" => "not_set" } : { "value" => value.to_f, "source" => source }
  end
end
