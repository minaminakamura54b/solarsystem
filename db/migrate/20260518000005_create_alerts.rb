class CreateAlerts < ActiveRecord::Migration[8.1]
  def change
    create_table :alerts do |t|
      t.references :site, null: false, foreign_key: true
      t.references :inspection, foreign_key: true
      t.references :panel, foreign_key: true
      t.string :title, null: false
      t.text :message
      t.string :severity, default: "info", null: false
      t.datetime :read_at

      t.timestamps
    end

    add_index :alerts, :severity
    add_index :alerts, :read_at
    add_index :alerts, :created_at
  end
end