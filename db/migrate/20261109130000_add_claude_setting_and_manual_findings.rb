# Claude の所見・総括文を点検ごとに「使う／使わない」で切り替える（既定は使わない。2026-11-09 ユーザー指示）。
# 使わない点検では、所見・総括文を人が書く。外部のサービスに送った内容（いつ・何を）を点検ごとに記録する。
# 既存の点検も「使わない」になる（既存の行の値は変えず、列の既定値で入る）
class AddClaudeSettingAndManualFindings < ActiveRecord::Migration[8.1]
  def change
    add_column :inspections, :claude_enabled, :boolean, default: false, null: false
    add_column :inspections, :claude_enabled_changed_at, :datetime
    add_column :inspections, :manual_summary, :text
    add_column :inspections, :manual_summary_updated_at, :datetime
    add_column :anomalies, :manual_finding, :text
    add_column :anomalies, :manual_finding_updated_at, :datetime
    add_column :anomaly_groups, :manual_finding, :text
    add_column :anomaly_groups, :manual_finding_updated_at, :datetime

    create_table :external_transmissions do |t|
      t.references :inspection, null: false, foreign_key: true
      t.string :service, null: false # anthropic
      t.string :purpose, null: false # anomaly_explanation / inspection_summary
      t.string :target_type
      t.bigint :target_id
      t.string :model
      t.string :prompt_version
      t.text :input_text, null: false # 送った入力（数値・種類・パネル番号など。画像・座標は送らない）
      t.integer :input_bytes, null: false
      t.string :status, null: false # sending / sent / failed
      t.text :error
      t.datetime :sent_at, null: false
      t.timestamps
    end
    add_index :external_transmissions, %i[inspection_id sent_at]
  end
end
