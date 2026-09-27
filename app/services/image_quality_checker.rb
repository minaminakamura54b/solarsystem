# 画像の品質チェック（docs/IMPROVEMENT_PLAN.md Phase 2-4）。
# rejected の項目が1つでもあれば、解析せずに needs_review にする（正常にはしない）
class ImageQualityChecker
  Check = Data.define(:key, :result, :message) # result: ok / warning / rejected

  def initialize(image, config: ImageQualityConfig.current)
    @image = image
    @config = config
  end

  def report
    checks = [ radiometric, resolution, captured_at, gps, irradiance ]
    status =
      if checks.any? { |c| c.result == "rejected" } then "rejected"
      elsif checks.any? { |c| c.result == "warning" } then "warning"
      else "ok"
      end

    {
      "status" => status,
      "review_reason" => checks.find { |c| c.result == "rejected" }&.key,
      "checks" => checks.map { |c| c.to_h.transform_keys(&:to_s) },
      "config_version" => @config.version,
      "checked_at" => Time.current.iso8601
    }
  end

  private

  def radiometric
    case @image.is_radiometric
    when true
      Check.new("radiometric", "ok", "温度データあり（メタデータによる仮判定。最終判定は解析エンジンで行う）")
    when false
      Check.new("no_radiometric", "rejected", "温度データ（放射温度）が見つかりません。R-JPEG などの温度データ付き画像が必要です")
    else
      Check.new("metadata_unreadable", "rejected", "メタデータを読み取れず、温度データの有無を判定できません")
    end
  end

  def resolution
    w = @image.width
    h = @image.height
    if w.nil? || h.nil?
      Check.new("low_resolution", "rejected", "解像度を取得できません")
    elsif w < @config.min_width || h < @config.min_height
      Check.new("low_resolution", "rejected", "解像度 #{w}×#{h} が基準（#{@config.min_width}×#{@config.min_height} 以上）を下回っています")
    else
      Check.new("resolution", "ok", "解像度 #{w}×#{h}")
    end
  end

  def captured_at
    if @image.captured_at
      Check.new("captured_at", "ok", "撮影時刻 #{@image.captured_at.in_time_zone(@config.capture_time_zone).strftime('%Y/%m/%d %H:%M:%S')}")
    else
      Check.new("missing_captured_at", "rejected", "撮影時刻がありません（気象データを割り当てられません）")
    end
  end

  def gps
    if @image.gps_lat && @image.gps_lng
      Check.new("gps", "ok", "位置情報あり")
    else
      Check.new("missing_gps", "warning", "位置情報（GPS）がありません")
    end
  end

  def irradiance
    value = @image.irradiance_w_m2
    type = @image.irradiance_type

    if value.nil?
      Check.new("missing_irradiance", "warning", "日射量が未入力です（ΔT を正規化できません）")
    elsif type == "poa" && value < @config.min_poa_irradiance_w_m2
      Check.new("low_irradiance", "rejected", "日射量 #{value.to_f.round} W/m²（POA）が基準（#{@config.min_poa_irradiance_w_m2} W/m² 以上）を下回っています")
    elsif type == "poa"
      Check.new("irradiance", "ok", "日射量 #{value.to_f.round} W/m²（POA）")
    else
      label = type == "ghi" ? "GHI（水平面）" : "種類不明"
      Check.new("irradiance_not_poa", "warning", "日射量 #{value.to_f.round} W/m² は#{label}のため、ΔT を正規化しません")
    end
  end
end
