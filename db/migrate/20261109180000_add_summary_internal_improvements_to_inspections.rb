# 総括文 v4（見直し R3）の、社内向けの撮影・解析の改善点（顧客向けの報告書には載せない）
class AddSummaryInternalImprovementsToInspections < ActiveRecord::Migration[8.1]
  def change
    add_column :inspections, :summary_internal_improvements, :jsonb
  end
end
