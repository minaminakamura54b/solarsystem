# 報告書の PDF に埋め込む切り出し画像（派生画像）を作る（docs/IMPROVEMENT_PLAN.md Phase 7 の決定事項）。
# - 原本（R-JPEG・RGB）は変えない。読み込んで切り出し、縮小した JPEG を data URI にして HTML に埋め込む
#   （PDF を作る Chromium がネットワークから画像を取りに行かないようにする）
# - サーモは bbox の周りを切り出して白い枠を描く。RGB は広めに切り出し、枠は描かない（おおよその位置）
# - 画面の報告書は CSS の背景で切り出す（ReportsHelper#report_crop）。切り出す範囲の求め方は同じ（ReportImages.window）
class ReportImages
  # 切り出す範囲（0〜1 の正規化座標）。aspect = 画像の 横 / 縦。戻り値: [left, top, w, h]
  def self.window(bbox, aspect:, pad:)
    x1, y1, x2, y2 = bbox.values_at("x1", "y1", "x2", "y2").map(&:to_f)
    w = ((x2 - x1) * (1 + pad)).clamp(0.08, 1.0)
    h = (w * aspect).clamp(0.08, 1.0)
    left = ((x1 + x2) / 2 - w / 2).clamp(0.0, 1.0 - w)
    top = ((y1 + y2) / 2 - h / 2).clamp(0.0, 1.0 - h)
    [ left, top, w, h ]
  end

  def initialize(images)
    @images = images # id => InspectionImage
    @cache = {}
  end

  def thermal(ref, width:)
    image = @images[ref&.dig("id")]
    return nil unless image&.displayable? && ref["bbox"]

    crop(image.display_image, ref["bbox"], width:, pad: 2.0, frame: true, nearest: true)
  end

  def rgb(ref, width:)
    image = @images[ref&.dig("id")]
    return nil unless image&.rgb&.attached? && ref["rgb_bbox"]

    crop(image.rgb, ref["rgb_bbox"], width:, pad: 4.0, frame: false, nearest: false)
  end

  private

  def crop(attachment, bbox, width:, pad:, frame:, nearest:)
    source = load(attachment)
    left, top, w, h = self.class.window(bbox, aspect: source.width.to_f / source.height, pad:)
    x, y = (left * source.width).floor, (top * source.height).floor
    cw = [ (w * source.width).round, source.width - x ].min
    ch = [ (h * source.height).round, source.height - y ].min
    out = source.crop(x, y, cw, ch)
    scale = width.to_f / cw
    out = out.resize(scale, kernel: nearest ? :nearest : :lanczos3)
    out = draw_frame(out, bbox, x, y, scale, source) if frame
    out = out.extract_band(0, n: 3) if out.bands > 3
    "data:image/jpeg;base64,#{Base64.strict_encode64(out.jpegsave_buffer(Q: 85, strip: true))}"
  end

  def draw_frame(img, bbox, x0, y0, scale, source)
    fx = ((bbox["x1"].to_f * source.width - x0) * scale).round
    fy = ((bbox["y1"].to_f * source.height - y0) * scale).round
    fw = ((bbox["x2"].to_f - bbox["x1"].to_f) * source.width * scale).round.clamp(2, img.width)
    fh = ((bbox["y2"].to_f - bbox["y1"].to_f) * source.height * scale).round.clamp(2, img.height)
    img = img.colourspace(:srgb) if img.bands < 3
    white = [ 255 ] * img.bands
    img.draw_rect(white, fx, fy, fw, fh, fill: false).draw_rect(white, fx - 1, fy - 1, fw + 2, fh + 2, fill: false)
  end

  def load(attachment)
    @cache[attachment.blob.id] ||= Vips::Image.new_from_buffer(attachment.blob.download, "").autorot
  end
end
