# 解析エンジンの出力（status = completed）を、画像の異常（anomalies）と異常群（anomaly_groups）として保存する。
# 未確定の異常・群は作り直し、人が確定・修正・却下・手動追加したもの（locked）は残す。重大度は SeverityRuleEngine で付ける。
# - locked の異常と bbox の IoU が locked_overlap_iou 以上で重なる候補は作らない（同じ異常を再び候補にしない）
# - locked の群とパネルが重なる群は作らない
# - 証拠レベルは検出時点ではすべて C（RGB の確認・電気測定はレビューで入力して B / A にする。2026-10-15 ユーザー指示）
# - 架台との位置合わせで作ったグリッド（pv_block_id あり）の異常は、グリッドの行・列から架台のパネルに割り当てる（位置情報による
#   割り当て。docs/LAYOUT_OVERLAY_DESIGN.md の B-3）。割り当ての根拠を panel_assignment_history に残す。それ以外は今までどおり人が割り当てる
class AnalysisResultImporter
  def initialize(image, output, rule_set, overlap_iou: AnalyzerConfig.current.locked_overlap_iou)
    @image = image
    @output = output
    @engine = SeverityRuleEngine.new(rule_set)
    @overlap_iou = overlap_iou
  end

  attr_reader :skipped_anomalies, :skipped_groups

  BASIS = { "layout" => "位置合わせ（自動）", "layout_adjusted" => "位置合わせの下書きを人が直したグリッド" }.freeze

  def import!
    ActiveRecord::Base.transaction do
      @image.anomalies.where(locked: false).delete_all
      @image.anomaly_groups.where(locked: false).destroy_all
      locked_boxes = @image.anomalies.where(locked: true).map { |a| a.final_bbox.presence || a.bbox }.compact
      locked_panels = @image.anomaly_groups.where(locked: true).flat_map(&:panel_indices)
      @skipped_anomalies = 0
      @skipped_groups = 0

      groups_by_panel = {}
      Array(@output["groups"]).each do |data|
        if (data["panel_indices"] & locked_panels).any?
          @skipped_groups += 1
          next
        end
        group = @image.anomaly_groups.build(
          inspection: @image.inspection, group_type: data["type"], panel_count: data["panel_indices"].size,
          panel_indices: data["panel_indices"], measure: data["measure"], delta_t: data["delta_t"],
          normalized_delta_t: data["normalized_delta_t"], threshold_basis: data["threshold_basis"]
        )
        @engine.apply(group).save!
        data["panel_indices"].each { |index| groups_by_panel[index] = group }
      end

      Array(@output["anomalies"]).each do |data|
        if locked_boxes.any? { |box| Bbox.iou(box, data["bbox"]) >= @overlap_iou }
          @skipped_anomalies += 1
          next
        end
        anomaly = @image.anomalies.build(
          inspection: @image.inspection, panel_index_in_image: data["panel_index"],
          anomaly_type: data["anomaly_type"], detection: data["detection"], active_bands: data["active_bands"],
          bbox: data["bbox"], t_max: data["t_max"], t_mean: data["t_mean"], t_min: data["t_min"],
          baseline_temp: data["baseline_temp"], delta_t: data["delta_t"], measure: data["measure"],
          normalized_delta_t: data["normalized_delta_t"], threshold_basis: data["threshold_basis"],
          area_ratio: data["area_ratio"], shape_features: data["shape"], flags: Array(data["flags"]),
          evidence_level: "C", review_status: "pending",
          # 群の構成パネル（module_wide）は群に紐付ける（計上は群を1件とする。docs/IMPROVEMENT_PLAN.md 4.4）
          anomaly_group: data["anomaly_type"] == "module_wide" ? groups_by_panel[data["panel_index"]] : nil
        )
        assign_layout_panel(anomaly, data["panel_index"])
        @engine.apply(anomaly).save!
      end

      @image.update!(
        raw_analysis: @output, analyzer_version: @output["analyzer_version"],
        analysis_status: "completed", review_reason: nil, error_message: nil
      )
    end
  end

  private

  # 画像内のパネル番号（グリッド順・グリッド内は行優先）→ 架台の段・列 → パネル
  def assign_layout_panel(anomaly, index)
    return if index.nil?

    offset = 0
    Array(@image.panel_grids).each do |grid|
      count = grid["rows"].to_i * grid["cols"].to_i
      if index < offset + count
        return unless BASIS.key?(grid["source"]) && grid["pv_block_id"]

        local = index - offset
        panel = Panel.find_by(pv_block_id: grid["pv_block_id"], block_row: local / grid["cols"].to_i + 1, block_col: local % grid["cols"].to_i + 1)
        return unless panel

        anomaly.panel = panel
        anomaly.panel_assignment_history = anomaly.panel_assignment_history + [ {
          "panel_number" => panel.number, "assigned_by" => grid["source"], "basis" => BASIS[grid["source"]],
          "alignment_residual_ratio" => @image.alignment&.dig("residual", "panel_width_ratio"), "assigned_at" => Time.current.iso8601
        }.compact ]
        return
      end
      offset += count
    end
  end
end
