class CreateRevenues < ActiveRecord::Migration[8.1]
  def change
    create_table :revenues do |t|
      t.references :site, null: false, foreign_key: true
      t.integer :year, null: false
      t.integer :month, null: false
      t.decimal :amount_yen, precision: 12, scale: 0, default: 0
      t.decimal :kwh, precision: 10, scale: 2, default: 0.0

      t.timestamps
    end

    add_index :revenues, [ :site_id, :year, :month ], unique: true
  end
end
