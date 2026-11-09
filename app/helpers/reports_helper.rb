# 報告書の表示（版の固定コピーから描く）
module ReportsHelper
  SEVERITY_LABELS = ReportSnapshotBuilder::SEVERITY_LABELS
  BASIS_LABELS = { "normalized" => "正規化ΔT", "raw" => "生ΔT", "unknown" => "不明" }.freeze
  IRRADIANCE_LABELS = { "poa" => "POA（パネル面）", "ghi" => "GHI（水平面）", "none" => "なし" }.freeze
  QUALITY_LABELS = { "ok" => "合格", "warning" => "注意", "rejected" => "不合格", "unknown" => "未判定" }.freeze

  def report_severity(severity) = SEVERITY_LABELS.fetch(severity.to_s, "—")

  def report_type(type) = RuleSetsHelper::ANOMALY_TYPE_LABELS.fetch(type.to_s, type.to_s)

  def report_kw(value) = value.nil? ? "—" : "#{format('%.3f', value)} kW"

  def report_time(iso) = iso.present? ? Time.zone.parse(iso).in_time_zone(ImageQualityConfig.current.capture_time_zone).strftime("%Y/%m/%d %H:%M") : "—"

  # 画像の bbox の周りを CSS の背景で切り出す（原本は変えない）。frame: true で枠を重ねる（RGB には描かない）。
  # 切り出す範囲は PDF の派生画像と同じ（ReportImages.window）
  def report_crop(url, bbox, aspect:, width: 220, pad: 2.0, frame: true)
    return content_tag(:div, "画像なし", class: "crop empty", style: "width:#{width}px;height:#{width}px;") if url.nil? || bbox.nil?

    x1, y1, x2, y2 = bbox.values_at("x1", "y1", "x2", "y2").map(&:to_f)
    left, top, w, h = ReportImages.window(bbox, aspect:, pad:)
    height = (width * h / (w * aspect)).round
    pos_x = w >= 1 ? 0 : (left / (1 - w) * 100).round(3)
    pos_y = h >= 1 ? 0 : (top / (1 - h) * 100).round(3)
    style = "width:#{width}px;height:#{height}px;background-image:url('#{url}');background-size:#{(100 / w).round(3)}% #{(100 / h).round(3)}%;" \
            "background-position:#{pos_x}% #{pos_y}%;background-repeat:no-repeat;position:relative;"
    box = frame ? content_tag(:div, "", class: "crop-frame", style: "left:#{((x1 - left) / w * 100).round(2)}%;top:#{((y1 - top) / h * 100).round(2)}%;" \
                                                                     "width:#{((x2 - x1) / w * 100).round(2)}%;height:#{((y2 - y1) / h * 100).round(2)}%;") : "".html_safe
    content_tag(:div, box, class: "crop", style:)
  end

  # PDF のとき（@pdf_images）は、切り出した派生画像を埋め込む
  def pdf_crop(data_uri, width)
    data_uri ? image_tag(data_uri, width:, class: "crop", alt: "") : content_tag(:div, "画像なし", class: "crop empty", style: "width:#{width}px;height:#{width}px;")
  end

  def thermal_crop(images, ref, **opts)
    return pdf_crop(@pdf_images.thermal(ref, width: opts.fetch(:width, 220)), opts.fetch(:width, 220)) if @pdf_images

    image = images[ref&.dig("id")]
    return report_crop(nil, nil, aspect: 1, **opts) unless image&.displayable?

    report_crop(url_for(image.display_image), ref["bbox"], aspect: (image.width || 640).to_f / (image.height || 512), **opts)
  end

  def rgb_crop(images, ref, **opts)
    if @pdf_images
      uri = @pdf_images.rgb(ref, width: opts.fetch(:width, 220))
      return uri && pdf_crop(uri, opts.fetch(:width, 220))
    end

    image = images[ref&.dig("id")]
    return nil unless image&.rgb&.attached? && ref["rgb_bbox"]

    meta = image.rgb.blob.metadata
    aspect = meta["width"] && meta["height"] ? meta["width"].to_f / meta["height"] : 4.0 / 3
    report_crop(url_for(image.rgb), ref["rgb_bbox"], aspect:, pad: 4.0, frame: false, **opts)
  end

  # 全体の様子のサーモ画像（R4）。PDF では縮小した派生画像を埋め込む
  def overview_image(images, ref, width: 330)
    return pdf_crop(@pdf_images.overview(ref, width:), width) if @pdf_images

    image = images[ref&.dig("id")]
    return pdf_crop(nil, width) unless image&.displayable?

    image_tag(url_for(image.display_image), width:, class: "crop", alt: "")
  end

  # 顧客向けの判定の目安（R2）: 判定に使った版のうち新しいものの閾値（版名は出さない）。段の閾値は段を判定したときだけ
  def customer_criteria_rows(snapshot)
    rules = Array(snapshot.dig("criteria", "rules"))
    version = rules.map { |r| r["version"] }.compact.max
    rules.select { |r| r["version"] == version }
  end

  # 配置図（北が上）の点を SVG の座標に
  def report_map_frame(blocks)
    points = blocks.flat_map { |b| b["corners"] }
    e0, e1 = points.map(&:first).minmax
    n0, n1 = points.map(&:last).minmax
    pad = 5.0
    { width: (e1 - e0 + 2 * pad).round(2), height: (n1 - n0 + 2 * pad).round(2), to: ->(e, n) { "#{(e - e0 + pad).round(2)},#{(n1 - n + pad).round(2)}" } }
  end

  # 架台の 4 隅の中の、段 row・列 col（1 始まり）の四角形。rows・cols が nil なら段全体
  def report_cell(block, row, col = nil)
    c = block["corners"]
    lerp = ->(a, b, t) { [ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t ] }
    rows, cols = block["rows"].to_f, block["cols"].to_f
    u0, u1 = col ? [ (col - 1) / cols, col / cols ] : [ 0.0, 1.0 ]
    v0, v1 = [ (row - 1) / rows, row / rows ]
    at = ->(u, v) { lerp.(lerp.(c[0], c[1], u), lerp.(c[3], c[2], u), v) }
    [ at.(u0, v0), at.(u1, v0), at.(u1, v1), at.(u0, v1) ]
  end
end
