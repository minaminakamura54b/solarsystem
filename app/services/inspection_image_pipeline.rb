# 品質チェックが終わった画像の次の段階（docs/IMPROVEMENT_PLAN.md Phase 4）。
# 合格（ok / warning）なら、グリッドの提案を作り、グリッドがあれば解析、無ければ needs_review（grid_required）
class InspectionImagePipeline
  def self.after_quality(image)
    return unless image.ready_for_analysis?

    GridProposalJob.perform_later(image.id) if image.grid_proposal.nil?
    if image.panel_grids.present?
      AnalyzeInspectionImageJob.perform_later(image.id)
    else
      image.update!(analysis_status: "needs_review", review_reason: "grid_required")
    end
  end
end
