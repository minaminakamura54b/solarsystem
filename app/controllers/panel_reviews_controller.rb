# パネルごとの候補の一覧（docs/LAYOUT_OVERLAY_DESIGN.md の C-1）。同じパネルの同じ場所の異常を 1 行にまとめ、
# 目印で絞り込んで、確定・却下（まとめて却下）する。種類・位置の修正は画像ごとのレビュー画面で行う
class PanelReviewsController < ApplicationController
  before_action :require_site
  before_action :find_inspection

  def show
    scope = @inspection.panel_candidates.includes(:panel, :anomalies, representative_anomaly: :inspection_image)
    @status = params[:status].presence_in(%w[pending all]) || "pending"
    @flag = params[:flag].presence_in(PanelCandidate::FLAGS.keys + [ "none" ])
    scope = scope.pending if @status == "pending"
    @candidates = scope.to_a
    @candidates.select! { |c| @flag == "none" ? c.flags.empty? : c.flags.include?(@flag) } if @flag
    @candidates.sort_by! { |c| [ c.pending? ? 0 : 1, -(c.observed_count.fdiv([ c.visible_count, 1 ].max)), -c.max_delta_t.to_f ] }
    @images = @inspection.inspection_images.index_by(&:id)
    @counts = @inspection.panel_candidates.pending.flat_map(&:flags).tally
    @pending_total = @inspection.panel_candidates.pending.count
  end

  def rebuild
    candidates = PanelCandidateBuilder.new(@inspection).call
    redirect_to inspection_panel_review_path(@inspection), notice: "パネルの候補を作り直しました（未判断 #{candidates.size} 件。判断済みの候補は変えていません）"
  end

  def confirm
    candidate = @inspection.panel_candidates.find(params[:id])
    PanelCandidateReview.new(candidate).confirm!(note: params.dig(:note, candidate.id.to_s))
    back(notice: "パネル #{candidate.panel.number} の候補を確定しました（ほかの画像の観測は重複としてまとめました）")
  rescue PanelCandidateReview::Error, AnomalyReview::Error => e
    back(alert: e.message)
  end

  def reject
    candidate = @inspection.panel_candidates.find(params[:id])
    PanelCandidateReview.new(candidate).reject!(reason: params.dig(:row_reason, candidate.id.to_s).to_s, note: params.dig(:note, candidate.id.to_s))
    back(notice: "パネル #{candidate.panel.number} の候補を却下しました")
  rescue PanelCandidateReview::Error, AnomalyReview::Error => e
    back(alert: e.message)
  end

  # 選んだ候補をまとめて却下する（目印で絞り込んだ一覧から、人が選んで行う）
  def bulk_reject
    ids = Array(params[:candidate_ids]).map(&:to_i)
    return back(alert: "却下する候補を選んでください") if ids.empty?

    reason = params[:reason].to_s
    candidates = @inspection.panel_candidates.pending.where(id: ids).to_a
    ActiveRecord::Base.transaction { candidates.each { |c| PanelCandidateReview.new(c).reject!(reason:) } }
    back(notice: "#{candidates.size} 件の候補を「#{AnomalyReview::REJECTION_REASONS[reason]}」として却下しました")
  rescue PanelCandidateReview::Error, AnomalyReview::Error => e
    back(alert: e.message)
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:inspection_id])
  end

  def back(**flash)
    redirect_to inspection_panel_review_path(@inspection, status: params[:status], flag: params[:flag]), flash
  end
end
