# 暫定の判定基準の版であることを残す（docs/IMPROVEMENT_PLAN.md Phase 7 の決定事項 2026-11-09）。
# 既存の行は変えない（暫定の版への印は bin/rails "rule_sets:mark_provisional[版]" で付ける）
class AddProvisionalToRuleSets < ActiveRecord::Migration[8.1]
  def change
    add_column :rule_sets, :provisional, :boolean, default: false, null: false
  end
end
