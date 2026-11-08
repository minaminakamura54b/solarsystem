# 画像1枚を解析エンジンで解析する（docs/IMPROVEMENT_PLAN.md Phase 4-4）。
# 品質チェック合格 → グリッドが無ければ needs_review（grid_required）→ 解析 → 異常・群を保存 → 重大度を付ける。
# 解析エンジンの終了コードでステータスを決める。失敗・要確認は正常扱いにしない。パネル・Site の状態は変えない
class AnalyzeInspectionImageJob < ApplicationJob
  queue_as :default

  class << self
    # テストで偽の解析エンジンに差し替えるためのフック。本番では常に ThermalAnalyzerClient
    attr_writer :client

    def client
      @client || ThermalAnalyzerClient.new
    end
  end

  def perform(image_id)
    image = InspectionImage.find_by(id: image_id)
    return unless image
    return unless image.ready_for_analysis?

    if image.panel_grids.blank?
      image.update!(analysis_status: "needs_review", review_reason: "grid_required")
      return image.inspection.refresh_status!
    end

    rule_set = RuleSet.active_set
    return mark_failed(image, "有効な判定基準（ルールセット）がありません", "no_rule_set") unless rule_set

    measurement = ThermalMeasurement.new(image)
    # 解析エンジンに渡した測定パラメータを残す（結果の成否に関係なく、渡した値の記録）
    image.update!(analysis_status: "analyzing", review_reason: nil, error_message: nil, measurement_params: measurement.record)
    image.inspection.refresh_status!
    result = image.open_thermal do |path|
      self.class.client.analyze(
        thermal_path: path, panel_grids: image.panel_grids, module_spec: image.inspection.site.analyzer_module_spec,
        rules: rule_set.to_analyzer_rules, irradiance: image.irradiance_w_m2&.to_f, irradiance_type: image.irradiance_type,
        measurement: measurement.params
      )
    end
    handle(image, result, rule_set)
    image.inspection.refresh_status!
    build_panel_candidates(image.inspection)
  rescue => e
    Rails.logger.error("AnalyzeInspectionImageJob failed: #{e.class}: #{e.message}")
    mark_failed(image, "解析中にエラーが発生しました: #{e.message}") if image
  end

  private

  # 点検の画像の解析がすべて終わったら、パネルの候補と架台・段の候補を作り直す（架台を登録した発電所だけ）。
  # 失敗しても画像の解析結果には影響させない（候補は「作り直す」でやり直せる）
  def build_panel_candidates(inspection)
    return unless LayoutAlignment.site_has_layout?(inspection.site)

    # 複数のワーカーで最後の画像がほぼ同時に終わっても、作り直しが重ならないよう点検の行をロックしてから確かめる
    inspection.with_lock do
      next if inspection.inspection_images.where(analysis_status: %w[pending analyzing]).exists?

      PanelCandidateBuilder.new(inspection).call
      BlockRowEffect.new(inspection).call
    end
  rescue => e
    Rails.logger.error("PanelCandidateBuilder / BlockRowEffect failed: #{e.class}: #{e.message}")
  end

  def handle(image, result, rule_set)
    if result.timed_out?
      mark_failed(image, result.message, "timeout")
    elsif result.error
      mark_failed(image, result.message, result.error)
    elsif result.ok? && result.status == "completed"
      AnalysisResultImporter.new(image, result.output, rule_set).import!
    elsif result.status == "needs_review"
      image.update!(analysis_status: "needs_review", review_reason: result.review_reason,
                    error_message: result.message, raw_analysis: result.output)
    else
      mark_failed(image, result.message, result.review_reason || "analyzer_error", raw_analysis: result.output)
    end
  end

  # トランザクションやバリデーションの影響を受けずに、確実に failed にする
  def mark_failed(image, message, reason = nil, raw_analysis: nil)
    attrs = { analysis_status: "failed", review_reason: reason, error_message: message, updated_at: Time.current }
    attrs[:raw_analysis] = raw_analysis if raw_analysis
    image.update_columns(attrs)
    image.inspection.refresh_status!
  end
end
