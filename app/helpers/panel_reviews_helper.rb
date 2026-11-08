module PanelReviewsHelper
  THUMB_W = 72

  # 画像の中のパネルの周りを切り出して見せる（CSS の背景で切り出す。原本は変えない）
  def panel_thumb_style(image, bbox, pad: 0.6)
    return nil unless image&.displayable? && bbox

    x1, y1, x2, y2 = bbox.values_at("x1", "y1", "x2", "y2").map(&:to_f)
    w = [ (x2 - x1) * (1 + pad), 0.02 ].max.clamp(0.02, 1.0)
    h = [ (y2 - y1) * (1 + pad), 0.02 ].max.clamp(0.02, 1.0)
    left = ((x1 + x2) / 2 - w / 2).clamp(0.0, 1.0 - w)
    top = ((y1 + y2) / 2 - h / 2).clamp(0.0, 1.0 - h)
    height = (THUMB_W * (h * (image.height || 512)) / (w * (image.width || 640))).round.clamp(24, 120)
    pos_x = w >= 1 ? 0 : (left / (1 - w) * 100).round(2)
    pos_y = h >= 1 ? 0 : (top / (1 - h) * 100).round(2)
    "width:#{THUMB_W}px; height:#{height}px; background-image:url('#{url_for(image.display_image)}'); " \
      "background-size:#{(100 / w).round(2)}% #{(100 / h).round(2)}%; background-position:#{pos_x}% #{pos_y}%; background-repeat:no-repeat;"
  end
end
