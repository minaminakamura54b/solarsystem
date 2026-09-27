# 画像に気象データを割り当てて品質チェックを行い、結果とステータスを設定する（保存はしない）
class InspectionImageQuality
  def self.apply(image, config: ImageQualityConfig.current)
    weather = WeatherInterpolator.new(image.inspection.weather_readings.to_a, config: config)
    image.assign_attributes(weather.attributes_for(image.captured_at))

    report = ImageQualityChecker.new(image, config: config).report
    image.quality_report = report
    image.error_message = nil
    if report["status"] == "rejected"
      image.analysis_status = "needs_review"
      image.review_reason = report["review_reason"]
    else
      image.analysis_status = "pending"
      image.review_reason = nil
    end
    image
  end
end
