require "test_helper"

# 影響容量と推定損失（Phase 7）
class ImpactCalculatorTest < ActiveSupport::TestCase
  setup do
    @site = sites(:south)
    @site.update!(module_rated_w: 400)
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg] * 2)
    @blocks = register_blocks(@site, %w[A01])
    @i1, @i2 = @inspection.inspection_images.order(:sequence).to_a
    analyzed_image(@i1, [ @blocks["A01"] ], y0: 0.4)
    analyzed_image(@i2, [ @blocks["A01"] ], y0: 0.4)
  end

  def confirmed(anomaly) = anomaly.tap { _1.update_columns(review_status: "confirmed", locked: true) }

  def row_finding(row:, review_status: "confirmed")
    @inspection.block_row_findings.create!(pv_block: @blocks["A01"], block_row: row, status: "evaluated", effect_c: 1.6,
                                           severity: "warning", review_status:)
  end

  test "影響容量は項目ごとに 定格 × 枚数。合計はパネルの重複を除く（段と点の異常に同じパネルが入っていても 1 枚）" do
    confirmed(anomaly_at(@i1, 0, 1, 1, type: "hotspot"))
    confirmed(anomaly_at(@i2, 0, 2, 3, type: "partial_module"))
    row_finding(row: 1)

    calc = ImpactCalculator.new(@inspection)

    assert_equal [ 0.4, 0.4, 4.0 ], calc.items.map(&:affected_dc_kw)
    assert_equal 11, calc.total.panels # 段 1 の 10 枚（1 列目の点の異常は段と重なるので数えない）+ 段 2 の 3 列目の 1 枚
    assert_equal 4.4, calc.total.affected_dc_kw
  end

  test "パネルを特定していない異常は重複を確かめられないので、その枚数を足して別に数える" do
    a = confirmed(anomaly_at(@i1, 0, 1, 1, type: "hotspot"))
    a.update_columns(panel_id: nil)

    total = ImpactCalculator.new(@inspection).total

    assert_equal 1, total.unidentified_panels
    assert_equal 0.4, total.affected_dc_kw
  end

  test "未確定・却下・未判断の段は数えない" do
    anomaly_at(@i1, 0, 1, 1, type: "hotspot")
    anomaly_at(@i1, 0, 1, 2, type: "hotspot").update_columns(review_status: "rejected", locked: true)
    row_finding(row: 1, review_status: "pending")

    assert_empty ImpactCalculator.new(@inspection).items
  end

  test "定格出力が無ければ推測で埋めず、null と理由" do
    @site.update!(module_rated_w: nil)
    confirmed(anomaly_at(@i1, 0, 1, 1, type: "hotspot"))

    calc = ImpactCalculator.new(@inspection)

    assert_nil calc.items.first.affected_dc_kw
    assert_equal ImpactCalculator::NO_RATED, calc.items.first.loss_basis
    assert_nil calc.total.affected_dc_kw
    assert_equal 1, calc.total.uncalculated_items
  end

  test "推定損失は substring_bypass（構成が登録済み・帯の本数が分かる）だけ。年間損失は係数と単価があるときだけ" do
    a = confirmed(anomaly_at(@i1, 0, 1, 1, type: "substring_bypass", active_bands: 1))
    confirmed(anomaly_at(@i1, 0, 1, 2, type: "module_wide"))
    confirmed(anomaly_at(@i1, 0, 1, 3, type: "hotspot"))

    items = ImpactCalculator.new(@inspection).items
    assert_nil items[0].estimated_loss_kw, "bypass_pattern が無ければ算定保留"
    assert_equal ImpactCalculator::LOSS_BASIS["no_bypass_pattern"], items[0].loss_basis

    @site.update!(bypass_pattern: { "bands" => 3 }, substring_count: 3, specific_yield_kwh_per_kw: 1200, fit_price_yen_per_kwh: 20)
    items = ImpactCalculator.new(@inspection.reload).items
    assert_in_delta 0.133, items[0].estimated_loss_kw, 0.001
    assert_in_delta 160.0, items[0].annual_loss_kwh, 0.5
    assert_equal 3192, items[0].annual_loss_yen
    assert_nil items[1].estimated_loss_kw
    assert_equal ImpactCalculator::LOSS_BASIS["module_wide"], items[1].loss_basis
    assert_equal ImpactCalculator::LOSS_BASIS["pending"], items[2].loss_basis
    assert_nil items[2].annual_loss_kwh

    a.update_columns(active_bands: nil)
    assert_equal ImpactCalculator::LOSS_BASIS["no_bands"], ImpactCalculator.new(@inspection.reload).items[0].loss_basis
  end
end
