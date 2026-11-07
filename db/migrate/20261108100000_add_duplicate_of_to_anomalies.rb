# 「他の画像と重複」で却下した異常のまとめ先（同じ点検の別の画像の異常）。学習データで、まとめ先の最終判断に合わせるため（2026-11-07 ユーザー承認）
class AddDuplicateOfToAnomalies < ActiveRecord::Migration[8.1]
  def change
    add_reference :anomalies, :duplicate_of, foreign_key: { to_table: :anomalies, on_delete: :nullify }
  end
end
