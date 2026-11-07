# 画像の位置（撮影位置・高度・向き・RTK の状態）を、配置との位置合わせに使えるかの記録（docs/LAYOUT_OVERLAY_DESIGN.md の B-1）
class AddGeorefToInspectionImages < ActiveRecord::Migration[8.1]
  def change
    add_column :inspection_images, :georef, :jsonb
  end
end
