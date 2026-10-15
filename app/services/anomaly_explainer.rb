# 確定した異常・群の所見を Claude に書かせる（docs/IMPROVEMENT_PLAN.md Phase 6）。
# - 入力は保存済みの数値・種類などの構造化データだけ（画像は送らない。2026-10-15 ユーザー承認）
# - 確定済みの重大度は、ルールで確定した事実として入力に含める（v2。推奨対応の緊急度を重大度と整合させるため。ユーザー指示）
# - 出力は固定スキーマ（structured outputs）。severity や正常/異常の判断はスキーマに無く、返ってきても保存しない
# - 書き込むのは所見の列だけ。種類・重大度・状態・パネルなど、判定と人の確認の結果には触れない
# - 入力（と prompt_version）が前回と同じなら作り直さない（force: true の「所見を作り直す」は除く）
# - 失敗したらエラーを記録する。入力が変わっていた場合は、古い所見を消す（今のデータと合わない所見を残さない）
class AnomalyExplainer
  PROMPT_VERSION = "anomaly_explainer_v2".freeze
  PROMPT_PATH = Rails.root.join("app/prompts/#{PROMPT_VERSION}.txt")
  RESULT_KEYS = %w[cause_candidates reasoning additional_checks recommended_action report_text].freeze

  SCHEMA = {
    type: "object",
    properties: {
      cause_candidates: {
        type: "array",
        items: {
          type: "object",
          properties: { cause: { type: "string" }, basis: { type: "string" } },
          required: %w[cause basis],
          additionalProperties: false
        }
      },
      reasoning: { type: "string" },
      additional_checks: { type: "array", items: { type: "string" } },
      recommended_action: { type: "string" },
      report_text: { type: "string" }
    },
    required: RESULT_KEYS,
    additionalProperties: false
  }.freeze

  TYPE_NOTES = {
    "hotspot" => "セルの一部の局所的な発熱",
    "multi_hotspot" => "1 枚のパネルの中に複数の局所的な発熱",
    "substring_bypass" => "バイパスダイオードの作動を示す帯状の発熱",
    "module_wide" => "パネル全体が周囲より高温",
    "partial_module" => "部分的な発熱（モジュール型式の定義と一致しない、または構成不明）",
    "other" => "その他",
    "panel_row_group" => "画像内の同じ行で隣接するパネル群がまとめて高温。電気的なストリングとは限らない"
  }.freeze
  FLAG_LABELS = { "glare_suspect" => "グレア（反射）の疑い", "unnormalized" => "未正規化", "edge_adjacent" => "パネル端に接する" }.freeze
  CELL_LAYOUTS = { "full_cell" => "フルセル", "half_cut" => "ハーフカット", "other" => "その他" }.freeze
  SEVERITY_LABELS = { "mild" => "軽微", "warning" => "注意", "critical" => "重大" }.freeze
  SEVERITY_SCALE = "3 段階: 軽微 < 注意 < 重大".freeze
  EVIDENCE_LABELS = { "A" => "A（サーモ＋RGB＋電気測定）", "B" => "B（サーモ＋RGB）", "C" => "C（サーモのみ）" }.freeze

  Error = Class.new(StandardError)

  def initialize(output: ClaudeStructuredOutput.new, now: Time.current)
    @output = output
    @now = now
  end

  # 戻り値: :explained / :skipped / :failed
  def explain(record, force: false)
    raise ArgumentError, "確定していない異常の所見は作りません" unless InspectionReview::CONFIRMED.include?(record.review_status)

    input = input_text(record)
    digest = digest_for(input)
    return :skipped if !force && record.explanation_input_digest == digest && record.explained_at.present? && record.explanation_error.blank?

    result = @output.request(system: prompt, input: input, schema: SCHEMA)
    record.update_columns(**sanitize(result), prompt_version: PROMPT_VERSION, explanation_input_digest: digest,
                          explained_at: @now, explanation_error: nil, updated_at: @now)
    :explained
  rescue ClaudeStructuredOutput::Error, Error => e
    record_failure(record, digest, e.message)
    :failed
  end

  # 保存済みの所見が、今のデータから作ったものか（画面で「古い所見」を示すのに使う）
  def current?(record)
    record.explained_at.present? && record.explanation_input_digest == digest_for(input_text(record))
  end

  def input_text(record)
    lines = record.is_a?(AnomalyGroup) ? group_lines(record) : anomaly_lines(record)
    lines.compact.join("\n")
  end

  private

  def prompt
    @prompt ||= PROMPT_PATH.read
  end

  def digest_for(input)
    Digest::SHA256.hexdigest("#{PROMPT_VERSION}\n#{input}")
  end

  def record_failure(record, digest, message)
    attrs = { explanation_error: message, updated_at: @now }
    if digest && record.explanation_input_digest != digest
      attrs.merge!(cause_candidates: nil, explanation: nil, additional_checks: nil, recommended_action: nil,
                   report_text: nil, prompt_version: nil, explanation_input_digest: nil, explained_at: nil)
    end
    record.update_columns(attrs)
  end

  # スキーマにある項目だけを、決まった型にして保存する（severity などの余計な項目は捨てる）
  def sanitize(result)
    causes = Array(result["cause_candidates"]).filter_map do |c|
      next unless c.is_a?(Hash) && c["cause"].present?

      { "cause" => c["cause"].to_s, "basis" => c["basis"].to_s }
    end
    report_text = result["report_text"].to_s
    raise Error, "Claude の応答に所見文（report_text）がありません" if report_text.blank?

    {
      cause_candidates: causes.first(4),
      explanation: result["reasoning"].to_s,
      additional_checks: Array(result["additional_checks"]).map(&:to_s).reject(&:blank?),
      recommended_action: result["recommended_action"].to_s,
      report_text: report_text
    }
  end

  def anomaly_lines(anomaly)
    type = anomaly.effective_type
    bands = "、帯 #{anomaly.active_bands} 本" if anomaly.active_bands && type == "substring_bypass"
    [
      "種類: #{type}（#{RuleSetsHelper::ANOMALY_TYPE_LABELS.fetch(type, type)}#{bands}。#{TYPE_NOTES.fetch(type, '-')}）",
      ("人が修正する前の種類: #{anomaly.anomaly_type}" if anomaly.final_anomaly_type.present?),
      severity_line(anomaly.effective_severity),
      ("検出: レビューで人が追加した見逃し（温度の数値なし）" if anomaly.detection == "manual"),
      delta_line(anomaly),
      ("面積比: #{format_number(anomaly.area_ratio)}" if anomaly.area_ratio),
      irradiance_line(anomaly.inspection_image),
      module_line(anomaly.inspection.site),
      "証拠レベル: #{EVIDENCE_LABELS.fetch(anomaly.evidence_level.to_s, 'なし')}",
      ("電気測定: #{AnomalyReview::ELECTRICAL_METHODS.fetch(anomaly.electrical_evidence['method'], '-')} — #{anomaly.electrical_evidence['result']}" if anomaly.electrical_evidence.present?),
      "人が選んだ原因候補: #{cause_labels(anomaly.selected_causes).presence || 'なし'}",
      "パネル: #{anomaly.panel&.number || '未割り当て'}",
      "フラグ: #{Array(anomaly.flags).map { |f| FLAG_LABELS.fetch(f, f) }.join('、').presence || 'なし'}"
    ]
  end

  def group_lines(group)
    members = group.anomalies.to_a
    [
      "種類: #{group.group_type}（#{RuleSetsHelper::ANOMALY_TYPE_LABELS.fetch(group.group_type, group.group_type)}。#{TYPE_NOTES.fetch(group.group_type, '-')}）",
      "パネル数: #{group.panel_count}",
      severity_line(group.severity),
      delta_line(group, note: "構成パネルの中央値"),
      irradiance_line(group.inspection_image),
      module_line(group.inspection.site),
      "証拠レベル: #{EVIDENCE_LABELS.fetch(weakest_evidence(members).to_s, 'なし')}（構成パネルのうち最も弱いもの）",
      "人が選んだ原因候補: #{cause_labels(members.flat_map(&:selected_causes).uniq).presence || 'なし'}",
      "パネル: #{members.filter_map { |m| m.panel&.number }.uniq.join('、').presence || '未割り当て'}",
      "フラグ: #{members.flat_map { |m| Array(m.flags) }.uniq.map { |f| FLAG_LABELS.fetch(f, f) }.join('、').presence || 'なし'}"
    ]
  end

  def severity_line(severity)
    "重大度（ルールで確定・人が確認済み。変更しない）: #{SEVERITY_LABELS.fetch(severity.to_s, '不明')}（#{SEVERITY_SCALE}）"
  end

  def delta_line(record, note: nil)
    return nil if record.delta_t.nil?

    measure = RuleSetsHelper::MEASURE_LABELS.fetch(record.measure.to_s, record.measure.to_s)
    line = "ΔT: #{format_number(record.delta_t)}℃（#{[ measure, note ].compact.join('・')} − 基準温度）"
    if record.threshold_basis == "normalized" && record.normalized_delta_t
      "#{line} / 正規化ΔT: #{format_number(record.normalized_delta_t)}℃"
    else
      "#{line} / 正規化ΔT: なし（未正規化）"
    end
  end

  def irradiance_line(image)
    return "日射量: 不明（未正規化）" if image.irradiance_w_m2.nil?

    type = { "poa" => "POA", "ghi" => "GHI。未正規化" }.fetch(image.irradiance_type.to_s, "種類不明。未正規化")
    "日射量: #{image.irradiance_w_m2.to_f.round} W/m²（#{type}）"
  end

  def module_line(site)
    layout = CELL_LAYOUTS[site.cell_layout] || "セル構成不明"
    "モジュール: #{layout}・サブストリング #{site.substring_count}"
  end

  def weakest_evidence(members)
    members.map(&:evidence_level).compact.max # "A" < "B" < "C" なので、最大が最も弱い
  end

  def cause_labels(causes)
    Array(causes).map { |c| AnomalyReview::CAUSES.fetch(c, c) }.join("、")
  end

  def format_number(value)
    value.to_f.round(2).to_s.sub(/\.0\z/, "")
  end
end
