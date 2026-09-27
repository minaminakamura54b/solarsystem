# 解析に失敗した点検が severity = "normal"（正常）として残らないようにする。
# - severity の NOT NULL とデフォルト "normal" を外す（NULL =「判定なし」）
# - 失敗理由を保存する error_message を追加する
# - 既存の failed の点検は severity を NULL にする
class MakeInspectionSeverityNullable < ActiveRecord::Migration[8.1]
  def up
    change_column_null :inspections, :severity, true
    change_column_default :inspections, :severity, from: "normal", to: nil
    add_column :inspections, :error_message, :text

    execute <<~SQL
      UPDATE inspections SET severity = NULL WHERE analysis_status = 'failed'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE inspections SET severity = 'normal' WHERE severity IS NULL
    SQL

    remove_column :inspections, :error_message
    change_column_default :inspections, :severity, from: nil, to: "normal"
    change_column_null :inspections, :severity, false
  end
end
