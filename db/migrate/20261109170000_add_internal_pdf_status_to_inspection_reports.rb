# 社内向けの作業記録の PDF（見直し R2。版ごとに残す）を作った日時と、作れなかったときのエラー
class AddInternalPdfStatusToInspectionReports < ActiveRecord::Migration[8.1]
  def change
    add_column :inspection_reports, :internal_pdf_generated_at, :datetime
    add_column :inspection_reports, :internal_pdf_error, :text
  end
end
