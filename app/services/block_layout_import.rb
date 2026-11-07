require "csv"

# 架台の CSV で、発電所の配置（架台とパネル）を登録・置き換える（docs/LAYOUT_OVERLAY_DESIGN.md の A。2026-11-07 ユーザー承認）。
# - 列: 架台ラベル（空欄なら自動）・段数・列数・4 隅の緯度経度（順不同）。任意でパネルの向き・パネルの向く方位・傾斜角・
#   上端と下端の標高・出どころ。書き出し用の「確認が必要」「観測の数」は取り込みでは使わない
# - 図面の座標から作った CSV も、画像から作った地図を書き出した CSV も同じ形
# - CSV は配置の全体（全部の置き換えだけ）。確認画面の後に確定。1 行でもエラーがあれば何も登録しない
# - パネルは架台から作る。番号は「架台ラベル-段-列」（段は上端から、列は列の始まり（東西の架台は西）から）。
#   パネルの置き換えは Phase 5b の PanelLayoutImport に任せる（同じ番号の実配置は更新、消えるパネルに付いた異常は
#   紐付けを外して割り当て直しの一覧へ。確定・重大度・locked は変えない）
# - 架台ラベルの自動付与: 列（架台の並び）を北から A, B, …、列の中を始まりから 01, 02, …
class BlockLayoutImport
  CORNERS = (1..4).flat_map { |i| [ "corner#{i}_lat", "corner#{i}_lng" ] }.freeze
  COLUMNS = {
    "block_label" => %w[block_label 架台ラベル],
    "rows" => %w[rows 段数],
    "cols" => %w[cols 列数],
    **(1..4).flat_map { |i| [ [ "corner#{i}_lat", [ "corner#{i}_lat", "隅#{i}緯度" ] ], [ "corner#{i}_lng", [ "corner#{i}_lng", "隅#{i}経度" ] ] ] }.to_h,
    "panel_orientation" => %w[panel_orientation パネルの向き],
    "facing_azimuth_deg" => %w[facing_azimuth_deg パネルの向く方位],
    "tilt_deg" => %w[tilt_deg 傾斜角],
    "upper_elevation_m" => %w[upper_elevation_m 上端の標高],
    "lower_elevation_m" => %w[lower_elevation_m 下端の標高],
    "source" => %w[source 出どころ],
    "low_confidence" => %w[low_confidence 確認が必要],
    "observations" => %w[observations 観測の数]
  }.freeze
  REQUIRED = %w[rows cols] + CORNERS
  MAX_BLOCKS = 5_000
  MAX_ERRORS = 50
  RIGHT_ANGLE_TOLERANCE_DEG = 15
  LENGTH_RANGE_M = (1.0..150.0)
  DEPTH_RANGE_M = (0.5..30.0)

  Error = Class.new(StandardError)
  StalePlan = PanelLayoutImport::StalePlan

  Block = Data.define(:line, :label, :rows, :cols, :corners_latlng, :corners_local, :along, :panel_orientation,
                      :facing_azimuth_deg, :tilt_deg, :upper_elevation_m, :lower_elevation_m, :source) do
    def center = corners_local.transpose.map { |v| v.sum / 4.0 }
    def length = Math.hypot(corners_local[1][0] - corners_local[0][0], corners_local[1][1] - corners_local[0][1])
    def depth = Math.hypot(corners_local[3][0] - corners_local[0][0], corners_local[3][1] - corners_local[0][1])

    # 段 row（1 = 上端）・列 col（1 = 始まり）のパネルの中心（東・北 m）
    def panel_center(row, col)
      s = (col - 0.5) / cols
      t = (row - 0.5) / rows
      us, ue, le, ls = corners_local
      top = [ us[0] + (ue[0] - us[0]) * s, us[1] + (ue[1] - us[1]) * s ]
      bottom = [ ls[0] + (le[0] - ls[0]) * s, ls[1] + (le[1] - ls[1]) * s ]
      [ top[0] + (bottom[0] - top[0]) * t, top[1] + (bottom[1] - top[1]) * t ]
    end
  end

  Plan = Data.define(:blocks, :panel_plan, :current_block_count) do
    def digest = Digest::SHA256.hexdigest([ panel_plan.digest, current_block_count ].to_json)
  end

  attr_reader :blocks, :errors, :frame

  def self.template_csv
    CSV.generate do |csv|
      csv << COLUMNS.keys.first(15)
      csv << [ "A01", 2, 10, 35.0000900, 139.0000000, 35.0000900, 139.0001270, 35.0000540, 139.0001270, 35.0000540, 139.0000000,
               "portrait", 180, nil, nil ]
    end
  end

  # 登録済みの架台を、取り込みと同じ形の CSV にする
  def self.export_csv(site)
    CSV.generate do |csv|
      csv << COLUMNS.keys.first(16)
      site.pv_blocks.order(:label).each do |b|
        csv << [ b.label, b.rows, b.cols, *b.corners_latlng.flatten.map { |v| format("%.8f", v) }, b.panel_orientation,
                 b.facing_azimuth_deg&.to_f, b.tilt_deg&.to_f, b.upper_elevation_m&.to_f, b.lower_elevation_m&.to_f, b.source ]
      end
    end
  end

  def initialize(site, text, now: Time.current)
    @site = site
    @now = now
    @errors = []
    text = utf8(text.to_s)
    records = text ? parse(text) : []
    @frame = origin_for(records)
    @blocks = errors.empty? ? build_blocks(records) : []
    check_overlaps if errors.empty?
    @blocks = [] unless errors.empty?
  end

  def valid? = errors.empty?

  def panel_rows
    @panel_rows ||= make_panel_rows
  end

  def plan
    raise Error, "CSV にエラーがあります" unless valid?

    Plan.new(blocks:, panel_plan: panel_import.plan, current_block_count: @site.pv_blocks.count)
  end

  def apply!(expected_digest:)
    ActiveRecord::Base.transaction do
      @site.lock!
      current = plan
      raise StalePlan, "確認画面を表示した後に、架台・パネルか異常の紐付けが変わりました。内容を確認して、もう一度確定してください" if current.digest != expected_digest

      @site.update!(geo_origin_lat: frame.lat0, geo_origin_lng: frame.lng0) if @site.geo_origin_lat.nil?
      old_ids = @site.pv_blocks.pluck(:id)
      # 同じラベルの新しい架台を先に入れるため、消す架台のラベルを一時的に変える（パネルを付け替えた後で消す）
      PvBlock.where(id: old_ids).update_all([ "label = ? || id::text", "~replaced~" ])
      inserted = PvBlock.insert_all!(blocks.map { |b| block_attributes(b) }, returning: %w[id label])
      ids = inserted.rows.to_h { |id, label| [ label, id ] }
      panel_rows.each { |row| row["pv_block_id"] = ids.fetch(row.delete("block_label")) }
      panel_import.apply!(expected_digest: current.panel_plan.digest)
      PvBlock.where(id: old_ids).delete_all
      current
    end
  end

  private

  def panel_import
    @panel_import ||= PanelLayoutImport.new(@site, rows: panel_rows, now: @now)
  end

  def block_attributes(b)
    {
      site_id: @site.id, label: b.label, rows: b.rows, cols: b.cols,
      corners_latlng: b.corners_latlng, corners_local: b.corners_local.map { |e, n| [ e.round(3), n.round(3) ] },
      panel_orientation: b.panel_orientation, facing_azimuth_deg: b.facing_azimuth_deg, tilt_deg: b.tilt_deg,
      upper_elevation_m: b.upper_elevation_m, lower_elevation_m: b.lower_elevation_m, source: b.source,
      created_at: @now, updated_at: @now
    }
  end

  # 架台 → パネルの行（PanelLayoutImport の行の形。block_label は架台の ID に置き換えてから登録する）
  def make_panel_rows
    rows_of_blocks.each_with_index.flat_map do |line_blocks, line_index|
      max_rows = line_blocks.map(&:rows).max
      x = 0
      line_blocks.flat_map do |b|
        cells = (1..b.rows).flat_map do |r|
          (1..b.cols).map do |c|
            lat, lng = frame.to_latlng(*b.panel_center(r, c))
            {
              "panel_number" => panel_number(b, r, c), "position_x" => x + c - 1, "position_y" => line_index * max_rows + r - 1,
              "row_number" => row_letter(line_index), "string_number" => nil, "position_in_string" => nil, "pcs_number" => nil,
              "gps_lat" => lat.round(7), "gps_lng" => lng.round(7), "block_row" => r, "block_col" => c, "block_label" => b.label
            }
          end
        end
        x += b.cols
        cells
      end
    end
  end

  def panel_number(block, row, col)
    width = block.cols >= 100 ? 3 : 2
    "#{block.label}-#{row}-#{col.to_s.rjust(width, '0')}"
  end

  # 架台を列（並び）ごとにまとめる。列に直交する向きの位置が、架台の奥行きの半分以内なら同じ列。北の列から、列の中は始まりから
  def rows_of_blocks
    return [] if blocks.empty?

    along = mean_direction(blocks.map(&:along))
    across = [ -along[1], along[0] ]
    sorted = blocks.sort_by { |b| -dot(b.center, across) }
    depth = median(blocks.map(&:depth))
    lines = []
    sorted.each do |b|
      if lines.any? && (dot(lines.last.first.center, across) - dot(b.center, across)).abs <= depth / 2
        lines.last << b
      else
        lines << [ b ]
      end
    end
    lines.map { |line| line.sort_by { |b| dot(b.center, along) } }
  end

  def row_letter(index)
    letters = +""
    n = index
    loop do
      letters.prepend(("A".ord + n % 26).chr)
      n = n / 26 - 1
      break if n.negative?
    end
    letters
  end

  def assign_labels(built)
    @blocks = built
    taken = built.map(&:label).compact
    rows_of_blocks.each_with_index.map do |line, li|
      line.each_with_index.map do |b, bi|
        next b if b.label

        label = "#{row_letter(li)}#{(bi + 1).to_s.rjust(2, '0')}"
        add_error("#{b.line} 行目: 自動で付ける架台ラベル「#{label}」が、CSV の別の架台ラベルと重なります") if taken.include?(label)
        b.with(label:)
      end
    end.flatten
  end

  def build_blocks(records)
    built = records.filter_map { |r| build_block(r) }
    return [] unless errors.empty?

    built = assign_labels(built)
    built.group_by(&:label).each do |label, list|
      add_error("架台ラベル「#{label}」が重複しています（#{list.map { |b| "#{b.line} 行目" }.join('、')}）") if list.size > 1
    end
    built
  end

  def build_block(r)
    local = r[:corners].map { |lat, lng| frame.to_local(lat, lng) }
    center = local.transpose.map { |v| v.sum / 4.0 }
    order = (0..3).sort_by { |i| Math.atan2(local[i][1] - center[1], local[i][0] - center[0]) }
    quad = order.map { |i| local[i] }
    unless convex?(quad)
      add_error("#{r[:line]} 行目: 4 隅が四角形になっていません（隅の重複・ねじれ）")
      return nil
    end
    sides = (0..3).map { |i| [ quad[(i + 1) % 4][0] - quad[i][0], quad[(i + 1) % 4][1] - quad[i][1] ] }
    angles = (0..3).map { |i| angle_between(sides[i - 1].map(&:-@), sides[i]) }
    if angles.any? { |a| (a - 90).abs > RIGHT_ANGLE_TOLERANCE_DEG }
      add_error("#{r[:line]} 行目: 4 隅が長方形になっていません（角が 90° ± #{RIGHT_ANGLE_TOLERANCE_DEG}° を外れています）")
      return nil
    end
    long = norm(sides[0]) + norm(sides[2]) >= norm(sides[1]) + norm(sides[3]) ? 0 : 1
    a = sides[long]
    b = sides[long + 2].map(&:-@)
    along = normalize([ a[0] + b[0], a[1] + b[1] ])
    along = along.map(&:-@) if along[0] < -1e-9 || (along[0].abs <= 1e-9 && along[1].negative?) # 東向き（南北なら北向き）
    across = [ -along[1], along[0] ]
    f = r[:facing] * Math::PI / 180
    upper_sign = (Math.sin(f) * across[0] + Math.cos(f) * across[1]).negative? ? 1 : -1
    rel = ->(i) { [ local[i][0] - center[0], local[i][1] - center[1] ] }
    upper, lower = (0..3).partition { |i| dot(rel.(i), across) * upper_sign > 0 }
    unless upper.size == 2 && lower.size == 2
      add_error("#{r[:line]} 行目: 上端と下端を決められません（パネルの向く方位と架台の向きを確かめてください）")
      return nil
    end
    us, ue = upper.sort_by { |i| dot(rel.(i), along) }
    ls, le = lower.sort_by { |i| dot(rel.(i), along) }
    idx = [ us, ue, le, ls ]
    block = Block.new(
      line: r[:line], label: r[:label], rows: r[:rows], cols: r[:cols],
      corners_latlng: idx.map { |i| r[:corners][i] }, corners_local: idx.map { |i| local[i] }, along:,
      panel_orientation: r[:panel_orientation], facing_azimuth_deg: r[:facing], tilt_deg: r[:tilt],
      upper_elevation_m: r[:upper_elevation], lower_elevation_m: r[:lower_elevation], source: r[:source]
    )
    unless LENGTH_RANGE_M.cover?(block.length) && DEPTH_RANGE_M.cover?(block.depth)
      add_error("#{r[:line]} 行目: 架台の大きさが範囲外です（長さ #{block.length.round(1)} m・奥行き #{block.depth.round(1)} m）")
      return nil
    end
    block
  end

  # 架台どうしが重なっていないか（凸四角形の分離軸の判定。0.1 m までの接触は許す）
  def check_overlaps
    blocks.combination(2).each do |a, b|
      next if Math.hypot(*a.center.zip(b.center).map { |x, y| x - y }) > (a.length + b.length) / 2 + 1
      next unless overlap?(a.corners_local, b.corners_local)

      add_error("#{a.line} 行目の架台「#{a.label}」と #{b.line} 行目の架台「#{b.label}」が重なっています")
    end
  end

  def overlap?(p, q)
    [ p, q ].each do |poly|
      4.times do |i|
        e = [ poly[(i + 1) % 4][0] - poly[i][0], poly[(i + 1) % 4][1] - poly[i][1] ]
        axis = normalize([ -e[1], e[0] ])
        pa = p.map { |v| dot(v, axis) }
        qa = q.map { |v| dot(v, axis) }
        return false if pa.max <= qa.min + 0.1 || qa.max <= pa.min + 0.1
      end
    end
    true
  end

  def origin_for(records)
    return GeoFrame.new(@site.geo_origin_lat, @site.geo_origin_lng) if @site.geo_origin_lat && @site.geo_origin_lng

    corners = records.flat_map { |r| r[:corners] }
    return GeoFrame.new(0, 0) if corners.empty?

    GeoFrame.new(corners.map(&:first).min, corners.map(&:last).min)
  end

  def parse(text)
    table = CSV.parse(text, headers: true, skip_blanks: true)
    columns = map_headers(table.headers)
    return [] unless columns

    records = []
    table.each.with_index(2) do |record, line|
      next if record.fields.all?(&:blank?)

      if records.size >= MAX_BLOCKS
        add_error("架台は #{MAX_BLOCKS} 個までです")
        break
      end
      values = columns.to_h { |index, key| [ key, record.fields[index].to_s.unicode_normalize(:nfkc).strip.presence ] }
      parsed = parse_record(values, line)
      records << parsed if parsed
    end
    add_error("架台の行がありません") if records.empty? && errors.empty?
    records
  rescue CSV::MalformedCSVError => e
    add_error("CSV の形式が正しくありません（#{e.message}）")
    []
  end

  def parse_record(v, line)
    errs = []
    label = v["block_label"]
    errs << "架台ラベルは 20 文字までです" if label.to_s.length > 20
    errs << "架台ラベルに「-」は使えません（パネル番号の区切りに使うため）" if label.to_s.include?("-")
    rows = Integer(v["rows"].to_s, 10, exception: false)
    cols = Integer(v["cols"].to_s, 10, exception: false)
    errs << "段数は 1〜50 の整数にしてください" unless rows&.between?(1, 50)
    errs << "列数は 1〜200 の整数にしてください" unless cols&.between?(1, 200)
    corners = (1..4).map do |i|
      lat = Float(v["corner#{i}_lat"].to_s, exception: false)
      lng = Float(v["corner#{i}_lng"].to_s, exception: false)
      errs << "隅#{i} の緯度・経度が正しくありません" unless lat&.between?(-90, 90) && lng&.between?(-180, 180)
      [ lat, lng ]
    end
    orientation = v["panel_orientation"] || "portrait"
    errs << "パネルの向きは portrait か landscape にしてください" unless PvBlock::ORIENTATIONS.include?(orientation)
    facing = v["facing_azimuth_deg"] ? Float(v["facing_azimuth_deg"], exception: false) : 180.0
    errs << "パネルの向く方位は 0〜360 の数にしてください" unless facing&.between?(0, 360)
    optional = %w[tilt_deg upper_elevation_m lower_elevation_m].to_h do |key|
      value = v[key] && Float(v[key], exception: false)
      errs << "#{COLUMNS[key].last} が数ではありません" if v[key] && value.nil?
      [ key, value ]
    end
    errs << "傾斜角は 0〜90 にしてください" if optional["tilt_deg"] && !optional["tilt_deg"].between?(0, 90)
    source = v["source"] || "drawing"
    errs << "出どころは #{PvBlock::SOURCES.keys.join(' / ')} のどれかにしてください" unless PvBlock::SOURCES.key?(source)
    errs.each { |m| add_error("#{line} 行目: #{m}") }
    return nil if errs.any?

    { line:, label:, rows:, cols:, corners:, panel_orientation: orientation, facing:, tilt: optional["tilt_deg"],
      upper_elevation: optional["upper_elevation_m"], lower_elevation: optional["lower_elevation_m"], source: }
  end

  def map_headers(headers)
    lookup = COLUMNS.flat_map { |key, names| names.map { |n| [ normalize_header(n), key ] } }.to_h
    columns = {}
    headers.each_with_index do |header, index|
      next if header.blank?

      key = lookup[normalize_header(header)]
      if key.nil?
        add_error("知らない列名です: 「#{header}」")
      elsif columns.value?(key)
        add_error("同じ項目の列が複数あります: 「#{header}」")
      else
        columns[index] = key
      end
    end
    missing = REQUIRED - columns.values
    add_error("必須の列がありません: #{missing.map { |k| COLUMNS[k].join(' / ') }.join('、')}") if missing.any?
    errors.empty? ? columns : nil
  end

  def normalize_header(name) = name.to_s.unicode_normalize(:nfkc).strip.downcase

  def utf8(text)
    return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

    PanelLayoutImport.decode(text.b)
  rescue PanelLayoutImport::Error => e
    add_error(e.message)
    nil
  end

  def convex?(quad)
    signs = (0..3).map do |i|
      a, b, c = quad[i], quad[(i + 1) % 4], quad[(i + 2) % 4]
      (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
    end
    signs.all? { |s| s > 1e-6 } || signs.all? { |s| s < -1e-6 }
  end

  def angle_between(u, v)
    cos = dot(u, v) / (norm(u) * norm(v))
    Math.acos(cos.clamp(-1.0, 1.0)) * 180 / Math::PI
  end

  def mean_direction(vectors)
    sx = vectors.sum { |x, y| Math.cos(2 * Math.atan2(y, x)) }
    sy = vectors.sum { |x, y| Math.sin(2 * Math.atan2(y, x)) }
    t = Math.atan2(sy, sx) / 2
    [ Math.cos(t), Math.sin(t) ]
  end

  def dot(u, v) = u[0] * v[0] + u[1] * v[1]
  def norm(u) = Math.hypot(u[0], u[1])
  def normalize(u) = u.map { |x| x / norm(u) }
  def median(values) = values.sort[values.size / 2]

  def add_error(message)
    errors << message if errors.size < MAX_ERRORS
  end
end
