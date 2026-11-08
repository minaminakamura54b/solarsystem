require "test_helper"

# 架台・段の候補（案 X 改）。合成の解析結果（パネルの平均温度）だけを使う
class BlockRowEffectTest < ActiveSupport::TestCase
  CONFIG = RowEffectConfig.new(
    version: "test", model: { min_images: 4, min_y_low: 0.2, min_y_high: 0.8, mad_k: 3, mad_floor_c: 0.3 },
    row: { min_views: 3, upper_y: 0.45, lower_y: 0.55, min_panels_per_view: 3 }
  )

  setup do
    load_initial_rule_set
    @row_rules = RuleSet.find_by!(version: "2026-11-trend-row-provisional")
    @inspection = analyzable_inspection(grids: [], files: [ "thermal_plain_T.jpg" ] * 8)
    @blocks = register_blocks(@inspection.site, %w[A01 A02 A03]).values
    @images = @inspection.inspection_images.order(:sequence).to_a
  end

  # 見え方の影響（画像の下側ほど +2.5℃）と小さなばらつきに、A02 の 2 段目だけ本物の +hot℃ を足す。
  # 画像ごとに写る架台の組を変える（A02 が画像の左にも右にも写る）。shots は [縦位置, 架台の組（0: A01・A02 / 1: A02・A03）]
  def shoot(shots, hot: 1.6)
    @images.zip(shots).each do |img, (y0, pair)|
      blocks = pair.zero? ? @blocks[0, 2] : @blocks[1, 2]
      temp = ->(gi, row, col, y) { 30 + 2.5 * y + 0.1 * Math.sin(gi * 7 + row * 3 + col) + (blocks[gi] == @blocks[1] && row == 2 ? hot : 0) }
      analyzed_image(img, blocks, y0:, temp:)
    end
  end

  def varied = [ [ 0.1, 0 ], [ 0.3, 1 ], [ 0.5, 0 ], [ 0.7, 1 ], [ 0.1, 1 ], [ 0.3, 0 ], [ 0.5, 1 ], [ 0.7, 0 ] ]

  def compute(config: CONFIG, rule_set: @row_rules) = BlockRowEffect.new(@inspection, config:, rule_set:).call

  def finding(label, row) = @inspection.block_row_findings.reload.find { |f| f.pv_block.label == label && f.block_row == row }

  test "見え方の影響を除いて、段全体の発熱を候補にする（閾値はルールセットの block_row）。ほかの段は候補にしない" do
    shoot(varied)
    compute

    hot = finding("A02", 2)
    assert_equal "evaluated", hot.status
    assert_in_delta 1.6, hot.effect_c.to_f, 0.35
    assert_includes %w[mild warning], hot.severity
    assert_equal [ "2026-11-trend-row-provisional", 0.8 ], [ hot.rule_version, hot.rule_snapshot["raw_mild"] ]
    assert_equal [ 8, 2, 4 ], [ hot.views_count, hot.upper_views, hot.lower_views ] # 2 段目の中心が縦 0.45 未満・0.55 超
    others = @inspection.block_row_findings.reject { |f| f.id == hot.id }
    assert others.all? { |f| f.status == "evaluated" && f.severity.nil? }, others.map { |f| [ f.label, f.effect_c ] }.inspect
    assert_equal "ok", @inspection.reload.view_model["status"]
  end

  test "画像の上側にしか写っていない段は「判断の材料が足りない」（理由つき。正常にはしない）" do
    # A03 は画像の上側（縦 0.1〜0.25）にしか写らない
    shoot([ [ 0.1, 0 ], [ 0.3, 0 ], [ 0.5, 0 ], [ 0.7, 0 ], [ 0.1, 1 ], [ 0.15, 1 ], [ 0.2, 1 ], [ 0.25, 1 ] ])
    compute

    assert_equal "evaluated", finding("A01", 1).status
    f = finding("A03", 2)
    assert_equal [ "insufficient", nil ], [ f.status, f.severity ]
    assert_match "上側にしか写っておらず", f.insufficient_reason
  end

  test "解析済みの画像が足りなければ、見え方の影響を求めず、すべての段を「判断の材料が足りない」にする" do
    shoot(varied)
    strict = RowEffectConfig.new(version: "t", model: CONFIG.model.merge("min_images" => 100), row: CONFIG.row)
    compute(config: strict)

    assert_equal "insufficient", @inspection.reload.view_model["status"]
    assert @inspection.block_row_findings.all? { |f| f.status == "insufficient" && f.insufficient_reason.include?("100 枚以上必要") }
  end

  test "判定基準に block_row が無ければ、効果だけを出して候補にしない" do
    shoot(varied)
    compute(rule_set: RuleSet.find_by!(version: "2026-09-initial"))

    assert_nil finding("A02", 2).severity
    assert finding("A02", 2).effect_c.to_f > 1.0
  end

  test "人が判断した段は作り直さない。確定した段の重大度は点検の重要度に入り、未判断の段は未確定の候補に数える" do
    shoot(varied)
    compute
    hot = finding("A02", 2)
    assert_equal 1, @inspection.candidate_count

    BlockRowReview.new(hot).confirm!
    shoot(varied, hot: 0.0)
    compute

    assert_equal [ hot.id, "confirmed", hot.severity ], finding("A02", 2).then { |f| [ f.id, f.review_status, f.severity ] }
    assert_equal hot.severity, InspectionReview.new(@inspection).final_severity
    assert_raises(BlockRowReview::Error) { BlockRowReview.new(finding("A01", 1)).confirm! }
  end
end
