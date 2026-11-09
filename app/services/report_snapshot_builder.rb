# 報告書の内容（版の固定コピー）を作る（docs/IMPROVEMENT_PLAN.md Phase 7 の決定事項 2026-10-22・2026-11-09）。
# - 報告書の画面と PDF は、この固定コピーだけから作る（発行後に点検・配置図・設定が変わっても、版の内容は変わらない）
# - 「第 N 版の発行後に変更があります」は、今の内容で同じものを作り、digest を比べて判定する
# - 本表は確定した異常（重複として却下した観測はまとめる）・群・架台の段。未確定は「候補」の別表
# - 判定はしない（重大度・種類は保存済みの値をそのまま載せる）。Claude の出力の重大度は使わない
# - 個人名を載せない（屋号は設定ファイル、発行者の欄は会社名と資格の種別だけ）。確信度（%）を載せない
class ReportSnapshotBuilder
  SCHEMA_VERSION = 1
  SEVERITY_LABELS = { "mild" => "軽微", "warning" => "注意", "critical" => "重大" }.freeze
  NO_EXPLANATION = "所見は作成していません".freeze

  def initialize(inspection, config: ReportConfig.current)
    @inspection = inspection
    @site = inspection.site
    @config = config
    @images = inspection.inspection_images.reload.to_a
    @used = @images.reject(&:excluded?)
  end

  def build
    impact = ImpactCalculator.new(@inspection)
    items = impact.items.map { |item| item_entry(item) }
    {
      "schema" => SCHEMA_VERSION,
      "business_name" => @config.business_name,
      "site_name" => @site.name,
      "inspection_date" => @inspection.conducted_at.to_date.iso8601,
      "reviewed_at" => @inspection.reviewed_at&.iso8601,
      "severity" => @inspection.severity,
      "conditions" => conditions,
      "criteria" => criteria,
      "summary" => summary,
      "counts" => counts(items),
      "impact" => impact.total.to_h.transform_keys(&:to_s),
      "items" => items,
      "candidates" => candidates,
      "coverage" => coverage,
      "map" => map,
      "rejections" => rejections,
      "module" => module_spec,
      "versions" => versions,
      "warnings" => warnings(items),
      "disclaimers" => disclaimers(items)
    }
  end

  # 内容の digest（発行者の欄などの発行時の入力は含めない）
  def self.digest(snapshot)
    Digest::SHA256.hexdigest(JSON.generate(snapshot.except("issue")))
  end

  private

  # ── 撮影条件 ─────────────────────────────

  def conditions
    times = @used.filter_map(&:captured_at).sort
    irr = @used.filter_map { |i| i.irradiance_w_m2&.to_f }
    temps = @used.filter_map { |i| i.air_temp_c&.to_f }
    winds = @used.filter_map { |i| i.wind_speed_m_s&.to_f }
    {
      "cameras" => @used.filter_map(&:camera_model).tally,
      "captured_from" => times.first&.iso8601, "captured_to" => times.last&.iso8601,
      "irradiance" => irr.any? ? { "min" => irr.min.round, "max" => irr.max.round, "types" => @used.map { |i| i.irradiance_type.presence || "none" }.tally } : nil,
      "air_temp_c" => temps.any? ? [ temps.min.round(1), temps.max.round(1) ] : nil,
      "wind_speed_m_s" => winds.any? ? [ winds.min.round(1), winds.max.round(1) ] : nil,
      "images" => { "total" => @images.size, "used" => @used.size, "excluded" => @images.size - @used.size },
      "quality" => @used.map { |i| i.quality_status || "unknown" }.tally,
      "measurement" => measurement_lines,
      "camera_default_params" => camera_default_params?,
      "weather_note" => @inspection.weather_note.presence
    }
  end

  # 測定パラメータを項目・出どころごとに 1 行（値は範囲）。画像ごとに値が違う距離なども行が増えないようにする
  def measurement_lines
    entries = @used.filter_map(&:measurement_params)
    ThermalMeasurement::LABELS.flat_map do |key, label|
      entries.filter_map { |p| p[key] }.group_by { |e| e["source"] }.map do |source, list|
        values = list.filter_map { |e| e["value"]&.to_f }
        range = values.empty? ? nil : (values.min == values.max ? values.min.round(3).to_s : "#{values.min.round(2)}〜#{values.max.round(2)}")
        text = range ? "#{label}: #{range}（#{ThermalMeasurement::SOURCES.fetch(source, source)}）" : "#{label}: #{ThermalMeasurement::SOURCES.fetch(source, source)}"
        [ text, list.size ]
      end
    end.to_h
  end

  def camera_default_params?
    # 測定パラメータの記録がある画像だけで判断する（記録の無い画像を「既定値を使った」とは言わない）
    @used.any? do |img|
      params = img.measurement_params
      params.present? && %w[emissivity reflected_temperature_c].any? { |key| params.dig(key, "value").nil? }
    end
  end

  # ── 判定基準（異常ごと・段ごとの rule_snapshot から） ───────────

  def criteria
    # 段は候補にならなかった段も同じ閾値で判定しているので、判定した段の閾値を載せる
    snapshots = confirmed_anomalies.map(&:rule_snapshot) + confirmed_groups.map(&:rule_snapshot) + pending_anomalies.map(&:rule_snapshot) +
                @inspection.block_row_findings.where(status: "evaluated").distinct.pluck(:rule_snapshot)
    snapshots = snapshots.compact.uniq { |s| [ s["version"], s["anomaly_type"] ] }
    versions = snapshots.map { |s| s["version"] }.compact.uniq.sort
    rule_sets = RuleSet.where(version: versions).index_by(&:version)
    {
      "versions" => versions.map { |v| { "version" => v, "provisional" => rule_sets[v]&.provisional? || false, "baseline" => rule_sets[v]&.baseline_method_label } },
      "provisional" => versions.any? { |v| rule_sets[v]&.provisional? },
      "rules" => snapshots.sort_by { |s| [ s["version"].to_s, RuleSet::ALL_TYPES.index(s["anomaly_type"]) || 99 ] },
      "basis_counts" => confirmed_anomalies.map { |a| a.threshold_basis.presence || "unknown" }.tally
    }
  end

  # ── 総括文 ─────────────────────────────

  def summary
    current = InspectionSummaryWriter.new(output: nil).current?(@inspection) if @inspection.completed? && @inspection.reviewed_at
    return { "state" => @inspection.summary_generated_at ? "stale" : "none", "text" => nil } unless current

    { "state" => "current", "text" => @inspection.summary_text, "priority_actions" => Array(@inspection.summary_priority_actions),
      "additional_checks" => Array(@inspection.summary_additional_checks), "prompt_version" => @inspection.summary_prompt_version }
  end

  def counts(items)
    { "total" => items.size,
      "by_severity" => items.map { |i| i["severity"] }.tally,
      "by_type" => items.map { |i| i["type"] }.tally }
  end

  # ── 本表 ─────────────────────────────

  def item_entry(item)
    record = item.record
    base = {
      "kind" => item.kind, "panel_count" => item.panel_count,
      "affected_dc_kw" => item.affected_dc_kw, "estimated_loss_kw" => item.estimated_loss_kw, "loss_basis" => item.loss_basis,
      "annual_loss_kwh" => item.annual_loss_kwh, "annual_loss_yen" => item.annual_loss_yen
    }
    case item.kind
    when "anomaly" then base.merge(anomaly_entry(record))
    when "group" then base.merge(group_entry(record))
    else base.merge(row_entry(record))
    end
  end

  def anomaly_entry(a)
    candidate = a.panel_candidate
    others = Array(candidate&.observations).select { |o| o["positive"] && o["image_id"] != a.inspection_image_id }
                                           .first(@config.max_other_observations)
    {
      "id" => a.id, "type" => a.effective_type, "severity" => a.effective_severity, "evidence_level" => a.evidence_level,
      "panel" => a.panel&.number, "delta_t" => a.delta_t&.to_f&.round(2), "measure" => a.measure,
      "normalized_delta_t" => a.normalized_delta_t&.to_f&.round(2), "threshold_basis" => a.threshold_basis,
      "observed" => candidate&.observed_count, "visible" => candidate&.visible_count,
      "image" => image_ref(a.inspection_image, a.effective_bbox),
      "others" => others.map { |o| { "image_id" => o["image_id"], "sequence" => o["sequence"], "bbox" => o["bbox"], "delta_t" => o["delta_t"]&.to_f&.round(2) } },
      **explanation_fields(a)
    }
  end

  def group_entry(g)
    {
      "id" => g.id, "type" => g.group_type, "severity" => g.severity, "evidence_level" => nil, "panel" => nil,
      "delta_t" => g.delta_t&.to_f&.round(2), "measure" => g.measure, "normalized_delta_t" => g.normalized_delta_t&.to_f&.round(2),
      "threshold_basis" => g.threshold_basis, "observed" => nil, "visible" => nil,
      "image" => image_ref(g.inspection_image, union_bbox(g.anomalies.map(&:effective_bbox))), "others" => [], **explanation_fields(g)
    }
  end

  def row_entry(r)
    {
      "id" => r.id, "type" => "block_row", "severity" => r.severity, "evidence_level" => nil, "panel" => r.label,
      "delta_t" => r.effect_c&.to_f&.round(2), "measure" => "row_effect", "normalized_delta_t" => nil, "threshold_basis" => nil,
      "observed" => nil, "visible" => r.views_count, "upper_views" => r.upper_views, "lower_views" => r.lower_views,
      "image" => nil, "others" => [], "explanation_state" => "not_applicable", "explanation" => nil
    }
  end

  def explanation_fields(record)
    current = AnomalyExplainer.new(output: nil).current?(record)
    return { "explanation_state" => record.explained_at ? "stale" : "none", "explanation" => NO_EXPLANATION } unless current

    { "explanation_state" => "current", "explanation" => record.report_text, "causes" => Array(record.cause_candidates).filter_map { |c| c["cause"] if c.is_a?(Hash) },
      "recommended_action" => record.recommended_action, "additional_checks" => Array(record.additional_checks) }
  end

  # 群の構成パネルの bbox をまとめた範囲（群の切り出しに使う）
  def union_bbox(boxes)
    boxes = boxes.compact
    return nil if boxes.empty?

    { "x1" => boxes.map { |b| b["x1"].to_f }.min, "y1" => boxes.map { |b| b["y1"].to_f }.min,
      "x2" => boxes.map { |b| b["x2"].to_f }.max, "y2" => boxes.map { |b| b["y2"].to_f }.max }
  end

  def image_ref(image, bbox)
    return nil unless image

    mapping = RgbCropMapping.for(image)
    rgb = image.rgb.attached? ? image.rgb.blob.metadata.slice("width", "height") : nil
    { "id" => image.id, "sequence" => image.sequence, "bbox" => bbox, "rgb" => image.rgb.attached?,
      "rgb_bbox" => (mapping && bbox && rgb ? mapping.to_rgb(bbox, rgb["width"] || 4, rgb["height"] || 3) : (bbox if image.rgb.attached?)),
      "rgb_mapping" => mapping ? "fov_ratio" : "same_position" }
  end

  # ── 候補（未確定） ─────────────────────────

  def candidates
    # パネルごとの候補にまとめた観測は 1 行（N 枚中 M 枚）。まとめていない観測は 1 件 1 行
    order = %w[mild warning critical]
    pending_anomalies.group_by { |a| a.panel_candidate_id ? "c#{a.panel_candidate_id}" : "a#{a.id}" }.map do |_, list|
      top = list.max_by { |a| [ order.index(a.effective_severity) || -1, a.delta_t.to_f ] }
      cand = top.panel_candidate
      { "kind" => "anomaly", "type" => top.effective_type, "severity" => top.effective_severity, "panel" => top.panel&.number,
        "sequence" => top.inspection_image.sequence, "delta_t" => top.delta_t&.to_f&.round(2),
        "observed" => cand&.observed_count, "visible" => cand&.visible_count }
    end +
      @inspection.anomaly_groups.where(review_status: "pending").map { |g| { "kind" => "group", "type" => g.group_type, "severity" => g.severity, "panel" => "#{g.panel_count} 枚", "sequence" => g.inspection_image.sequence, "delta_t" => g.delta_t&.to_f&.round(2) } } +
      @inspection.block_row_findings.candidates.where(review_status: "pending").includes(:pv_block).map { |r| { "kind" => "block_row", "type" => "block_row", "severity" => r.severity, "panel" => r.label, "sequence" => nil, "delta_t" => r.effect_c&.to_f&.round(2) } }
  end

  # ── 点検の範囲と限界 ─────────────────────────

  def coverage
    summary = InspectionCoverage.new(@inspection).summary
    unused = @images.select(&:excluded?)
    {
      "registered" => summary.registered, "covered" => summary.covered, "uncovered" => summary.uncovered,
      "layout_unlinked_images" => summary.layout_unlinked_images, "outside_layout_images" => summary.outside_layout_images,
      "unused_by_reason" => unused.map { |img| BulkImageExclusion.reason_label(img) }.tally,
      "unused_images" => unused.map { |img| { "sequence" => img.sequence, "captured_at" => img.captured_at&.iso8601, "reason" => BulkImageExclusion.reason_label(img), "note" => img.exclusion_note } },
      "insufficient_rows" => @inspection.block_row_findings.insufficient.includes(:pv_block).sort_by { |r| [ r.pv_block.label, r.block_row ] }
                                     .map { |r| { "label" => r.label, "views" => r.views_count, "reason" => r.insufficient_reason } }
    }
  end

  def map
    blocks = @site.pv_blocks.order(:label).to_a
    return nil if blocks.empty?

    by_id = blocks.index_by(&:id)
    coverage = InspectionCoverage.new(@inspection)
    keys = ->(ids) { Panel.where(id: ids).where.not(pv_block_id: nil).pluck(:pv_block_id, :block_row, :block_col).map { |b, r, c| [ by_id[b]&.label, r, c ] } }
    {
      "blocks" => blocks.map { |b| { "label" => b.label, "rows" => b.rows, "cols" => b.cols, "corners" => b.corners_local } },
      "anomaly_panels" => keys.(confirmed_anomalies.filter_map(&:panel_id)).uniq,
      "rows" => confirmed_rows.map { |r| [ r.pv_block.label, r.block_row ] },
      "insufficient_rows" => @inspection.block_row_findings.insufficient.includes(:pv_block).map { |r| [ r.pv_block.label, r.block_row ] },
      "uncovered_panels" => (coverage.registered_keys - coverage.covered_keys).map { |b, r, c| [ by_id[b]&.label, r, c ] }.sort_by(&:to_s)
    }
  end

  # ── 付録: 人が確認し、異常ではないと判断した候補の件数（重複として却下したものは数えない） ──

  def rejections
    reasons = AnomalyReview::REJECTION_REASONS
    anomaly_units = @inspection.anomalies.where(review_status: "rejected").countable.where.not(rejection_reason: "duplicate")
                               .group_by { |a| a.panel_candidate_id ? "c#{a.panel_candidate_id}" : "a#{a.id}" }
                               .map { |_, list| list.first.rejection_reason }
    group_units = @inspection.anomaly_groups.where(review_status: "rejected").where.not(rejection_reason: "duplicate").pluck(:rejection_reason)
    row_units = @inspection.block_row_findings.candidates.where(review_status: "rejected").pluck(:rejection_reason)
    all = (anomaly_units + group_units + row_units).map { |r| reasons.fetch(r.to_s, "理由の記録なし") }
    { "total" => all.size, "by_reason" => all.tally }
  end

  def module_spec
    { "model" => @site.module_model, "rated_w" => @site.module_rated_w, "cell_layout" => @site.cell_layout,
      "substring_count" => @site.substring_count, "bypass_pattern" => @site.bypass_pattern.present?,
      "specific_yield_kwh_per_kw" => @site.specific_yield_kwh_per_kw&.to_f, "fit_price_yen_per_kwh" => @site.fit_price_yen_per_kwh&.to_f }
  end

  def versions
    blocks = @site.pv_blocks.order(:label).pluck(:label, :rows, :cols, :corners_local)
    {
      "layout" => { "blocks" => blocks.size, "panels" => @site.panels.where.not(pv_block_id: nil).count,
                    "digest" => blocks.any? ? Digest::SHA256.hexdigest(JSON.generate(blocks))[0, 16] : nil },
      "layout_overlay" => @used.filter_map { |i| i.alignment.to_h["config_version"] }.uniq.sort,
      "view_model" => @inspection.view_model.to_h["config_version"],
      "panel_candidates" => @inspection.panel_candidates.distinct.pluck(:config_version).compact.sort,
      "summary_prompt" => @inspection.summary_prompt_version
    }
  end

  # ── 発行時の警告（確認したときだけ発行できる） ─────────────────

  def warnings(items)
    list = []
    pending = @inspection.candidate_count
    list << "未確定の候補が #{pending} 件あります（本表には載せず、「候補」の別表に載せます）" if pending.positive?
    reassign = @inspection.anomalies.where(panel_reassignment_required: true).count
    list << "配置図の置き換えでパネルの割り当てが外れた異常が #{reassign} 件あります" if reassign.positive?
    no_text = items.count { |i| %w[stale none].include?(i["explanation_state"]) }
    list << "所見が古い、または作れていない異常が #{no_text} 件あります（所見の欄に「#{NO_EXPLANATION}」と載せます）" if no_text.positive?
    list << "総括文が古い、または作れていません（総括文の欄は空になります）" unless summary["state"] == "current"
    list << "モジュールの定格出力が未登録のため、影響容量を算定できません" if @site.module_rated_w.nil?
    list << "暫定の判定基準（#{criteria['versions'].select { |v| v['provisional'] }.map { |v| v['version'] }.join('、')}）を使っています" if criteria["provisional"]
    list
  end

  # ── 免責（2026-11-09 の文面。該当するときだけ載せる行がある。顧客に初めて出す前にユーザーが確認する） ──

  def disclaimers(items)
    lines = [
      "本報告書は、ドローンで撮影した赤外線画像の放射温度データから、太陽光パネルの熱異常の候補を抽出し、人が確認した結果をまとめたものです。故障の確定診断ではありません。",
      "法定の点検に代わるものではなく、点検記録の補助資料です。",
      "IEC TS 62446-3 を参考にしていますが、準拠を保証するものではありません。",
      "パネルの特定は、撮影位置の記録と登録された配置図の重ね合わせによる推定です。配置図と現地が異なる場合、パネル番号がずれることがあります。",
      "判定は撮影時の条件（日射・風・時刻・撮影の角度）の影響を受けます。撮影条件の欄をあわせてご確認ください。",
      "「点検の範囲と限界」に記載した範囲は解析できておらず、異常がないことを示すものではありません。",
      "推定損失・年間損失は概算で、電気的な測定で確かめたものではありません。"
    ]
    lines << "放射率など測定パラメータの一部は、カメラの既定値を使用しています（撮影条件の欄に記載）。" if camera_default_params?
    lines << "RGB 画像はおおよその位置です（位置合わせを調整するまで）。" if items.any? { |i| i.dig("image", "rgb") }
    lines << "判定基準は暫定の版で、今後見直す予定です。" if criteria["provisional"]
    lines
  end

  # ── 対象のレコード ─────────────────────────

  def confirmed_anomalies
    @confirmed_anomalies ||= @inspection.anomalies.where(review_status: InspectionReview::CONFIRMED).countable.includes(:panel, :panel_candidate, inspection_image: { rgb_attachment: :blob }).to_a
  end

  def confirmed_groups
    @confirmed_groups ||= @inspection.anomaly_groups.where(review_status: InspectionReview::CONFIRMED).includes(:anomalies, inspection_image: { rgb_attachment: :blob }).to_a
  end

  def confirmed_rows
    @confirmed_rows ||= @inspection.block_row_findings.candidates.where(review_status: "confirmed").includes(:pv_block).to_a
  end

  def pending_anomalies
    @pending_anomalies ||= @inspection.anomalies.candidates.countable.includes(:panel, :inspection_image, :panel_candidate).to_a
  end
end
