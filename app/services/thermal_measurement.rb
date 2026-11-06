# 解析エンジンに渡す測定パラメータ（放射率・反射温度・湿度・距離）を画像ごとに組み立てる（2026-10-22 ユーザー指示。
# 出どころの決め方は 2026-11-06 ユーザー指示）。
# - 距離: 画像ごとのレーザー距離計の値 → 点検ごとの入力 → どちらも無ければ渡さない（画像に記録された値を SDK が使う）
# - 放射率・反射温度: 点検ごとの入力。無ければ渡さない（カメラの既定値）。放射率は根拠のある値が分かるまで推測で決めない
# - 湿度: 撮影時刻に合わせて割り当てた気象データ
# - SDK が受け付ける範囲（config/analyzer.yml の measurement_ranges）の外の値は渡さず、出どころに「範囲外」と残す
# - 渡した値と出どころを inspection_images.measurement_params に残す（報告書への記載と、再解析が要るかの表示に使う）
class ThermalMeasurement
  SOURCES = {
    "lrf" => "レーザー距離計（画像ごと）",
    "inspection" => "点検で入力",
    "weather" => "気象データ",
    "out_of_range" => "範囲外のため未使用（カメラ既定値。画像に記録された値を使用）",
    "not_set" => "未設定（カメラ既定値。画像に記録された値を使用）"
  }.freeze
  LABELS = { "emissivity" => "放射率", "reflected_temperature_c" => "反射温度（℃）",
             "humidity_percent" => "湿度（%）", "distance_m" => "距離（m）" }.freeze

  def initialize(image, config: AnalyzerConfig.current)
    @image = image
    @config = config
  end

  # 解析エンジンの --measurement に渡す値（値がある項目だけ）
  def params
    record.filter_map { |key, entry| [ key, entry["value"] ] unless entry["value"].nil? }.to_h
  end

  # 値と出どころ。inspection_images.measurement_params にこのまま保存する
  def record
    inspection = @image.inspection
    {
      "emissivity" => entry("emissivity", [ inspection.emissivity, "inspection" ]),
      "reflected_temperature_c" => entry("reflected_temperature_c", [ inspection.reflected_temperature_c, "inspection" ]),
      "humidity_percent" => entry("humidity_percent", [ @image.humidity, "weather" ]),
      "distance_m" => entry("distance_m", [ @image.lrf_distance_m, "lrf" ], [ inspection.object_distance_m, "inspection" ])
    }
  end

  # 解析したときの測定パラメータが、今の入力と同じか（違えば再解析で反映する）
  def current?
    @image.measurement_params.nil? || @image.measurement_params == record
  end

  # 画面・報告書向けの 1 行（例: "放射率: 未設定（カメラ既定値。…）"、"距離（m）: 41.5（レーザー距離計（画像ごと））"）
  def self.describe(stored)
    LABELS.filter_map do |key, label|
      entry = stored&.dig(key) or next
      source = SOURCES.fetch(entry["source"], entry["source"])
      entry["value"].nil? ? "#{label}: #{source}" : "#{label}: #{entry['value']}（#{source}）"
    end
  end

  private

  # 候補を順に見て、値があり SDK の範囲内の最初のものを使う。値はあるが範囲外のものしか無ければ out_of_range
  def entry(key, *candidates)
    out_of_range = false
    candidates.each do |value, source|
      next if value.nil?
      return { "value" => value.to_f, "source" => source } if @config.measurement_in_range?(key, value)

      out_of_range = true
    end
    { "value" => nil, "source" => out_of_range ? "out_of_range" : "not_set" }
  end
end
