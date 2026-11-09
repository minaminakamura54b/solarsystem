# 要確認・失敗の画像を理由ごとにまとめて除外する（docs/IMPROVEMENT_PLAN.md Phase 7 の決定事項 2026-11-09）。
# 一覧（理由ごとの枚数）→ 確認（写っていないまま残るパネルの数）→ 除外
class BulkExclusionsController < ApplicationController
  before_action :require_site
  before_action :find_inspection

  def show
    @exclusion = BulkImageExclusion.new(@inspection)
    @groups = @exclusion.groups
    @coverage = InspectionCoverage.new(@inspection).summary
    @group, @impact = @exclusion.preview(params[:reason]) if params[:reason].present?
  rescue BulkImageExclusion::Error => e
    redirect_to inspection_bulk_exclusion_path(@inspection), alert: e.message
  end

  def create
    count = BulkImageExclusion.new(@inspection).exclude!(params[:reason].to_s, image_ids: Array(params[:image_ids]), note: params[:note])
    redirect_to inspection_bulk_exclusion_path(@inspection), notice: "#{count} 枚を除外しました（取り消しは画像ごとに点検の画面で行えます）"
  rescue BulkImageExclusion::Error, ActiveRecord::RecordInvalid => e
    redirect_to inspection_bulk_exclusion_path(@inspection), alert: e.message
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:inspection_id])
  end
end
