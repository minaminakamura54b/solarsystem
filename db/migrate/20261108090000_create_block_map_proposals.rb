# 点検の画像から作った架台の地図の候補（docs/LAYOUT_OVERLAY_DESIGN.md の A-3）。人が確認して架台の CSV として登録するまでは使わない
class CreateBlockMapProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :block_map_proposals do |t|
      t.references :site, null: false, foreign_key: true
      t.references :inspection, null: false, foreign_key: true
      t.string :status, null: false, default: "pending" # pending / running / proposed / needs_review / failed
      t.jsonb :params, null: false, default: {} # モジュールの寸法・段数・パネルの向く方位
      t.jsonb :result # 解析エンジンの出力（推定値・合い方・架台）
      t.integer :image_count
      t.text :message
      t.timestamps
    end
  end
end
