# 報告書の「発電所の様子」のサーモ画像（見直し R4）。自動の提案を、人が候補の画像から差し替える（最大 4 枚）
class ReportOverviewsController < ApplicationController
  PER_PAGE = 48

  before_action :require_site
  before_action :find_inspection

  def show
    @overview = ReportOverview.new(@inspection)
    @selected = @overview.selected_ids.filter_map { |id| @overview.candidate(id) }
    list = @overview.candidates
    @block = params[:block].to_s.strip.upcase.presence
    list = list.select { |c| c.blocks.to_s.upcase.include?(@block) } if @block
    @total = list.size
    @pages = [ (@total.to_f / PER_PAGE).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @pages)
    @candidates = list.slice((@page - 1) * PER_PAGE, PER_PAGE) || []
  end

  def update
    overview = ReportOverview.new(@inspection)
    params[:remove].present? ? overview.remove!(params[:remove]) : overview.add!(params[:add])
    redirect_to inspection_report_overview_path(@inspection, block: params[:block], page: params[:page]), notice: "発電所の様子の画像を変えました"
  rescue ReportOverview::Error => e
    redirect_to inspection_report_overview_path(@inspection, block: params[:block], page: params[:page]), alert: e.message
  end

  def destroy
    ReportOverview.new(@inspection).reset!
    redirect_to inspection_report_overview_path(@inspection), notice: "自動の提案に戻しました"
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:inspection_id])
  end
end
