# 撮影条件の雲量（オクタ。0 = 雲なし 〜 8 = 全天が雲）の記録欄（2026-11-03 ユーザー指示）。列の追加のみ。
# 記録だけで、画像への割り当てと品質チェックへの反映は Phase S の後に行う
class AddCloudCoverToWeatherReadings < ActiveRecord::Migration[8.1]
  def change
    add_column :weather_readings, :cloud_cover_okta, :integer
  end
end
