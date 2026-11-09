# 報告書の版（docs/IMPROVEMENT_PLAN.md Phase 7 の決定事項 2026-10-22・2026-11-09）。
# 版番号・発行日時・発行時の内容の固定コピー（snapshot）・内容の digest・改訂の理由。PDF は Active Storage（後で追加）
class CreateInspectionReports < ActiveRecord::Migration[8.1]
  def change
    create_table :inspection_reports do |t|
      t.references :inspection, null: false, foreign_key: true
      t.integer :version_number, null: false
      t.datetime :issued_at, null: false
      t.jsonb :snapshot, null: false, default: {}
      t.string :content_digest, null: false
      t.text :revision_reason
      t.jsonb :acknowledged_warnings, null: false, default: []
      t.timestamps
    end
    add_index :inspection_reports, %i[inspection_id version_number], unique: true
  end
end
