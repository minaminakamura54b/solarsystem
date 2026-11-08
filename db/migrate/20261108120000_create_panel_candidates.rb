# パネルの候補（docs/LAYOUT_OVERLAY_DESIGN.md の C-1。2026-11-08 ユーザー承認）。
# 同じパネルの同じ場所の異常（画像ごとの観測）を束ね、「N 枚中 M 枚」と目印を記録する。判定（重大度）は変えない
class CreatePanelCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :panel_candidates do |t|
      t.references :inspection, null: false, foreign_key: true
      t.references :panel, null: false, foreign_key: true
      t.string :kind, null: false # area（パネルの面状の発熱）/ point（点状の発熱）
      t.jsonb :location # point のとき、パネルの中の位置 { "u" => 0〜1（列の始まりから）, "v" => 0〜1（上端から） }
      t.string :anomaly_type, null: false # 代表の観測の種類（表示用）
      t.references :representative_anomaly, foreign_key: { to_table: :anomalies, on_delete: :nullify }
      t.integer :observed_count, null: false, default: 0 # M: この場所で異常が出た画像の数
      t.integer :visible_count, null: false, default: 0 # N: このパネルを解析できた画像の数（端で切れていない）
      t.jsonb :flags, null: false, default: []
      t.jsonb :observations, null: false, default: [] # 画像ごと: image_id・sequence・y（画像内の縦位置）・positive・delta_t
      t.string :review_status, null: false, default: "pending"
      t.boolean :locked, null: false, default: false
      t.string :rejection_reason
      t.text :reviewer_note
      t.datetime :reviewed_at
      t.string :config_version
      t.timestamps
    end
    add_reference :anomalies, :panel_candidate, foreign_key: { on_delete: :nullify }
  end
end
