# 架台（docs/LAYOUT_OVERLAY_DESIGN.md の A-1）。発電所の配置を、地上の座標付きの架台で登録する。
# パネルは架台から作り（段・列）、位置の対応はこの座標で行う
class CreatePvBlocks < ActiveRecord::Migration[8.1]
  def change
    create_table :pv_blocks do |t|
      t.references :site, null: false, foreign_key: true
      t.string :label, null: false
      # 4 隅（上端の始まり・上端の終わり・下端の終わり・下端の始まり の順）
      t.jsonb :corners_latlng, null: false
      t.jsonb :corners_local, null: false # 発電所の原点からの東・北（m）
      t.integer :rows, null: false
      t.integer :cols, null: false
      t.string :panel_orientation, null: false, default: "portrait"
      t.decimal :facing_azimuth_deg, precision: 6, scale: 2, null: false, default: 180
      t.decimal :tilt_deg, precision: 5, scale: 2
      t.decimal :upper_elevation_m, precision: 8, scale: 3
      t.decimal :lower_elevation_m, precision: 8, scale: 3
      t.string :source, null: false, default: "drawing" # drawing / image_map / manual
      t.timestamps
    end
    add_index :pv_blocks, %i[site_id label], unique: true

    add_column :sites, :geo_origin_lat, :decimal, precision: 10, scale: 7
    add_column :sites, :geo_origin_lng, :decimal, precision: 10, scale: 7

    add_reference :panels, :pv_block, foreign_key: { on_delete: :nullify }
    add_column :panels, :block_row, :integer
    add_column :panels, :block_col, :integer
  end
end
