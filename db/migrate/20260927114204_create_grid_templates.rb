# 同じ高度・ジンバル角で撮った画像に使い回すパネルのグリッド（4.2。UI は Phase 4）
class CreateGridTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :grid_templates do |t|
      t.references :inspection, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :rows, null: false
      t.integer :cols, null: false
      t.jsonb :corners, null: false, default: []
      t.string :panel_orientation, null: false, default: "landscape"
      t.decimal :altitude_m, precision: 8, scale: 2
      t.decimal :gimbal_pitch, precision: 6, scale: 2
      t.decimal :gimbal_yaw, precision: 6, scale: 2
      t.jsonb :start_panel_ref
      t.timestamps
    end
  end
end
