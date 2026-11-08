# 架台・段の候補（案 X 改。2026-11-08 ユーザー承認）。点検の全画像から、架台の段ごとの温度の効果（見え方の影響を飛行全体で
# 1 つの関数として除いた後の、画像をまたいだ中央値）を出し、ルールセットの block_row の閾値で候補にする
class CreateBlockRowFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :block_row_findings do |t|
      t.references :inspection, null: false, foreign_key: true
      t.references :pv_block, null: false, foreign_key: true
      t.integer :block_row, null: false
      t.string :status, null: false # evaluated（判定した）/ insufficient（判断の材料が足りない）
      t.string :insufficient_reason
      t.decimal :effect_c, precision: 6, scale: 3
      t.integer :views_count, null: false, default: 0
      t.integer :upper_views, null: false, default: 0
      t.integer :lower_views, null: false, default: 0
      t.jsonb :observations, null: false, default: [] # 画像ごと: image_id・sequence・y・effect・bbox（段の範囲）
      t.string :severity # 閾値未満・判断の材料が足りないときは null（候補ではない）
      t.references :rule_set, foreign_key: true
      t.string :rule_version
      t.jsonb :rule_snapshot
      t.string :review_status, null: false, default: "pending"
      t.boolean :locked, null: false, default: false
      t.string :rejection_reason
      t.text :reviewer_note
      t.datetime :reviewed_at
      t.string :config_version
      t.timestamps
    end
    add_index :block_row_findings, %i[inspection_id pv_block_id block_row], unique: true, name: "index_block_row_findings_on_inspection_block_row"
    add_column :inspections, :view_model, :jsonb # 見え方の影響の関数（係数・観測の数・使えたか）
  end
end
