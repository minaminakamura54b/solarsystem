# 既存パネルの status を normal に戻す（2026-09-27 ユーザー承認済み）。
# 現在の warning / error は、シードのランダム値と、Phase 1 で削除した「並び順による割り当て」の名残で、
# 点検結果の根拠がない。元の値は根拠がないため記録せず、down では戻さない。
class ResetPanelStatusesToNormal < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE panels SET status = 'normal' WHERE status IN ('warning', 'error')"
  end

  def down
    # 元の値に意味がないため、何もしない（ロールバックは可能だが status は戻らない）
  end
end
