# 点検ごとの気象データ（時刻付きで複数行）。画像の撮影時刻で補間して割り当てる
class CreateWeatherReadings < ActiveRecord::Migration[8.1]
  def change
    create_table :weather_readings do |t|
      t.references :inspection, null: false, foreign_key: true
      t.datetime :observed_at, null: false
      t.decimal :irradiance_w_m2, precision: 7, scale: 1
      t.string :irradiance_type
      t.decimal :wind_speed_m_s, precision: 5, scale: 2
      t.decimal :air_temp_c, precision: 5, scale: 2
      t.decimal :humidity, precision: 5, scale: 2
      t.timestamps
    end
    add_index :weather_readings, [ :inspection_id, :observed_at ]
  end
end
