# 1つの点検（セッション）に複数の画像を紐付ける（docs/IMPROVEMENT_PLAN.md 4.1）
class CreateInspectionImages < ActiveRecord::Migration[8.1]
  def change
    create_table :inspection_images do |t|
      t.references :inspection, null: false, foreign_key: true
      t.integer :sequence, null: false
      t.string :thermal_filename
      t.datetime :captured_at
      t.string :camera_model
      t.boolean :is_radiometric # メタデータによる仮判定。null = 判定できなかった
      t.integer :width
      t.integer :height
      t.decimal :gps_lat, precision: 10, scale: 7
      t.decimal :gps_lng, precision: 10, scale: 7
      t.decimal :altitude_m, precision: 8, scale: 2
      t.decimal :gimbal_pitch, precision: 6, scale: 2
      t.decimal :gimbal_yaw, precision: 6, scale: 2
      t.jsonb :metadata, null: false, default: {}
      t.decimal :irradiance_w_m2, precision: 7, scale: 1
      t.string :irradiance_type
      t.decimal :wind_speed_m_s, precision: 5, scale: 2
      t.decimal :air_temp_c, precision: 5, scale: 2
      t.decimal :humidity, precision: 5, scale: 2
      t.jsonb :quality_report
      t.string :analysis_status, null: false, default: "pending"
      t.string :review_reason
      t.text :exclusion_note
      t.jsonb :panel_grids, null: false, default: []
      t.jsonb :grid_proposal
      t.string :analyzer_version
      t.jsonb :raw_analysis
      t.text :error_message
      t.timestamps
    end
    add_index :inspection_images, [ :inspection_id, :sequence ], unique: true
    add_index :inspection_images, :analysis_status
  end
end
