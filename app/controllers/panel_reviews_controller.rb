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
    # 登録済みの部材の位置に出た候補は、目印で絞り込んだときだけ表示する（たたんで表示。自動では却下しない）
    unless @flag
      @hidden_structure = @candidates.count { |c| c.flags.include?("registered_structure") }
      @candidates.reject! { |c| c.flags.include?("registered_structure") }
    end
    @candidates.sort_by! { |c| [ c.pending? ? 0 : 1, -(c.observed_count.fdiv([ c.visible_count, 1 ].max)), -c.max_delta_t.to_f ] }
    @images = @inspection.inspection_images.index_by(&:id)
    @counts = @inspection.panel_candidates.pending.flat_map(&:flags).tally
    @pending_total = @inspection.panel_candidates.pending.count
    rows = @inspection.block_row_findings.includes(:pv_block).to_a
    @row_candidates = rows.select(&:candidate?).sort_by { |r| [ r.pending? ? 0 : 1, -r.effect_c.to_f ] }
    @row_candidates.select!(&:pending?) if @status == "pending"
    @row_insufficient = rows.select { |r| r.status == "insufficient" }.sort_by { |r| [ r.pv_block.label, r.block_row ] }
    @row_all = rows
  end

  def rebuild
    candidates = PanelCandidateBuilder.new(@inspection).call
    rows = BlockRowEffect.new(@inspection).call
    redirect_to inspection_panel_review_path(@inspection),
                notice: "パネルの候補（未判断 #{candidates.size} 件）と架台・段の候補（#{rows.count(&:candidate?)} 件）を作り直しました。判断済みのものは変えていません"
  end

  def confirm_row
    row = @inspection.block_row_findings.find(params[:id])
    BlockRowReview.new(row).confirm!(note: params.dig(:note, "row_#{row.id}"))
    back(notice: "#{row.label} の候補を確定しました")
  rescue BlockRowReview::Error => e
    back(alert: e.message)
  end

  def reject_row
    row = @inspection.block_row_findings.find(params[:id])
    BlockRowReview.new(row).reject!(reason: params.dig(:row_reason, "row_#{row.id}").to_s, note: params.dig(:note, "row_#{row.id}"))
    back(notice: "#{row.label} の候補を却下しました")
  rescue BlockRowReview::Error => e
    back(alert: e.message)
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
    candidates = @inspection.panel_candidates.pending.includes(:panel).where(id: ids).to_a
    registered = 0
    ActiveRecord::Base.transaction do
      candidates.each { |c| PanelCandidateReview.new(c).reject!(reason:) }
      registered = register_structure_positions(candidates) if reason == "structure" && params[:register_structure] == "1"
    end
    notice = "#{candidates.size} 件の候補を「#{AnomalyReview::REJECTION_REASONS[reason]}」として却下しました"
    notice += "。部材の位置を #{registered} か所登録しました（次の点検から目印を付けます）" if registered.positive?
    back(notice:)
  rescue PanelCandidateReview::Error, AnomalyReview::Error => e
    back(alert: e.message)
  end

  private

  # 「部材・構造物」で却下した点状の発熱の候補の位置（段・列・パネルの中の区画）を、発電所の部材の位置として登録する（案 A）
  def register_structure_positions(candidates)
    bins = PanelCandidateConfig.current.flags["same_position_grid_bins"].to_i
    keys = candidates.select { |c| c.kind == "point" && c.location }.map { |c| StructurePosition.key_for(c.panel, c.location, bins) }.uniq
    keys.count do |row, col, u, v, b|
      position = @inspection.site.structure_positions.find_or_initialize_by(block_row: row, block_col: col, u_bin: u, v_bin: v, bins: b)
      next false if position.persisted?

      position.update!(source_inspection: @inspection, note: "点検 #{@inspection.conducted_at&.strftime('%Y/%m/%d')} のパネルごとの候補で「部材・構造物」として却下")
      true
    end
  end

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
