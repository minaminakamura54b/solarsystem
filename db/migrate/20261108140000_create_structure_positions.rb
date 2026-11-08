# 発電所ごとの「部材の位置」（案 A。2026-11-08 ユーザー承認）。架台の中の位置（段・列・パネルの中の区画）で表す。
# この位置に出た点状の発熱の候補に目印を付けるだけで、自動では却下せず、検出も変えない
class CreateStructurePositions < ActiveRecord::Migration[8.1]
  def change
    create_table :structure_positions do |t|
      t.references :site, null: false, foreign_key: true
      t.integer :block_row, null: false
      t.integer :block_col, null: false
      t.integer :u_bin, null: false # パネルの中の区画（列の始まりから）
      t.integer :v_bin, null: false # パネルの中の区画（上端から）
      t.integer :bins, null: false # パネルを縦横それぞれ何等分した区画か
      t.text :note
      t.references :source_inspection, foreign_key: { to_table: :inspections, on_delete: :nullify }
      t.timestamps
    end
    add_index :structure_positions, %i[site_id block_row block_col u_bin v_bin bins], unique: true, name: "index_structure_positions_on_site_and_position"
  end
end
