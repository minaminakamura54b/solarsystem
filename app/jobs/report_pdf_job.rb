# 発行した報告書の版の PDF を作る（ReportPdf）。開発は :inline（発行と同時）、本番は Solid Queue
class ReportPdfJob < ApplicationJob
  queue_as :default

  def perform(report_id)
    report = InspectionReport.find_by(id: report_id)
    return unless report

    ReportPdf.new(report, kind: :customer).call
    ReportPdf.new(report, kind: :internal).call
  end
end
