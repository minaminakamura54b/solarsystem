# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_09_140000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "alerts", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "inspection_id"
    t.bigint "panel_id"
    t.string "title", null: false
    t.text "message"
    t.string "severity", default: "info", null: false
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "anomaly_id"
    t.bigint "anomaly_group_id"
    t.index ["anomaly_group_id"], name: "index_alerts_on_anomaly_group_id"
    t.index ["anomaly_id"], name: "index_alerts_on_anomaly_id"
    t.index ["created_at"], name: "index_alerts_on_created_at"
    t.index ["inspection_id"], name: "index_alerts_on_inspection_id"
    t.index ["panel_id"], name: "index_alerts_on_panel_id"
    t.index ["read_at"], name: "index_alerts_on_read_at"
    t.index ["severity"], name: "index_alerts_on_severity"
    t.index ["site_id"], name: "index_alerts_on_site_id"
  end

  create_table "anomalies", force: :cascade do |t|
    t.bigint "inspection_image_id", null: false
    t.bigint "inspection_id", null: false
    t.bigint "anomaly_group_id"
    t.bigint "panel_id"
    t.integer "panel_index_in_image"
    t.string "anomaly_type", null: false
    t.string "severity"
    t.jsonb "bbox"
    t.decimal "t_max", precision: 6, scale: 2
    t.decimal "t_mean", precision: 6, scale: 2
    t.decimal "t_min", precision: 6, scale: 2
    t.decimal "baseline_temp", precision: 6, scale: 2
    t.decimal "delta_t", precision: 6, scale: 2
    t.string "measure"
    t.decimal "normalized_delta_t", precision: 6, scale: 2
    t.string "threshold_basis"
    t.decimal "area_ratio", precision: 6, scale: 4
    t.jsonb "shape_features"
    t.jsonb "flags", default: [], null: false
    t.string "evidence_level"
    t.jsonb "electrical_evidence"
    t.bigint "rule_set_id"
    t.string "rule_version"
    t.jsonb "rule_snapshot"
    t.string "review_status", default: "pending", null: false
    t.string "final_anomaly_type"
    t.jsonb "final_bbox"
    t.string "final_severity"
    t.datetime "reviewed_at"
    t.text "reviewer_note"
    t.boolean "locked", default: false, null: false
    t.jsonb "cause_candidates"
    t.text "recommended_action"
    t.text "explanation"
    t.string "prompt_version"
    t.decimal "affected_dc_kw", precision: 8, scale: 3
    t.decimal "estimated_loss_kw", precision: 8, scale: 3
    t.text "loss_basis"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "detection"
    t.integer "active_bands"
    t.jsonb "selected_causes", default: [], null: false
    t.string "rejection_reason"
    t.jsonb "additional_checks"
    t.text "report_text"
    t.string "explanation_input_digest"
    t.datetime "explained_at"
    t.text "explanation_error"
    t.jsonb "panel_assignment_history", default: [], null: false
    t.boolean "panel_reassignment_required", default: false, null: false
    t.bigint "duplicate_of_id"
    t.bigint "panel_candidate_id"
    t.text "manual_finding"
    t.datetime "manual_finding_updated_at"
    t.index ["anomaly_group_id"], name: "index_anomalies_on_anomaly_group_id"
    t.index ["duplicate_of_id"], name: "index_anomalies_on_duplicate_of_id"
    t.index ["inspection_id"], name: "index_anomalies_on_inspection_id"
    t.index ["inspection_image_id"], name: "index_anomalies_on_inspection_image_id"
    t.index ["panel_candidate_id"], name: "index_anomalies_on_panel_candidate_id"
    t.index ["panel_id"], name: "index_anomalies_on_panel_id"
    t.index ["rule_set_id"], name: "index_anomalies_on_rule_set_id"
  end

  create_table "anomaly_groups", force: :cascade do |t|
    t.bigint "inspection_image_id", null: false
    t.bigint "inspection_id", null: false
    t.string "group_type", null: false
    t.integer "panel_count", null: false
    t.jsonb "panel_indices", default: [], null: false
    t.string "measure"
    t.decimal "delta_t", precision: 6, scale: 2
    t.decimal "normalized_delta_t", precision: 6, scale: 2
    t.string "threshold_basis"
    t.string "severity"
    t.bigint "rule_set_id"
    t.string "rule_version"
    t.jsonb "rule_snapshot"
    t.string "electrical_string_ref"
    t.string "review_status", default: "pending", null: false
    t.boolean "locked", default: false, null: false
    t.decimal "affected_dc_kw", precision: 8, scale: 3
    t.text "loss_basis"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "reviewed_at"
    t.text "reviewer_note"
    t.string "rejection_reason"
    t.jsonb "cause_candidates"
    t.text "explanation"
    t.jsonb "additional_checks"
    t.text "recommended_action"
    t.text "report_text"
    t.string "prompt_version"
    t.string "explanation_input_digest"
    t.datetime "explained_at"
    t.text "explanation_error"
    t.text "manual_finding"
    t.datetime "manual_finding_updated_at"
    t.index ["inspection_id"], name: "index_anomaly_groups_on_inspection_id"
    t.index ["inspection_image_id"], name: "index_anomaly_groups_on_inspection_image_id"
    t.index ["rule_set_id"], name: "index_anomaly_groups_on_rule_set_id"
  end

  create_table "block_map_proposals", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "inspection_id", null: false
    t.string "status", default: "pending", null: false
    t.jsonb "params", default: {}, null: false
    t.jsonb "result"
    t.integer "image_count"
    t.text "message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["inspection_id"], name: "index_block_map_proposals_on_inspection_id"
    t.index ["site_id"], name: "index_block_map_proposals_on_site_id"
  end

  create_table "block_row_findings", force: :cascade do |t|
    t.bigint "inspection_id", null: false
    t.bigint "pv_block_id", null: false
    t.integer "block_row", null: false
    t.string "status", null: false
    t.string "insufficient_reason"
    t.decimal "effect_c", precision: 6, scale: 3
    t.integer "views_count", default: 0, null: false
    t.integer "upper_views", default: 0, null: false
    t.integer "lower_views", default: 0, null: false
    t.jsonb "observations", default: [], null: false
    t.string "severity"
    t.bigint "rule_set_id"
    t.string "rule_version"
    t.jsonb "rule_snapshot"
    t.string "review_status", default: "pending", null: false
    t.boolean "locked", default: false, null: false
    t.string "rejection_reason"
    t.text "reviewer_note"
    t.datetime "reviewed_at"
    t.string "config_version"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["inspection_id", "pv_block_id", "block_row"], name: "index_block_row_findings_on_inspection_block_row", unique: true
    t.index ["inspection_id"], name: "index_block_row_findings_on_inspection_id"
    t.index ["pv_block_id"], name: "index_block_row_findings_on_pv_block_id"
    t.index ["rule_set_id"], name: "index_block_row_findings_on_rule_set_id"
  end

  create_table "external_transmissions", force: :cascade do |t|
    t.bigint "inspection_id", null: false
    t.string "service", null: false
    t.string "purpose", null: false
    t.string "target_type"
    t.bigint "target_id"
    t.string "model"
    t.string "prompt_version"
    t.text "input_text", null: false
    t.integer "input_bytes", null: false
    t.string "status", null: false
    t.text "error"
    t.datetime "sent_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.integer "cache_creation_input_tokens"
    t.integer "cache_read_input_tokens"
    t.index ["inspection_id", "sent_at"], name: "index_external_transmissions_on_inspection_id_and_sent_at"
    t.index ["inspection_id"], name: "index_external_transmissions_on_inspection_id"
  end

  create_table "grid_templates", force: :cascade do |t|
    t.bigint "inspection_id", null: false
    t.string "name", null: false
    t.integer "rows", null: false
    t.integer "cols", null: false
    t.jsonb "corners", default: [], null: false
    t.string "panel_orientation", default: "landscape", null: false
    t.decimal "altitude_m", precision: 8, scale: 2
    t.decimal "gimbal_pitch", precision: 6, scale: 2
    t.decimal "gimbal_yaw", precision: 6, scale: 2
    t.jsonb "start_panel_ref"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["inspection_id"], name: "index_grid_templates_on_inspection_id"
  end

  create_table "inspection_images", force: :cascade do |t|
    t.bigint "inspection_id", null: false
    t.integer "sequence", null: false
    t.string "thermal_filename"
    t.datetime "captured_at"
    t.string "camera_model"
    t.boolean "is_radiometric"
    t.integer "width"
    t.integer "height"
    t.decimal "gps_lat", precision: 10, scale: 7
    t.decimal "gps_lng", precision: 10, scale: 7
    t.decimal "altitude_m", precision: 8, scale: 2
    t.decimal "gimbal_pitch", precision: 6, scale: 2
    t.decimal "gimbal_yaw", precision: 6, scale: 2
    t.jsonb "metadata", default: {}, null: false
    t.decimal "irradiance_w_m2", precision: 7, scale: 1
    t.string "irradiance_type"
    t.decimal "wind_speed_m_s", precision: 5, scale: 2
    t.decimal "air_temp_c", precision: 5, scale: 2
    t.decimal "humidity", precision: 5, scale: 2
    t.jsonb "quality_report"
    t.string "analysis_status", default: "pending", null: false
    t.string "review_reason"
    t.text "exclusion_note"
    t.jsonb "panel_grids", default: [], null: false
    t.jsonb "grid_proposal"
    t.string "analyzer_version"
    t.jsonb "raw_analysis"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "measurement_params"
    t.jsonb "georef"
    t.jsonb "alignment"
    t.index ["analysis_status"], name: "index_inspection_images_on_analysis_status"
    t.index ["inspection_id", "sequence"], name: "index_inspection_images_on_inspection_id_and_sequence", unique: true
    t.index ["inspection_id"], name: "index_inspection_images_on_inspection_id"
  end

  create_table "inspection_reports", force: :cascade do |t|
    t.bigint "inspection_id", null: false
    t.integer "version_number", null: false
    t.datetime "issued_at", null: false
    t.jsonb "snapshot", default: {}, null: false
    t.string "content_digest", null: false
    t.text "revision_reason"
    t.jsonb "acknowledged_warnings", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "pdf_generated_at"
    t.text "pdf_error"
    t.index ["inspection_id", "version_number"], name: "index_inspection_reports_on_inspection_id_and_version_number", unique: true
    t.index ["inspection_id"], name: "index_inspection_reports_on_inspection_id"
  end

  create_table "inspections", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.datetime "conducted_at", null: false
    t.string "severity"
    t.text "result"
    t.text "report"
    t.string "analysis_status", default: "pending", null: false
    t.json "legacy_anomalies", default: []
    t.integer "anomaly_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "error_message"
    t.string "review_reason"
    t.text "weather_note"
    t.datetime "reviewed_at"
    t.text "summary_text"
    t.jsonb "summary_priority_actions"
    t.jsonb "summary_additional_checks"
    t.string "summary_prompt_version"
    t.string "summary_input_digest"
    t.datetime "summary_generated_at"
    t.text "summary_error"
    t.decimal "emissivity", precision: 4, scale: 3
    t.decimal "reflected_temperature_c", precision: 5, scale: 1
    t.decimal "object_distance_m", precision: 6, scale: 1
    t.jsonb "view_model"
    t.boolean "claude_enabled", default: false, null: false
    t.datetime "claude_enabled_changed_at"
    t.text "manual_summary"
    t.datetime "manual_summary_updated_at"
    t.index ["analysis_status"], name: "index_inspections_on_analysis_status"
    t.index ["conducted_at"], name: "index_inspections_on_conducted_at"
    t.index ["severity"], name: "index_inspections_on_severity"
    t.index ["site_id"], name: "index_inspections_on_site_id"
  end

  create_table "panel_candidates", force: :cascade do |t|
    t.bigint "inspection_id", null: false
    t.bigint "panel_id", null: false
    t.string "kind", null: false
    t.jsonb "location"
    t.string "anomaly_type", null: false
    t.bigint "representative_anomaly_id"
    t.integer "observed_count", default: 0, null: false
    t.integer "visible_count", default: 0, null: false
    t.jsonb "flags", default: [], null: false
    t.jsonb "observations", default: [], null: false
    t.string "review_status", default: "pending", null: false
    t.boolean "locked", default: false, null: false
    t.string "rejection_reason"
    t.text "reviewer_note"
    t.datetime "reviewed_at"
    t.string "config_version"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["inspection_id"], name: "index_panel_candidates_on_inspection_id"
    t.index ["panel_id"], name: "index_panel_candidates_on_panel_id"
    t.index ["representative_anomaly_id"], name: "index_panel_candidates_on_representative_anomaly_id"
  end

  create_table "panels", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "number", null: false
    t.integer "position_x", null: false
    t.integer "position_y", null: false
    t.string "status", default: "normal", null: false
    t.datetime "last_inspected_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "row_number"
    t.string "string_number"
    t.integer "position_in_string"
    t.decimal "gps_lat", precision: 10, scale: 7
    t.decimal "gps_lng", precision: 10, scale: 7
    t.string "layout_source", default: "auto", null: false
    t.string "pcs_number"
    t.bigint "pv_block_id"
    t.integer "block_row"
    t.integer "block_col"
    t.index ["pv_block_id"], name: "index_panels_on_pv_block_id"
    t.index ["site_id", "number"], name: "index_panels_on_site_id_and_number", unique: true
    t.index ["site_id"], name: "index_panels_on_site_id"
    t.index ["status"], name: "index_panels_on_status"
  end

  create_table "pv_blocks", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "label", null: false
    t.jsonb "corners_latlng", null: false
    t.jsonb "corners_local", null: false
    t.integer "rows", null: false
    t.integer "cols", null: false
    t.string "panel_orientation", default: "portrait", null: false
    t.decimal "facing_azimuth_deg", precision: 6, scale: 2, default: "180.0", null: false
    t.decimal "tilt_deg", precision: 5, scale: 2
    t.decimal "upper_elevation_m", precision: 8, scale: 3
    t.decimal "lower_elevation_m", precision: 8, scale: 3
    t.string "source", default: "drawing", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "label"], name: "index_pv_blocks_on_site_id_and_label", unique: true
    t.index ["site_id"], name: "index_pv_blocks_on_site_id"
  end

  create_table "revenues", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.integer "year", null: false
    t.integer "month", null: false
    t.decimal "amount_yen", precision: 12, default: "0"
    t.decimal "kwh", precision: 10, scale: 2, default: "0.0"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "year", "month"], name: "index_revenues_on_site_id_and_year_and_month", unique: true
    t.index ["site_id"], name: "index_revenues_on_site_id"
  end

  create_table "rule_sets", force: :cascade do |t|
    t.string "version", null: false
    t.boolean "active", default: false, null: false
    t.text "note"
    t.jsonb "detection_params", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "provisional", default: false, null: false
    t.index ["active"], name: "index_rule_sets_on_single_active", unique: true, where: "active"
    t.index ["version"], name: "index_rule_sets_on_version", unique: true
  end

  create_table "severity_rules", force: :cascade do |t|
    t.bigint "rule_set_id", null: false
    t.string "anomaly_type", null: false
    t.string "measure", null: false
    t.decimal "normalized_mild", precision: 6, scale: 2, null: false
    t.decimal "normalized_warning", precision: 6, scale: 2, null: false
    t.decimal "normalized_critical", precision: 6, scale: 2, null: false
    t.decimal "raw_mild", precision: 6, scale: 2, null: false
    t.decimal "raw_warning", precision: 6, scale: 2, null: false
    t.decimal "raw_critical", precision: 6, scale: 2, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["rule_set_id", "anomaly_type"], name: "index_severity_rules_on_rule_set_id_and_anomaly_type", unique: true
    t.index ["rule_set_id"], name: "index_severity_rules_on_rule_set_id"
  end

  create_table "sites", force: :cascade do |t|
    t.string "name", null: false
    t.string "location", null: false
    t.integer "panel_count", default: 0, null: false
    t.decimal "capacity_kw", precision: 8, scale: 2, default: "0.0"
    t.string "status", default: "active", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "module_model"
    t.integer "module_rated_w"
    t.string "cell_layout"
    t.integer "substring_count", default: 3, null: false
    t.jsonb "bypass_pattern"
    t.decimal "specific_yield_kwh_per_kw", precision: 8, scale: 1
    t.decimal "fit_price_yen_per_kwh", precision: 6, scale: 2
    t.decimal "geo_origin_lat", precision: 10, scale: 7
    t.decimal "geo_origin_lng", precision: 10, scale: 7
    t.index ["status"], name: "index_sites_on_status"
  end

  create_table "structure_positions", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.integer "block_row", null: false
    t.integer "block_col", null: false
    t.integer "u_bin", null: false
    t.integer "v_bin", null: false
    t.integer "bins", null: false
    t.text "note"
    t.bigint "source_inspection_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "block_row", "block_col", "u_bin", "v_bin", "bins"], name: "index_structure_positions_on_site_and_position", unique: true
    t.index ["site_id"], name: "index_structure_positions_on_site_id"
    t.index ["source_inspection_id"], name: "index_structure_positions_on_source_inspection_id"
  end

  create_table "weather_readings", force: :cascade do |t|
    t.bigint "inspection_id", null: false
    t.datetime "observed_at", null: false
    t.decimal "irradiance_w_m2", precision: 7, scale: 1
    t.string "irradiance_type"
    t.decimal "wind_speed_m_s", precision: 5, scale: 2
    t.decimal "air_temp_c", precision: 5, scale: 2
    t.decimal "humidity", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "cloud_cover_okta"
    t.index ["inspection_id", "observed_at"], name: "index_weather_readings_on_inspection_id_and_observed_at"
    t.index ["inspection_id"], name: "index_weather_readings_on_inspection_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "alerts", "anomalies"
  add_foreign_key "alerts", "anomaly_groups"
  add_foreign_key "alerts", "inspections"
  add_foreign_key "alerts", "panels"
  add_foreign_key "alerts", "sites"
  add_foreign_key "anomalies", "anomalies", column: "duplicate_of_id", on_delete: :nullify
  add_foreign_key "anomalies", "anomaly_groups"
  add_foreign_key "anomalies", "inspection_images"
  add_foreign_key "anomalies", "inspections"
  add_foreign_key "anomalies", "panel_candidates", on_delete: :nullify
  add_foreign_key "anomalies", "panels"
  add_foreign_key "anomalies", "rule_sets"
  add_foreign_key "anomaly_groups", "inspection_images"
  add_foreign_key "anomaly_groups", "inspections"
  add_foreign_key "anomaly_groups", "rule_sets"
  add_foreign_key "block_map_proposals", "inspections"
  add_foreign_key "block_map_proposals", "sites"
  add_foreign_key "block_row_findings", "inspections"
  add_foreign_key "block_row_findings", "pv_blocks"
  add_foreign_key "block_row_findings", "rule_sets"
  add_foreign_key "external_transmissions", "inspections"
  add_foreign_key "grid_templates", "inspections"
  add_foreign_key "inspection_images", "inspections"
  add_foreign_key "inspection_reports", "inspections"
  add_foreign_key "inspections", "sites"
  add_foreign_key "panel_candidates", "anomalies", column: "representative_anomaly_id", on_delete: :nullify
  add_foreign_key "panel_candidates", "inspections"
  add_foreign_key "panel_candidates", "panels"
  add_foreign_key "panels", "pv_blocks", on_delete: :nullify
  add_foreign_key "panels", "sites"
  add_foreign_key "pv_blocks", "sites"
  add_foreign_key "revenues", "sites"
  add_foreign_key "severity_rules", "rule_sets"
  add_foreign_key "structure_positions", "inspections", column: "source_inspection_id", on_delete: :nullify
  add_foreign_key "structure_positions", "sites"
  add_foreign_key "weather_readings", "inspections"
end
