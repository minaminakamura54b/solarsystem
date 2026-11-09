# 報告書の見直し R1（2026-11-09 ユーザー承認）。
# - 点検の対象範囲（対象の架台）: アプリの案を人が確定する。確定していなければ発電所全体として扱う
# - 報告書に載せる備考（今の「気象の備考」は社内メモとして報告書に載せない）
# - 発電所の既定の宛先（報告書の表紙。発行の画面で直せる）
class AddScopeAndReportFields < ActiveRecord::Migration[8.1]
  def change
    add_column :inspections, :scope_block_ids, :jsonb
    add_column :inspections, :scope_source, :string # proposal（案を確定）/ manual（人が選んだ）
    add_column :inspections, :scope_confirmed_at, :datetime
    add_column :inspections, :report_remarks, :text
    add_column :sites, :client_name, :string
  end
end
