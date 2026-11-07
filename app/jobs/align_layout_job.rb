# 登録した架台を画像に重ね、位置を補正してグリッド（パネル領域）を自動で作る（docs/LAYOUT_OVERLAY_DESIGN.md の B-2・B-3）。
# - 残差が閾値以内で、列に沿う向き・直交する向きの手がかりがあれば、グリッドを保存して解析へ進む
# - それ以外（架台が写っていない・端が写っていない・残差が大きい・解析エンジンの失敗）は needs_review（alignment_failed）。
#   正常にはしない。下書きのグリッドを残し、手動のグリッドの画面で人が直して保存する
# - パネル・Site の状態は変えない
class AlignLayoutJob < ApplicationJob
  queue_as :default

  def perform(image_id)
    image = InspectionImage.find_by(id: image_id)
    return unless image&.ready_for_analysis?
    return unless LayoutAlignment.applicable?(image)

    alignment = LayoutAlignment.new(image)
    result = image.open_thermal do |path|
      AnalyzeInspectionImageJob.client.align_layout(input: alignment.input(path), dir: File.dirname(path))
    end
    output = result.output
    if output && output["status"] == "aligned" && result.ok?
      image.update!(panel_grids: output["grids"], alignment: alignment.record(output, aligned: true))
      AnalyzeInspectionImageJob.perform_later(image.id)
    else
      output ||= { "status" => "failed", "review_reason" => "analyzer_error", "message" => result.message || "解析エンジンの出力を読めませんでした" }
      image.update!(analysis_status: "needs_review", review_reason: "alignment_failed", alignment: alignment.record(output, aligned: false))
    end
    image.inspection.refresh_status!
  rescue => e
    Rails.logger.error("AlignLayoutJob failed: #{e.class}: #{e.message}")
    return unless image

    image.update_columns(analysis_status: "needs_review", review_reason: "alignment_failed",
                         alignment: { "status" => "failed", "review_reason" => "error", "message" => e.message }, updated_at: Time.current)
    image.inspection.refresh_status!
  end
end
