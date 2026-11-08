# 点検の異常を、パネルの候補（同じパネルの同じ場所）に束ねる（docs/LAYOUT_OVERLAY_DESIGN.md の C-1。2026-11-08 ユーザー承認）。
# - 対象: パネルが割り当てられた異常で、異常群（隣接パネル群）に属さないもの。群は今までどおり画像ごとにレビューする
# - 面状の発熱（partial_module・module_wide・substring_bypass）は同じパネルなら 1 つ、点状の発熱（hotspot・multi_hotspot）は
#   パネルの中の位置が point_merge_distance 以内なら 1 つにまとめる
# - N = そのパネルを解析できた画像の数（解析結果のパネルのうち端で切れていないもの）、M = 異常が出た画像の数
# - 目印（判定は変えない。レビューで絞り込むため）: 1 枚だけ・写る位置で変わる・多くの架台の同じ位置
# - 人が判断した候補（locked）は作り直さない（束ねた観測も変えない）。それ以外は毎回作り直す
class PanelCandidateBuilder
  def initialize(inspection, config: PanelCandidateConfig.current)
    @inspection = inspection
    @config = config
  end

  def call
    ActiveRecord::Base.transaction do
      @inspection.panel_candidates.where(locked: false).find_each do |c|
        c.anomalies.update_all(panel_candidate_id: nil)
        c.delete
      end
      anomalies = @inspection.anomalies.where(anomaly_group_id: nil, panel_candidate_id: nil).where.not(panel_id: nil)
                             .includes(:inspection_image, :panel).to_a
      clusters = cluster(anomalies)
      candidates = clusters.map { |panel_id, kind, members, location| build(panel_id, kind, members, location) }
      flag_same_position(candidates)
      candidates.each(&:save!)
      candidates.each { |c| Anomaly.where(id: c.instance_variable_get(:@member_ids)).update_all(panel_candidate_id: c.id) }
      candidates
    end
  end

  private

  def cluster(anomalies)
    out = []
    anomalies.group_by(&:panel_id).each do |panel_id, list|
      area, point = list.partition { |a| PanelCandidate.kind_for(a.anomaly_type) == "area" }
      out << [ panel_id, "area", area, nil ] if area.any?
      groups = []
      point.each do |a|
        loc = location(a)
        target = groups.find { |g| loc && g[:loc] && Math.hypot(g[:loc][0] - loc[0], g[:loc][1] - loc[1]) <= @config.point_merge_distance }
        if target
          target[:members] << a
        else
          groups << { loc: loc, members: [ a ] }
        end
      end
      groups.each { |g| out << [ panel_id, "point", g[:members], g[:loc] ] }
    end
    out
  end

  def build(panel_id, kind, members, loc)
    visible = visibility[panel_id] || {}
    positive_images = members.map(&:inspection_image_id).uniq
    observations = visible.map do |image_id, info|
      mine = members.select { |a| a.inspection_image_id == image_id }
      { "image_id" => image_id, "sequence" => info[:sequence], "y" => info[:y].round(3), "bbox" => info[:bbox],
        "positive" => mine.any?, "delta_t" => mine.map { |a| a.delta_t.to_f }.max }
    end.sort_by { |o| o["sequence"] }
    representative = members.min_by { |a| center_distance(a) }
    candidate = @inspection.panel_candidates.build(
      panel_id:, kind:, location: loc && { "u" => loc[0].round(3), "v" => loc[1].round(3) },
      anomaly_type: representative.effective_type, representative_anomaly: representative,
      observed_count: positive_images.size, visible_count: [ visible.size, positive_images.size ].max,
      observations:, flags: base_flags(observations, positive_images.size, visible.size), config_version: @config.version
    )
    candidate.instance_variable_set(:@member_ids, members.map(&:id))
    candidate
  end

  def base_flags(observations, m, n)
    flags = []
    flags << "single_view" if m == 1 && n >= @config.flags["single_view_min_visible"].to_i
    pos = observations.select { |o| o["positive"] }.map { |o| o["y"] }
    neg = observations.reject { |o| o["positive"] }.map { |o| o["y"] }
    if pos.any? && neg.any? && (pos.sum / pos.size - neg.sum / neg.size).abs >= @config.flags["position_bias_min_diff"].to_f
      flags << "position_biased"
    end
    flags
  end

  # 点状の発熱で、架台の中の同じ位置（段・列・パネルの中の区画）に、多くの架台で出ているもの
  def flag_same_position(candidates)
    bins = @config.flags["same_position_grid_bins"].to_i
    points = candidates.select { |c| c.kind == "point" && c.location }
    return if points.empty?

    panels = Panel.where(id: points.map(&:panel_id)).index_by(&:id)
    key = lambda do |c|
      p = panels[c.panel_id]
      [ p.block_row, p.block_col, (c.location["u"] * bins).floor.clamp(0, bins - 1), (c.location["v"] * bins).floor.clamp(0, bins - 1) ]
    end
    blocks_with_points = points.map { |c| panels[c.panel_id].pv_block_id }.uniq.size
    points.group_by(&key).each_value do |list|
      blocks = list.map { |c| panels[c.panel_id].pv_block_id }.uniq.size
      next unless blocks >= @config.flags["same_position_min_blocks"].to_i && blocks >= blocks_with_points * @config.flags["same_position_min_block_ratio"].to_f

      list.each { |c| c.flags = (c.flags + [ "same_position" ]).uniq }
    end
  end

  # パネル ID → { 画像 ID → { sequence, y, bbox } }（解析結果のパネルのうち、端で切れていないもの）
  def visibility
    @visibility ||= begin
      map = Hash.new { |h, k| h[k] = {} }
      panel_of = Panel.where(site_id: @inspection.site_id).where.not(pv_block_id: nil)
                      .pluck(:pv_block_id, :block_row, :block_col, :id).to_h { |b, r, c, id| [ [ b, r, c ], id ] }
      @inspection.inspection_images.where(analysis_status: "completed").find_each do |image|
        grids = Array(image.panel_grids)
        Array(image.raw_analysis&.dig("panels")).each do |p|
          next if p["excluded"]

          grid = grids[p["grid_index"].to_i]
          next unless grid && grid["pv_block_id"]

          id = panel_of[[ grid["pv_block_id"], p["row"].to_i + 1, p["col"].to_i + 1 ]]
          next unless id

          b = p["bbox"]
          map[id][image.id] = { sequence: image.sequence, y: (b["y1"].to_f + b["y2"].to_f) / 2, bbox: b }
        end
      end
      map
    end
  end

  # 異常の中心の、パネルの中の位置（列の始まりから u・上端から v）。解析結果のパネルの 4 隅から逆に求める
  def location(anomaly)
    polygon = Array(anomaly.inspection_image.raw_analysis&.dig("panels")).find { |p| p["index"] == anomaly.panel_index_in_image }&.dig("polygon")
    box = anomaly.bbox
    return nil unless polygon&.size == 4 && box

    Homography.unit_to_quad(polygon).inverse_point((box["x1"].to_f + box["x2"].to_f) / 2, (box["y1"].to_f + box["y2"].to_f) / 2)
              &.map { |v| v.clamp(0.0, 1.0) }
  end

  def center_distance(anomaly)
    b = anomaly.bbox || {}
    Math.hypot((b["x1"].to_f + b["x2"].to_f) / 2 - 0.5, (b["y1"].to_f + b["y2"].to_f) / 2 - 0.5)
  end
end
