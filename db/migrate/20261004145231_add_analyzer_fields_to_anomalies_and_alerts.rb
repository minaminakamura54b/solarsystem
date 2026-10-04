# 解析エンジンの出力（schema_version 2.1）を保存するための列と、アラートと異常・群の紐付け（Phase 4）。
# 既存の値は変更しない
class AddAnalyzerFieldsToAnomaliesAndAlerts < ActiveRecord::Migration[8.1]
  def change
    change_table :anomalies, bulk: true do |t|
      t.string :detection # local = 局所的な判定 / baseline = 基準温度からの判定
      t.integer :active_bands # substring_bypass で作動した帯の本数（Phase 7 の損失計算で使う）
    end

    # 確定した critical の異常・群ごとに1件だけアラートを作る（重複防止のための紐付け）
    add_reference :alerts, :anomaly, foreign_key: true
    add_reference :alerts, :anomaly_group, foreign_key: true
  end
end
