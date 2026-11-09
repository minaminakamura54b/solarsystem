# 報告書（docs/IMPROVEMENT_PLAN.md Phase 7）。版の一覧と発行（index・create）、今の内容のプレビュー（preview）、
# 発行した版（show）。報告書の内容は版の固定コピー（ReportSnapshotBuilder）だけから描く。PDF は ferrum_pdf の承認後に追加する
class ReportsController < ApplicationController
  before_action :require_site
  before_action :find_inspection

  def index
    @issue = ReportIssue.new(@inspection)
    @reports = @inspection.inspection_reports.latest_first.to_a
    @warnings = @issue.snapshot["warnings"]
    @blockers = @issue.blockers
  end

  def preview
    @snapshot = ReportSnapshotBuilder.new(@inspection).build
    @preview = true
    render :show, layout: "report"
  end

  def show
    @report = @inspection.inspection_reports.find(params[:id])
    @snapshot = @report.snapshot
    render layout: "report"
  end

  def create
    report = ReportIssue.new(@inspection).issue!(
      acknowledge_warnings: params[:acknowledge_warnings] == "1", revision_reason: params[:revision_reason],
      company_name: params[:company_name], qualification: params[:qualification]
    )
    redirect_to inspection_reports_path(@inspection), notice: "報告書の#{report.title}を発行しました"
  rescue ReportIssue::Error => e
    redirect_to inspection_reports_path(@inspection), alert: e.message
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:inspection_id])
  end
end
