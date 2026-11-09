# config/layout_overlay.yml の読み込み（配置図と位置情報によるパネルの自動特定の設定）
class LayoutOverlayConfig
  attr_reader :version, :max_residual_panel_width_ratio, :max_off_nadir_deg, :require_rtk_fixed, :max_rtk_std_m, :cameras

  def self.current
    new(Rails.application.config_for(:layout_overlay))
  end

  def initialize(values)
    values = values.to_h.with_indifferent_access
    georef = values.fetch(:georef).to_h.with_indifferent_access
    @version = values.fetch(:version).to_s
    @max_residual_panel_width_ratio = values.fetch(:max_residual_panel_width_ratio).to_f
    @max_off_nadir_deg = georef.fetch(:max_off_nadir_deg).to_f
    @require_rtk_fixed = georef.fetch(:require_rtk_fixed) == true
    @max_rtk_std_m = georef.fetch(:max_rtk_std_m).to_f
    @cameras = values.fetch(:cameras, {}).to_h.to_h { |model, spec| [ model.to_s, spec.to_h.transform_keys(&:to_s) ] }
  end

  # カメラの画素の角度（mrad/画素）。設定に無ければ nil
  def ifov_mrad(camera_model)
    cameras.dig(camera_model.to_s, "ifov_mrad")&.to_f
  end

  # 同時撮影の RGB の画素の角度（mrad/画素）と基準の横の画素数。設定に無ければ nil
  def rgb_optics(camera_model)
    spec = cameras[camera_model.to_s].to_h
    return nil unless spec["rgb_ifov_mrad"] && spec["rgb_reference_width"]

    { ifov_mrad: spec["rgb_ifov_mrad"].to_f, reference_width: spec["rgb_reference_width"].to_i }
  end
end
