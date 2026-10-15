# 画像サイズで正規化した bbox（{"x1","y1","x2","y2"}、0〜1）の計算
module Bbox
  module_function

  def normalize(bbox)
    return nil unless bbox.respond_to?(:to_h)

    h = bbox.to_h.stringify_keys
    values = %w[x1 y1 x2 y2].map { |k| Float(h[k], exception: false) }
    return nil if values.any?(&:nil?)

    x1, y1, x2, y2 = values
    { "x1" => [ x1, x2 ].min.clamp(0.0, 1.0).round(6), "y1" => [ y1, y2 ].min.clamp(0.0, 1.0).round(6),
      "x2" => [ x1, x2 ].max.clamp(0.0, 1.0).round(6), "y2" => [ y1, y2 ].max.clamp(0.0, 1.0).round(6) }
  end

  # 重なり面積 ÷ 合わせた面積（Intersection over Union）
  def iou(a, b)
    a = normalize(a)
    b = normalize(b)
    return 0.0 unless a && b

    w = [ a["x2"], b["x2"] ].min - [ a["x1"], b["x1"] ].max
    h = [ a["y2"], b["y2"] ].min - [ a["y1"], b["y1"] ].max
    return 0.0 if w <= 0 || h <= 0

    inter = w * h
    union = area(a) + area(b) - inter
    union.positive? ? inter / union : 0.0
  end

  def area(b)
    (b["x2"] - b["x1"]) * (b["y2"] - b["y1"])
  end
end
