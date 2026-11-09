# 点検の対象範囲（見直し R1）。アプリの案（広め）を配置図の上で直し、人が確定する。取り消すと発電所全体に戻る
class InspectionScopesController < ApplicationController
  before_action :require_site
  before_action :find_inspection

  def show
    @scope = InspectionScope.new(@inspection)
    @proposal = @scope.proposal
    @blocks = @inspection.site.pv_blocks.order(:label).to_a
    @selected = @inspection.scope_confirmed? ? Array(@inspection.scope_block_ids) : @proposal
  end

  def update
    InspectionScope.new(@inspection).confirm!(params[:block_ids], source: params[:source])
    redirect_to inspection_path(@inspection, anchor: "report-settings"), notice: "点検の対象範囲を確定しました（#{InspectionScope.new(@inspection.reload).description}）"
  rescue InspectionScope::Error => e
    redirect_to inspection_scope_path(@inspection), alert: e.message
  end

  def destroy
    InspectionScope.new(@inspection).clear!
    redirect_to inspection_path(@inspection, anchor: "report-settings"), notice: "点検の対象範囲の確定を取り消しました（発電所全体として数えます）"
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:inspection_id])
  end
end
