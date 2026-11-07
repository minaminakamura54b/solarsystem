# 登録した架台と画像の位置合わせの結果（状態・残差・補正量・設定の版。docs/LAYOUT_OVERLAY_DESIGN.md の B-3）
class AddAlignmentToInspectionImages < ActiveRecord::Migration[8.1]
  def change
    add_column :inspection_images, :alignment, :jsonb
  end
end
