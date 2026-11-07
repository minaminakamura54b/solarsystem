# 画像の位置（georef）の記録を作る（docs/LAYOUT_OVERLAY_DESIGN.md の B-1）。
# 画素と地上の座標の対応の計算そのものは解析エンジン（analyzer/analyzer/geo/projection.py）で行う。ここでは、
# 計算に使う撮影情報を集め、自動の位置合わせに使えるか（usable）と、使えない理由（issues）を残す。
# 使えない画像も失敗にはしない（手動のグリッドで解析できる）。位置合わせのときに「位置合わせ不可（要確認）」にする
class ImageGeoref
  ISSUES = {
    "no_gps" => "撮影位置（GPS）がありません",
    "no_absolute_altitude" => "絶対高度（AbsoluteAltitude）がありません",
    "no_gimbal_angles" => "ジンバルの角度がありません",
    "not_nadir" => "カメラが真下を向いていません",
    "rtk_not_fixed" => "RTK が固定解ではありません",
    "rtk_std_large" => "RTK の位置の標準偏差が大きすぎます",
    "unknown_camera" => "このカメラの画素の角度が設定にありません（config/layout_overlay.yml）"
  }.freeze

  RTK_FIXED = 50

  def initialize(image, config: LayoutOverlayConfig.current)
    @image = image
    @meta = image.metadata.to_h
    @config = config
  end

  def record
    issues = []
    issues << "no_gps" if @image.gps_lat.nil? || @image.gps_lng.nil?
    abs_alt = number("AbsoluteAltitude")
    issues << "no_absolute_altitude" if abs_alt.nil?
    yaw, pitch, roll = number("GimbalYawDegree"), number("GimbalPitchDegree"), number("GimbalRollDegree")
    if [ yaw, pitch, roll ].any?(&:nil?)
      issues << "no_gimbal_angles"
    elsif (pitch + 90).abs > @config.max_off_nadir_deg
      issues << "not_nadir"
    end
    rtk_flag = number("RtkFlag")&.to_i
    issues << "rtk_not_fixed" if @config.require_rtk_fixed && rtk_flag != RTK_FIXED
    std = %w[RtkStdLon RtkStdLat RtkStdHgt].to_h { |key| [ key, number(key) ] }
    issues << "rtk_std_large" if std.values.compact.any? { |v| v > @config.max_rtk_std_m }
    ifov = @config.ifov_mrad(@image.camera_model)
    issues << "unknown_camera" if ifov.nil?

    {
      "version" => @config.version,
      "usable" => issues.empty?,
      "issues" => issues,
      "camera" => {
        "lat" => @image.gps_lat&.to_f, "lng" => @image.gps_lng&.to_f, "abs_alt_m" => abs_alt,
        "gimbal_yaw" => yaw, "gimbal_pitch" => pitch, "gimbal_roll" => roll,
        # 真下向きのとき、画像の上が向く方位（北から時計回り）。飛行 008（yaw 約 179.5°・roll 180°）で北が上になることを確認
        "image_up_azimuth_deg" => (yaw && roll) ? ((yaw - roll) % 360).round(3) : nil,
        "width" => @image.width, "height" => @image.height,
        "ifov_mrad" => ifov, "ifov_source" => ifov ? "config" : nil
      },
      "rtk" => { "status" => @meta["GpsStatus"], "flag" => rtk_flag, "std_m" => std.transform_keys { |k| k.delete_prefix("RtkStd").downcase } },
      "lrf" => lrf
    }
  end

  def self.describe(georef)
    return nil if georef.blank?
    return "位置合わせに使えます（RTK 固定解・真下向き）" if georef["usable"]

    "位置合わせに使えません: " + Array(georef["issues"]).map { |issue| ISSUES.fetch(issue, issue) }.join("、")
  end

  private

  def lrf
    return nil unless @meta["LRFStatus"].to_s == "Normal"

    { "distance_m" => number("LRFTargetDistance"), "target_abs_alt_m" => number("LRFTargetAbsAlt") }
  end

  def number(key)
    value = @meta[key]
    return nil if value.nil? || value.to_s.strip.empty?
    Float(value.to_s.delete_prefix("+"), exception: false)
  end
end
