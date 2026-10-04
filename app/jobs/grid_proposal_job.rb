# 品質チェックに合格した画像に、解析エンジンの propose-grid を実行してグリッドの提案を保存する（Phase 4-2）。
# 提案はグリッド入力画面の初期値にするだけで、解析には使わない。失敗しても画像のステータスは変えない
class GridProposalJob < ApplicationJob
  queue_as :default

  def perform(image_id)
    image = InspectionImage.find_by(id: image_id)
    return unless image&.ready_for_analysis?

    result = image.thermal.open { |file| AnalyzeInspectionImageJob.client.propose_grid(thermal_path: file.path) }
    proposal = result.ok? ? result.output["grid_proposal"] : nil
    image.update_columns(grid_proposal: proposal, updated_at: Time.current)
  rescue => e
    Rails.logger.warn("GridProposalJob failed: #{e.class}: #{e.message}")
  end
end
