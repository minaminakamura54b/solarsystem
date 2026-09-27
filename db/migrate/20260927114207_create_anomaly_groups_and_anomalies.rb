# 解析エンジンの検出結果（4.3 / 4.4）。書き込むのは Phase 4 以降
class CreateAnomalyGroupsAndAnomalies < ActiveRecord::Migration[8.1]
  def change
    create_table :anomaly_groups do |t|
      t.references :inspection_image, null: false, foreign_key: true
      t.references :inspection, null: false, foreign_key: true
      t.string :group_type, null: false
      t.integer :panel_count, null: false
      t.jsonb :panel_indices, null: false, default: []
      t.string :measure
      t.decimal :delta_t, precision: 6, scale: 2
      t.decimal :normalized_delta_t, precision: 6, scale: 2
      t.string :threshold_basis
      t.string :severity
      t.references :rule_set, foreign_key: true
      t.string :rule_version
      t.jsonb :rule_snapshot
      t.string :electrical_string_ref
      t.string :review_status, null: false, default: "pending"
      t.boolean :locked, null: false, default: false
      t.decimal :affected_dc_kw, precision: 8, scale: 3
      t.text :loss_basis
      t.timestamps
    end

    create_table :anomalies do |t|
      t.references :inspection_image, null: false, foreign_key: true
      t.references :inspection, null: false, foreign_key: true
      t.references :anomaly_group, foreign_key: true
      t.references :panel, foreign_key: true
      t.integer :panel_index_in_image
      t.string :anomaly_type, null: false
      t.string :severity
      t.jsonb :bbox
      t.decimal :t_max, precision: 6, scale: 2
      t.decimal :t_mean, precision: 6, scale: 2
      t.decimal :t_min, precision: 6, scale: 2
      t.decimal :baseline_temp, precision: 6, scale: 2
      t.decimal :delta_t, precision: 6, scale: 2
      t.string :measure
      t.decimal :normalized_delta_t, precision: 6, scale: 2
      t.string :threshold_basis
      t.decimal :area_ratio, precision: 6, scale: 4
      t.jsonb :shape_features
      t.jsonb :flags, null: false, default: []
      t.string :evidence_level
      t.jsonb :electrical_evidence
      t.references :rule_set, foreign_key: true
      t.string :rule_version
      t.jsonb :rule_snapshot
      t.string :review_status, null: false, default: "pending"
      t.string :final_anomaly_type
      t.jsonb :final_bbox
      t.string :final_severity
      t.datetime :reviewed_at
      t.text :reviewer_note
      t.boolean :locked, null: false, default: false
      t.jsonb :cause_candidates
      t.text :recommended_action
      t.text :explanation
      t.string :prompt_version
      t.decimal :affected_dc_kw, precision: 8, scale: 3
      t.decimal :estimated_loss_kw, precision: 8, scale: 3
      t.text :loss_basis
      t.timestamps
    end
  end
end
