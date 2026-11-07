# 登録した架台と画像の位置合わせ（docs/LAYOUT_OVERLAY_DESIGN.md の B）。対象の判定と、解析エンジンへの入力づくり。
# - 対象: 架台を登録した発電所の、位置合わせに使える画像（georef の usable）で、グリッドがまだ無いもの
# - 架台の標高が無ければ、最後に作った架台の地図の候補の推定値（パネル面の標高・上端と下端の高さの差）を使う
# - 画素の角度の倍率も、候補の推定値があれば使う（無ければ 1.0。補正の拡大縮小でも吸収する）
class LayoutAlignment
  NEAR_M = 40.0 # 画像の中心からこの距離に隅がある架台だけを渡す

  def self.site_has_layout?(site) = site.pv_blocks.exists?

  def self.applicable?(image)
    image.panel_grids.blank? && image.georef&.dig("usable") == true && site_has_layout?(image.inspection.site)
  end

  def initialize(image, config: LayoutOverlayConfig.current)
    @image = image
    @site = image.inspection.site
    @config = config
  end

  def input(thermal_path)
    camera = @image.georef["camera"]
    frame = GeoFrame.new(@site.geo_origin_lat, @site.geo_origin_lng)
    ce, cn = frame.to_local(camera["lat"], camera["lng"])
    blocks = @site.pv_blocks.select do |b|
      b.corners_local.any? { |e, n| Math.hypot(e - ce, n - cn) <= NEAR_M }
    end
    est = latest_estimate
    {
      origin: { lat: @site.geo_origin_lat.to_f, lng: @site.geo_origin_lng.to_f },
      max_residual_panel_width_ratio: @config.max_residual_panel_width_ratio,
      ifov_ratio: est["ifov_ratio"] || 1.0,
      panel_elevation_m: est["panel_elevation_m"],
      edge_height_delta_m: est["edge_height_delta_m"] || 0.0,
      image: {
        id: @image.id.to_s, thermal: thermal_path.to_s, lrf_target_abs_alt_m: @image.georef.dig("lrf", "target_abs_alt_m"),
        camera: camera.slice("lat", "lng", "abs_alt_m", "image_up_azimuth_deg", "ifov_mrad", "width", "height")
      },
      blocks: blocks.map do |b|
        { id: b.id, label: b.label, rows: b.rows, cols: b.cols, corners_latlng: b.corners_latlng, panel_orientation: b.panel_orientation,
          upper_elevation_m: b.upper_elevation_m&.to_f, lower_elevation_m: b.lower_elevation_m&.to_f }
      end
    }
  end

  # 画像に残す記録（下書きのグリッドは、位置合わせできなかったときだけ手動のグリッドの画面で使う）
  def record(output, aligned:)
    output.slice("status", "review_reason", "message", "residual", "correction", "matches", "gsd_m", "panel_width_m", "blocks_in_view")
          .merge("config_version" => @config.version, "threshold_ratio" => @config.max_residual_panel_width_ratio,
                 "estimate_source" => latest_estimate.present? ? "block_map_proposal" : nil, "at" => Time.current.iso8601)
          .merge(aligned ? {} : { "draft_grids" => Array(output["draft_grids"]).presence || Array(output["grids"]) })
  end

  private

  def latest_estimate
    @latest_estimate ||= @site.block_map_proposals.where(status: "proposed").order(created_at: :desc).first&.result&.dig("estimated").to_h
  end
end
