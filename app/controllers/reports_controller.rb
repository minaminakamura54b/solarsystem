# 報告書（docs/IMPROVEMENT_PLAN.md Phase 7）。版の一覧と発行（index・create）、今の内容のプレビュー（preview）、
# 発行した版（show）・その PDF（pdf・regenerate_pdf）。報告書の内容は版の固定コピー（ReportSnapshotBuilder）だけから描く
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
      company_name: params[:company_name], qualification: params[:qualification], addressee: params[:addressee]
    )
    ReportPdfJob.perform_later(report.id)
    redirect_to inspection_reports_path(@inspection), notice: "報告書の#{report.title}を発行しました（PDF を作ります）"
  rescue ReportIssue::Error => e
    redirect_to inspection_reports_path(@inspection), alert: e.message
  end

  def pdf
    report = @inspection.inspection_reports.find(params[:id])
    return redirect_to(inspection_reports_path(@inspection), alert: "#{report.title}の PDF はまだありません") unless report.pdf.attached?

    redirect_to rails_blob_path(report.pdf, disposition: "attachment")
  end

  # PDF が作れなかった・まだ無い版の PDF を作り直す（版の内容は変えない）
  def regenerate_pdf
    report = @inspection.inspection_reports.find(params[:id])
    ReportPdfJob.perform_later(report.id)
    redirect_to inspection_reports_path(@inspection), notice: "#{report.title}の PDF を作り直します"
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:inspection_id])
  end
end
