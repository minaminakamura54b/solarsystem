# 報告書の「発電所の様子」のサーモ画像（見直し R4）。人が差し替えたときだけ画像の id を持つ（NULL = 自動の提案を使う）
class AddReportOverviewImageIdsToInspections < ActiveRecord::Migration[8.1]
  def change
    add_column :inspections, :report_overview_image_ids, :jsonb
  end
end
