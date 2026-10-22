# 測定パラメータの受け皿（2026-10-22 ユーザー指示。DJI Thermal SDK への渡し方は Phase S で確定）。列の追加のみ
# - inspections: 点検ごとに入力する放射率・反射温度・距離（任意。未入力なら渡さない）
# - inspection_images.measurement_params: 解析のときに解析エンジンへ渡した値と、その出どころ（報告書・再解析の要否に使う）
class AddMeasurementParams < ActiveRecord::Migration[8.1]
  def change
    change_table :inspections, bulk: true do |t|
      t.decimal :emissivity, precision: 4, scale: 3
      t.decimal :reflected_temperature_c, precision: 5, scale: 1
      t.decimal :object_distance_m, precision: 6, scale: 1
    end
    add_column :inspection_images, :measurement_params, :jsonb
  end
end
