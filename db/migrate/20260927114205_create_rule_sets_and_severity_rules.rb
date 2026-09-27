# 重大度の閾値をルールセット単位でバージョン管理する（4.5）
class CreateRuleSetsAndSeverityRules < ActiveRecord::Migration[8.1]
  def change
    create_table :rule_sets do |t|
      t.string :version, null: false
      t.boolean :active, null: false, default: false
      t.text :note
      t.jsonb :detection_params, null: false, default: {}
      t.timestamps
    end
    add_index :rule_sets, :version, unique: true
    add_index :rule_sets, :active, unique: true, where: "active", name: "index_rule_sets_on_single_active"

    create_table :severity_rules do |t|
      t.references :rule_set, null: false, foreign_key: true
      t.string :anomaly_type, null: false
      t.string :measure, null: false
      t.decimal :normalized_mild, precision: 6, scale: 2, null: false
      t.decimal :normalized_warning, precision: 6, scale: 2, null: false
      t.decimal :normalized_critical, precision: 6, scale: 2, null: false
      t.decimal :raw_mild, precision: 6, scale: 2, null: false
      t.decimal :raw_warning, precision: 6, scale: 2, null: false
      t.decimal :raw_critical, precision: 6, scale: 2, null: false
      t.timestamps
    end
    add_index :severity_rules, [ :rule_set_id, :anomaly_type ], unique: true
  end
end
