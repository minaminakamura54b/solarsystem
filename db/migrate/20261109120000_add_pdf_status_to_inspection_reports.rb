# 報告書の版の PDF（Active Storage の pdf）を作った日時と、作れなかったときのエラー
class AddPdfStatusToInspectionReports < ActiveRecord::Migration[8.1]
  def change
    add_column :inspection_reports, :pdf_generated_at, :datetime
    add_column :inspection_reports, :pdf_error, :text
  end
end
