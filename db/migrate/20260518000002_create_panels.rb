class CreatePanels < ActiveRecord::Migration[8.1]
  def change
    create_table :panels do |t|
      t.references :site, null: false, foreign_key: true
      t.string :number, null: false
      t.integer :position_x, null: false
      t.integer :position_y, null: false
      t.string :status, default: "normal", null: false
      t.datetime :last_inspected_at

      t.timestamps
    end

    add_index :panels, [ :site_id, :number ], unique: true
    add_index :panels, :status
  end
end
