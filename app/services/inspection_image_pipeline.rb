# 品質チェックが終わった画像の次の段階（docs/IMPROVEMENT_PLAN.md Phase 4）。
# 合格（ok / warning）なら、架台を登録した発電所では位置合わせ、それ以外はグリッドの提案を作り、グリッドがあれば解析、無ければ needs_review（grid_required）
class InspectionImagePipeline
  def self.after_quality(image)
    return unless image.ready_for_analysis?

    # 架台を登録した発電所では、位置合わせでグリッドを自動で作る（docs/LAYOUT_OVERLAY_DESIGN.md の B）
    if LayoutAlignment.applicable?(image)
      image.update!(analysis_status: "pending", review_reason: nil)
      return AlignLayoutJob.perform_later(image.id)
    end
    if image.panel_grids.blank? && LayoutAlignment.site_has_layout?(image.inspection.site)
      image.update!(alignment: { "status" => "unavailable", "review_reason" => "georef_unusable",
                                 "message" => ImageGeoref.describe(image.georef) || "画像の位置（撮影情報）がありません" })
    end

    GridProposalJob.perform_later(image.id) if image.grid_proposal.nil? && !LayoutAlignment.site_has_layout?(image.inspection.site)
    if image.panel_grids.present?
      AnalyzeInspectionImageJob.perform_later(image.id)
    else
      image.update!(analysis_status: "needs_review", review_reason: "grid_required")
    end
  end
end
