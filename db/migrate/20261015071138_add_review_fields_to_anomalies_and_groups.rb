# レビュー（Phase 5）で人が入力する項目。既存の値は変更しない
class AddReviewFieldsToAnomaliesAndGroups < ActiveRecord::Migration[8.1]
  def change
    change_table :anomalies, bulk: true do |t|
      # レビューで人が選んだ原因候補（cause_candidates は Phase 6 の Claude の出力用なので分ける）
      t.jsonb :selected_causes, null: false, default: []
      t.string :rejection_reason # glare / shadow / soiling / other
    end

    change_table :anomaly_groups, bulk: true do |t|
      t.datetime :reviewed_at
      t.text :reviewer_note
      t.string :rejection_reason
    end
  end
end
