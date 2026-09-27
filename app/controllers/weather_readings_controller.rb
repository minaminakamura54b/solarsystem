# 点検の気象データ（時刻付き）の登録・削除。変更したら全画像の気象データと品質チェックをやり直す
class WeatherReadingsController < ApplicationController
  before_action :require_site
  before_action :find_inspection

  def create
    @reading = @inspection.weather_readings.build(reading_params)
    @reading.observed_at = parse_local_time(params.dig(:weather_reading, :observed_at))
    if @reading.save
      RecheckInspectionQualityJob.perform_later(@inspection.id)
      redirect_to inspection_path(@inspection, anchor: "weather"), notice: "気象データを登録しました。画像の品質チェックをやり直します"
    else
      redirect_to inspection_path(@inspection, anchor: "weather"), alert: @reading.errors.full_messages.join(" / ")
    end
  end

  def destroy
    @inspection.weather_readings.find(params[:id]).destroy
    RecheckInspectionQualityJob.perform_later(@inspection.id)
    redirect_to inspection_path(@inspection, anchor: "weather"), notice: "気象データを削除しました。画像の品質チェックをやり直します"
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:inspection_id])
  end

  def reading_params
    params.require(:weather_reading).permit(:irradiance_w_m2, :irradiance_type, :wind_speed_m_s, :air_temp_c, :humidity)
  end

  # 入力された時刻は、撮影時刻と同じタイムゾーン（config/image_quality.yml の capture_time_zone）の現地時刻として解釈する
  def parse_local_time(value)
    return nil if value.blank?

    ImageQualityConfig.current.capture_time_zone.parse(value)
  rescue ArgumentError
    nil
  end
end
