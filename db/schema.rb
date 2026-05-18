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

ActiveRecord::Schema[8.1].define(version: 2026_05_18_103516) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "alerts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "inspection_id"
    t.text "message"
    t.bigint "panel_id"
    t.datetime "read_at"
    t.string "severity", default: "info", null: false
    t.bigint "site_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_alerts_on_created_at"
    t.index ["inspection_id"], name: "index_alerts_on_inspection_id"
    t.index ["panel_id"], name: "index_alerts_on_panel_id"
    t.index ["read_at"], name: "index_alerts_on_read_at"
    t.index ["severity"], name: "index_alerts_on_severity"
    t.index ["site_id"], name: "index_alerts_on_site_id"
  end

  create_table "inspections", force: :cascade do |t|
    t.string "analysis_status", default: "pending", null: false
    t.json "anomalies", default: []
    t.integer "anomaly_count", default: 0
    t.datetime "conducted_at", null: false
    t.datetime "created_at", null: false
    t.text "report"
    t.text "result"
    t.string "severity", default: "normal", null: false
    t.bigint "site_id", null: false
    t.datetime "updated_at", null: false
    t.index ["analysis_status"], name: "index_inspections_on_analysis_status"
    t.index ["conducted_at"], name: "index_inspections_on_conducted_at"
    t.index ["severity"], name: "index_inspections_on_severity"
    t.index ["site_id"], name: "index_inspections_on_site_id"
  end

  create_table "panels", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_inspected_at"
    t.string "number", null: false
    t.integer "position_x", null: false
    t.integer "position_y", null: false
    t.bigint "site_id", null: false
    t.string "status", default: "normal", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "number"], name: "index_panels_on_site_id_and_number", unique: true
    t.index ["site_id"], name: "index_panels_on_site_id"
    t.index ["status"], name: "index_panels_on_status"
  end

  create_table "revenues", force: :cascade do |t|
    t.decimal "amount_yen", precision: 12, default: "0"
    t.datetime "created_at", null: false
    t.decimal "kwh", precision: 10, scale: 2, default: "0.0"
    t.integer "month", null: false
    t.bigint "site_id", null: false
    t.datetime "updated_at", null: false
    t.integer "year", null: false
    t.index ["site_id", "year", "month"], name: "index_revenues_on_site_id_and_year_and_month", unique: true
    t.index ["site_id"], name: "index_revenues_on_site_id"
  end

  create_table "sites", force: :cascade do |t|
    t.decimal "capacity_kw", precision: 8, scale: 2, default: "0.0"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "location", null: false
    t.string "name", null: false
    t.integer "panel_count", default: 0, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_sites_on_status"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "alerts", "inspections"
  add_foreign_key "alerts", "panels"
  add_foreign_key "alerts", "sites"
  add_foreign_key "inspections", "sites"
  add_foreign_key "panels", "sites"
  add_foreign_key "revenues", "sites"
end
