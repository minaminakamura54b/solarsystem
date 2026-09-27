# config/image_quality.yml の読み込み
class ImageQualityConfig
  attr_reader :version, :min_width, :min_height, :min_poa_irradiance_w_m2,
              :weather_max_gap_minutes, :radiometric_tags, :capture_time_zone

  def self.current
    new(Rails.application.config_for(:image_quality))
  end

  def initialize(values)
    values = values.to_h.with_indifferent_access
    @version = values.fetch(:version)
    @min_width = values.fetch(:min_width)
    @min_height = values.fetch(:min_height)
    @min_poa_irradiance_w_m2 = values.fetch(:min_poa_irradiance_w_m2)
    @weather_max_gap_minutes = values.fetch(:weather_max_gap_minutes)
    @radiometric_tags = Array(values.fetch(:radiometric_tags)).map(&:to_s)
    @capture_time_zone = ActiveSupport::TimeZone[values.fetch(:capture_time_zone)] ||
      raise(ArgumentError, "capture_time_zone が不正です: #{values[:capture_time_zone]}")
  end
end
