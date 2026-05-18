class CreateSites < ActiveRecord::Migration[8.1]
  def change
    create_table :sites do |t|
      t.string :name, null: false
      t.string :location, null: false
      t.integer :panel_count, default: 0, null: false
      t.decimal :capacity_kw, precision: 8, scale: 2, default: 0.0
      t.string :status, default: "active", null: false
      t.text :description

      t.timestamps
    end

    add_index :sites, :status
  end
end