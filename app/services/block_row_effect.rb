require "matrix"

# 架台・段の候補を作る（案 X 改。docs/LAYOUT_OVERLAY_DESIGN.md。2026-11-08 ユーザー承認）。
# 1. 点検の解析済みの画像から、パネル（端で切れていないもの）の平均温度と画像内の中心の位置を集める
# 2. 画像ごとに、パネルの平均温度の中央値を引く（画像ごとの明るさの違い）
# 3. 見え方の影響を、画像内の位置の 2 次式 f(縦, 横) として、全画像の観測から 1 つだけ求める（外れ値を除いて当てはめ直す）。
#    画像ごとに求めないので、1 つの架台が熱くても関数に吸収されない
# 4. 段の効果 = その段が写った画像ごとの「残りの差」の平均の、画像をまたいだ中央値
# 5. 判断できる段（min_views 枚以上・画像の上半分にも下半分にも写る）だけを、ルールセットの block_row の閾値で候補にする。
#    判断できない段は insufficient（判断の材料が足りない。理由つき）。正常にはしない
# 人が判断した段（locked）は作り直さない。判定に使ったルールセットの版と閾値を段ごとに残す
class BlockRowEffect
  FEATURES = ->(x, y) { [ 1.0, y, y * y, x, x * x, x * y ] }

  def initialize(inspection, config: RowEffectConfig.current, rule_set: RuleSet.active_set)
    @inspection = inspection
    @config = config
    @rule_set = rule_set
  end

  def call
    obs, images = collect
    model = fit(obs, images)
    @inspection.update_columns(view_model: model.except(:coef).merge("coefficients" => model[:coef]), updated_at: Time.current)
    rule = @rule_set&.rule_for("block_row")
    rows = per_row(obs, model)
    ActiveRecord::Base.transaction do
      locked = @inspection.block_row_findings.where(locked: true).pluck(:pv_block_id, :block_row)
      @inspection.block_row_findings.where(locked: false).delete_all
      rows.each do |(block_id, row), views|
        next if locked.include?([ block_id, row ])

        @inspection.block_row_findings.create!(attributes_for(block_id, row, views, model, rule))
      end
    end
    @inspection.block_row_findings.reload
  end

  private

  # 観測: { image_id, sequence, x, y, residual_offset（パネル平均 − 画像の中央値）, key（[架台 ID, 段]）, bbox }
  def collect
    obs = []
    images = 0
    @inspection.inspection_images.where(analysis_status: "completed").find_each do |image|
      panels = Array(image.raw_analysis&.dig("panels")).reject { |p| p["excluded"] || p["t_mean"].nil? }
      next if panels.empty?

      images += 1
      offset = median(panels.map { |p| p["t_mean"].to_f })
      grids = Array(image.panel_grids)
      panels.each do |p|
        b = p["bbox"]
        grid = grids[p["grid_index"].to_i]
        obs << { image_id: image.id, sequence: image.sequence, x: (b["x1"].to_f + b["x2"].to_f) / 2, y: (b["y1"].to_f + b["y2"].to_f) / 2,
                 value: p["t_mean"].to_f - offset, key: grid&.dig("pv_block_id") ? [ grid["pv_block_id"], p["row"].to_i + 1 ] : nil, bbox: b }
      end
    end
    [ obs, images ]
  end

  def fit(obs, images)
    m = @config.model
    ys = obs.map { |o| o[:y] }
    reason = if images < m["min_images"].to_i
      "解析済みの画像が #{images} 枚で、見え方の影響を求めるのに足りません（#{m['min_images']} 枚以上必要）"
    elsif ys.empty? || ys.min > m["min_y_low"].to_f || ys.max < m["min_y_high"].to_f
      "パネルが画像の上から下まで写っておらず、見え方の影響を求められません"
    end
    return { "status" => "insufficient", "reason" => reason, "images" => images, "observations" => obs.size, coef: nil } if reason

    keep = Array.new(obs.size, true)
    coef = nil
    5.times do
      coef = solve(obs.each_index.select { |i| keep[i] }.map { |i| obs[i] })
      res = obs.map { |o| o[:value] - dot(coef, FEATURES.(o[:x], o[:y])) }
      kept = res.each_index.select { |i| keep[i] }.map { |i| res[i] }
      center = median(kept)
      mad = [ median(kept.map { |r| (r - center).abs }) * 1.4826, m["mad_floor_c"].to_f ].max
      new_keep = res.map { |r| (r - center).abs <= m["mad_k"].to_f * mad }
      break if new_keep == keep

      keep = new_keep
    end
    { "status" => "ok", "images" => images, "observations" => obs.size, "kept" => keep.count(true), coef: coef.map { |c| c.round(4) },
      "config_version" => @config.version }
  end

  def solve(rows)
    a = Matrix[*rows.map { |o| FEATURES.(o[:x], o[:y]) }]
    b = Vector[*rows.map { |o| o[:value] }]
    ((a.transpose * a).inverse * (a.transpose * b)).to_a
  end

  # 段ごとの画像ごとの観測（残りの差の平均・段の中心の縦位置・段の範囲）
  def per_row(obs, model)
    min_panels = @config.row["min_panels_per_view"].to_i
    rows = Hash.new { |h, k| h[k] = [] }
    obs.select { |o| o[:key] }.group_by { |o| [ o[:key], o[:image_id] ] }.each do |(key, image_id), list|
      next if list.size < min_panels

      effect = model[:coef] ? list.sum { |o| o[:value] - dot(model[:coef], FEATURES.(o[:x], o[:y])) } / list.size : nil
      boxes = list.map { |o| o[:bbox] }
      rows[key] << { "image_id" => image_id, "sequence" => list.first[:sequence], "y" => (list.sum { |o| o[:y] } / list.size).round(3),
                     "effect" => effect&.round(3),
                     "bbox" => { "x1" => boxes.map { |b| b["x1"].to_f }.min, "y1" => boxes.map { |b| b["y1"].to_f }.min,
                                 "x2" => boxes.map { |b| b["x2"].to_f }.max, "y2" => boxes.map { |b| b["y2"].to_f }.max } }
    end
    rows
  end

  def attributes_for(block_id, row, views, model, rule)
    r = @config.row
    upper = views.count { |v| v["y"] < r["upper_y"].to_f }
    lower = views.count { |v| v["y"] > r["lower_y"].to_f }
    reason = if model["status"] != "ok"
      model["reason"]
    elsif views.size < r["min_views"].to_i
      "写った画像が #{views.size} 枚で足りません（#{r['min_views']} 枚以上必要）"
    elsif upper.zero? || lower.zero?
      "画像の#{upper.zero? ? '下側' : '上側'}にしか写っておらず、見え方の影響と区別できません"
    end
    effect = views.filter_map { |v| v["effect"] }.then { |e| e.empty? ? nil : median(e) }
    severity = reason.nil? && rule && effect ? severity_for(effect, rule) : nil
    {
      pv_block_id: block_id, block_row: row, status: reason ? "insufficient" : "evaluated", insufficient_reason: reason,
      effect_c: effect&.round(3), views_count: views.size, upper_views: upper, lower_views: lower,
      observations: views.sort_by { |v| v["sequence"] }, severity:,
      rule_set_id: @rule_set&.id, rule_version: @rule_set&.version, rule_snapshot: rule&.snapshot, config_version: @config.version
    }
  end

  def severity_for(effect, rule)
    if effect >= rule.raw_critical.to_f then "critical"
    elsif effect >= rule.raw_warning.to_f then "warning"
    elsif effect >= rule.raw_mild.to_f then "mild"
    end
  end

  def dot(a, b) = a.zip(b).sum { |x, y| x * y }

  def median(values)
    sorted = values.sort
    n = sorted.size
    n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  end
end
