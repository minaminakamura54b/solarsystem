# 既存テーブルの拡張（4.6 / 4.7）。既存の値は変更しない
class ExtendSitesPanelsInspectionsForPhase2 < ActiveRecord::Migration[8.1]
  def change
    change_table :sites, bulk: true do |t|
      t.string :module_model
      t.integer :module_rated_w
      t.string :cell_layout
      t.integer :substring_count, null: false, default: 3
      t.jsonb :bypass_pattern
      t.decimal :specific_yield_kwh_per_kw, precision: 8, scale: 1
      t.decimal :fit_price_yen_per_kwh, precision: 6, scale: 2
    end

    change_table :panels, bulk: true do |t|
      t.string :row_number
      t.string :string_number
      t.integer :position_in_string
      t.decimal :gps_lat, precision: 10, scale: 7
      t.decimal :gps_lng, precision: 10, scale: 7
      # auto = 発電所作成時に自動生成した仮配置（実配置ではない）/ manual = 実配置として登録したもの
      t.string :layout_source, null: false, default: "auto"
    end

    change_table :inspections, bulk: true do |t|
      t.string :review_reason
      t.text :weather_note
      t.datetime :reviewed_at
    end

    # 旧方式（Claude の画像判定）の結果。温度も bbox もないため新しい anomalies には移行せず、読み取り専用で残す
    rename_column :inspections, :anomalies, :legacy_anomalies
  end
end
