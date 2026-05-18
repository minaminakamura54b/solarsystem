class CreateInspections < ActiveRecord::Migration[8.1]
  def change
    create_table :inspections do |t|
      t.references :site, null: false, foreign_key: true
      t.datetime :conducted_at, null: false
      t.string :severity, default: "normal", null: false
      t.text :result
      t.text :report
      t.string :analysis_status, default: "pending", null: false
      t.json :anomalies, default: []
      t.integer :anomaly_count, default: 0

      t.timestamps
    end

    add_index :inspections, :conducted_at
    add_index :inspections, :severity
    add_index :inspections, :analysis_status
  end
end