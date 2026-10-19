require "csv"

# 配置図から作った CSV で、発電所のパネルを実配置に置き換える（docs/IMPROVEMENT_PLAN.md Phase 5b。2026-10-19 ユーザー承認）。
# - CSV は発電所の配置の全体を表す（全部の置き換えだけ）。1 行でもエラーがあれば何も登録しない
# - 実配置どうしは、パネル番号が同じなら同じパネルとして更新する（id・状態・最終点検日時・異常・アラートの紐付けを残す）
# - 仮配置（layout_source auto）のパネルは、番号が同じでも引き継がない（番号の一致による機械的な紐付けをしない）
# - 消えるパネル（仮配置すべてと、CSV に無い実配置）に紐付いた異常は、紐付けを外し、元のパネル番号を履歴に残し、
#   割り当て直しの一覧に出す（付け替え方 A）。確定・重大度・locked は変えず、レビュー完了済みの点検も戻さない
# - 新しく登録するパネルは layout_source manual・状態 normal・最終点検日時なし（根拠のない値を入れない）
# - sites.panel_count を CSV の件数にする
class PanelLayoutImport
  # 列名（英語・日本語）。日本語の列名は全角英数字も受け付ける（NFKC で正規化して比べる）
  COLUMNS = {
    "panel_number" => %w[panel_number パネル番号],
    "position_x" => %w[position_x X位置],
    "position_y" => %w[position_y Y位置],
    "row_number" => %w[row_number 列番号],
    "string_number" => %w[string_number ストリング番号],
    "position_in_string" => %w[position_in_string ストリング内位置],
    "pcs_number" => %w[pcs_number パワコン番号],
    "gps_lat" => %w[gps_lat 緯度],
    "gps_lng" => %w[gps_lng 経度]
  }.freeze
  REQUIRED = %w[panel_number position_x position_y].freeze
  MAX_ROWS = 20_000
  MAX_BYTES = 5.megabytes
  MAX_ERRORS = 50 # 画面に出すエラーの上限

  Error = Class.new(StandardError)
  StalePlan = Class.new(Error)

  Plan = Data.define(:creates, :updates, :deletes, :anomalies) do
    def placeholder_deletes = deletes.count(&:placeholder_layout?)
    def manual_deletes = deletes.count { |p| !p.placeholder_layout? }
    def reassignment_anomalies = anomalies.reject { |a| a.review_status == "rejected" }

    def anomalies_from(layout_source)
      ids = deletes.select { |p| p.layout_source == layout_source }.map(&:id)
      anomalies.select { |a| ids.include?(a.panel_id) }
    end

    # プレビューの後にデータが変わっていないかを確かめるための要約値
    def digest
      Digest::SHA256.hexdigest([ creates.map { |r| r["panel_number"] }, updates.map { |p, _| [ p.id, p.updated_at.to_f ] },
                                 deletes.map { |p| [ p.id, p.updated_at.to_f ] }, anomalies.map { |a| [ a.id, a.panel_id ] } ].to_json)
    end
  end

  attr_reader :rows, :errors

  # アップロードされたバイト列を UTF-8 の文字列にする（UTF-8（BOM 可）か Shift_JIS）。読めなければ Error
  def self.decode(bytes)
    raise Error, "CSV ファイルが大きすぎます（#{MAX_BYTES / 1.megabyte}MB まで）" if bytes.bytesize > MAX_BYTES

    utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
    return utf8.delete_prefix("﻿") if utf8.valid_encoding?

    sjis = bytes.dup.force_encoding(Encoding::Windows_31J)
    raise Error, "CSV の文字コードを読めませんでした（UTF-8 か Shift_JIS で保存してください）" unless sjis.valid_encoding?

    sjis.encode(Encoding::UTF_8)
  end

  def self.template_csv
    CSV.generate do |csv|
      csv << COLUMNS.keys
      csv << [ "A-01-01", 0, 0, "A", "S01", 1, "PCS1", nil, nil ]
      csv << [ "A-01-02", 1, 0, "A", "S01", 2, "PCS1", nil, nil ]
    end
  end

  def initialize(site, text, now: Time.current)
    @site = site
    @now = now
    @errors = []
    @text = utf8_text(text.to_s)
    @rows = @text ? parse : []
  end

  def valid?
    errors.empty?
  end

  def plan
    raise Error, "CSV にエラーがあります" unless valid?

    current = Panel.where(site_id: @site.id).to_a # 常に最新の状態で比べる
    manual = current.reject(&:placeholder_layout?).index_by(&:number)
    updates = []
    creates = []
    rows.each do |row|
      panel = manual[row["panel_number"]]
      panel ? updates << [ panel, row ] : creates << row
    end
    kept = updates.map { |panel, _| panel.id }
    deletes = current.reject { |p| kept.include?(p.id) }
    anomalies = Anomaly.where(panel_id: deletes.map(&:id)).order(:id).to_a
    Plan.new(creates:, updates:, deletes:, anomalies:)
  end

  # 置き換える。expected_digest（プレビューのときの要約値）と今のデータが違えば StalePlan
  def apply!(expected_digest:)
    ActiveRecord::Base.transaction do
      @site.lock! # 同じ発電所の置き換えを同時に行わない
      current = plan
      raise StalePlan, "確認画面を表示した後に、パネルか異常の紐付けが変わりました。内容を確認して、もう一度確定してください" if current.digest != expected_digest

      unassign(current)
      delete_ids = current.deletes.map(&:id)
      Alert.where(panel_id: delete_ids).update_all(panel_id: nil, updated_at: @now) # アラートの本文は残し、パネルの紐付けだけ外す
      Panel.where(id: delete_ids).delete_all
      current.updates.each { |panel, row| panel.update!(panel_attributes(row)) }
      if current.creates.any?
        Panel.insert_all!(current.creates.map { |row| panel_attributes(row).merge("site_id" => @site.id, "status" => "normal") })
      end
      @site.update!(panel_count: rows.size)
      current
    end
  end

  private

  # CSV の行 → Panel の属性（パネル番号の列は number）。CSV に無い任意の項目は空にする（CSV が配置の全体のため）
  def panel_attributes(row)
    row.except("panel_number").merge("number" => row["panel_number"], "layout_source" => "manual")
  end

  def utf8_text(text)
    return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

    self.class.decode(text.b)
  rescue Error => e
    add_error(e.message)
    nil
  end

  def unassign(plan)
    numbers = plan.deletes.index_by(&:id)
    plan.anomalies.each do |anomaly|
      panel = numbers.fetch(anomaly.panel_id)
      entry = { "panel_number" => panel.number, "layout_source" => panel.layout_source,
                "unassigned_at" => @now.iso8601, "reason" => "layout_replaced" }
      anomaly.update_columns(
        panel_id: nil, panel_assignment_history: anomaly.panel_assignment_history + [ entry ],
        # 却下した異常はパネルの割り当てが要らないので、割り当て直しの一覧には出さない（履歴は残す）
        panel_reassignment_required: anomaly.review_status == "rejected" ? anomaly.panel_reassignment_required : true,
        updated_at: @now
      )
    end
  end

  def parse
    table = CSV.parse(@text, headers: true, skip_blanks: true)
    columns = map_headers(table.headers)
    return [] unless columns

    rows = []
    table.each.with_index(2) do |record, line|
      next if record.fields.all?(&:blank?)

      if rows.size >= MAX_ROWS
        add_error("パネルは #{MAX_ROWS} 枚までです")
        break
      end
      row = parse_row(record, columns, line)
      rows << row if row
    end
    add_error("パネルの行がありません") if rows.empty? && errors.empty?
    check_duplicates(rows)
    errors.empty? ? rows.map { |r| r.except("line") } : []
  rescue CSV::MalformedCSVError => e
    add_error("CSV の形式が正しくありません（#{e.message}）")
    []
  end

  # 列名 → 項目。足りない列・知らない列・同じ項目の重複はエラー
  def map_headers(headers)
    lookup = COLUMNS.flat_map { |key, names| names.map { |n| [ normalize_header(n), key ] } }.to_h
    columns = {}
    headers.each_with_index do |header, index|
      next if header.blank? # Excel が付ける空の列

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

  def normalize_header(name)
    name.to_s.unicode_normalize(:nfkc).strip.downcase
  end

  def parse_row(record, columns, line)
    values = columns.to_h { |index, key| [ key, record.fields[index].to_s.unicode_normalize(:nfkc).strip.presence ] }
    row_errors = []
    row = { "line" => line }
    row_errors << "パネル番号が空です" if values["panel_number"].nil?
    row["panel_number"] = values["panel_number"]
    row_errors << "パネル番号は 50 文字までです" if values["panel_number"].to_s.length > 50
    %w[position_x position_y].each do |key|
      row[key] = integer(values[key], min: 0)
      row_errors << "#{COLUMNS[key].join(' / ')} は 0 以上の整数にしてください" if row[key].nil?
    end
    %w[row_number string_number pcs_number].each { |key| row[key] = values[key] }
    if values["position_in_string"]
      row["position_in_string"] = integer(values["position_in_string"], min: 1)
      row_errors << "ストリング内位置は 1 以上の整数にしてください" if row["position_in_string"].nil?
    end
    { "gps_lat" => 90, "gps_lng" => 180 }.each do |key, limit|
      next if values[key].nil?

      value = Float(values[key], exception: false)
      if value && value.abs <= limit
        row[key] = value
      else
        row_errors << "#{COLUMNS[key].join(' / ')} が正しくありません"
      end
    end
    row_errors.each { |message| add_error("#{line} 行目: #{message}") }
    row_errors.empty? ? COLUMNS.keys.to_h { |k| [ k, row[k] ] }.merge("line" => line) : nil
  end

  def integer(value, min:)
    number = Integer(value.to_s, 10, exception: false)
    number if number && number >= min
  end

  def check_duplicates(rows)
    rows.group_by { |r| r["panel_number"] }.each do |number, list|
      add_error("パネル番号「#{number}」が重複しています（#{list.map { |r| "#{r['line']} 行目" }.join('、')}）") if list.size > 1
    end
    rows.group_by { |r| [ r["position_x"], r["position_y"] ] }.each do |(x, y), list|
      add_error("位置（#{x}, #{y}）が重複しています（#{list.map { |r| "#{r['line']} 行目" }.join('、')}）") if list.size > 1
    end
  end

  def add_error(message)
    errors << message if errors.size < MAX_ERRORS
  end
end
