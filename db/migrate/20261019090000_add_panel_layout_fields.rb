# 実配置の登録（docs/IMPROVEMENT_PLAN.md Phase 5b）。列の追加のみで、既存の値は変えない
# - panels.pcs_number: パワコン番号（将来の発電量・電気測定データとの紐付け用。任意）
# - anomalies.panel_assignment_history: 配置の置き換えで外れたパネルの紐付けの履歴（元のパネル番号など）
# - anomalies.panel_reassignment_required: 紐付けが外れ、人が割り当て直す必要がある
class AddPanelLayoutFields < ActiveRecord::Migration[8.1]
  def change
    add_column :panels, :pcs_number, :string

    change_table :anomalies, bulk: true do |t|
      t.jsonb :panel_assignment_history, default: [], null: false
      t.boolean :panel_reassignment_required, default: false, null: false
    end
  end
end
