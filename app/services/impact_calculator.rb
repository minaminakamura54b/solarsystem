# 影響容量と推定損失（docs/IMPROVEMENT_PLAN.md Phase 7 の手順 1 と、決定事項 2026-10-22・2026-11-09）。
# - 対象: 確定・修正した異常（群の構成パネルを除く）・群・架台・段の候補（確定）
# - 影響容量（項目ごと）= 定格 W / 1000 × 対象のパネルの枚数。合計はパネルの重複を除いて数える
#   （同じパネルが確定した段と点状の異常の両方に入っていても 1 枚）。パネルを特定していない項目は重複を確かめられないので、
#   その枚数をそのまま足し、「パネル未特定」として別に数える
# - モジュールの定格出力が無ければ推測で埋めず、すべて null と理由（「算定済み X kW（未算定 N 件）」）
# - 推定損失は substring_bypass（bypass_pattern が登録済みで、作動した帯の本数が分かるとき）だけ。それ以外は null と理由
# - 年間損失（kWh・円）は推定損失と、年間発電量の係数・単価があるときだけ（概算）
# 判定（重大度・種類）には使わない。計算した値は保存せず、報告書の版の固定コピーにだけ残す（人が確定した異常の行は書き換えない）
class ImpactCalculator
  NO_RATED = "モジュールの定格出力が未登録のため算定できません".freeze
  LOSS_BASIS = {
    "module_wide" => "モジュール全体の発熱。開放・短絡の可能性があり、電気測定で確認が必要",
    "pending" => "算定保留（サーモのみでは出力低下量を確定できない）",
    "group" => "隣接パネル群。影響容量のみ（出力低下量はサーモのみでは確定できない）",
    "block_row" => "架台の段全体の温度上昇。影響容量のみ（出力低下量はサーモのみでは確定できない）",
    "no_bypass_pattern" => "算定保留（モジュールのバイパスダイオードの構成が未登録）",
    "no_bands" => "算定保留（作動した帯の本数が分からない）"
  }.freeze

  Item = Data.define(:kind, :record, :panel_ids, :unidentified_panels, :affected_dc_kw, :estimated_loss_kw, :loss_basis,
                     :annual_loss_kwh, :annual_loss_yen) do
    def panel_count = panel_ids.size + unidentified_panels
  end

  Total = Data.define(:affected_dc_kw, :panels, :unidentified_panels, :uncalculated_items, :reason)

  def initialize(inspection)
    @inspection = inspection
    @site = inspection.site
    @rated_w = @site.module_rated_w
  end

  def items
    @items ||= anomaly_items + group_items + row_items
  end

  def total
    unique = items.flat_map(&:panel_ids).uniq.size
    unidentified = items.sum(&:unidentified_panels)
    return Total.new(affected_dc_kw: nil, panels: unique + unidentified, unidentified_panels: unidentified, uncalculated_items: items.size, reason: NO_RATED) unless @rated_w

    Total.new(affected_dc_kw: kw(unique + unidentified), panels: unique + unidentified, unidentified_panels: unidentified, uncalculated_items: 0, reason: nil)
  end

  private

  def anomaly_items
    @inspection.anomalies.where(review_status: InspectionReview::CONFIRMED).countable.order(:inspection_image_id, :id).map do |a|
      loss, basis = loss_for(a)
      build("anomaly", a, a.panel_id ? [ a.panel_id ] : [], a.panel_id ? 0 : 1, loss, basis)
    end
  end

  def group_items
    @inspection.anomaly_groups.where(review_status: InspectionReview::CONFIRMED).includes(:anomalies).order(:inspection_image_id, :id).map do |g|
      ids = g.anomalies.filter_map(&:panel_id).uniq
      build("group", g, ids, [ g.panel_count.to_i - ids.size, 0 ].max, nil, LOSS_BASIS["group"])
    end
  end

  def row_items
    @inspection.block_row_findings.candidates.where(review_status: "confirmed").includes(:pv_block).map do |r|
      ids = Panel.where(pv_block_id: r.pv_block_id, block_row: r.block_row).pluck(:id)
      build("block_row", r, ids, [ r.pv_block.cols - ids.size, 0 ].max, nil, LOSS_BASIS["block_row"])
    end
  end

  def build(kind, record, panel_ids, unidentified, loss_kw, basis)
    return Item.new(kind:, record:, panel_ids:, unidentified_panels: unidentified, affected_dc_kw: nil, estimated_loss_kw: nil,
                    loss_basis: NO_RATED, annual_loss_kwh: nil, annual_loss_yen: nil) unless @rated_w

    kwh = loss_kw && @site.specific_yield_kwh_per_kw ? (loss_kw * @site.specific_yield_kwh_per_kw.to_f).round(1) : nil
    yen = kwh && @site.fit_price_yen_per_kwh ? (kwh * @site.fit_price_yen_per_kwh.to_f).round : nil
    Item.new(kind:, record:, panel_ids:, unidentified_panels: unidentified, affected_dc_kw: kw(panel_ids.size + unidentified),
             estimated_loss_kw: loss_kw, loss_basis: basis, annual_loss_kwh: kwh, annual_loss_yen: yen)
  end

  def loss_for(anomaly)
    case anomaly.effective_type
    when "substring_bypass"
      return [ nil, LOSS_BASIS["no_bypass_pattern"] ] if @site.bypass_pattern.blank?
      return [ nil, LOSS_BASIS["no_bands"] ] if anomaly.active_bands.nil? || @rated_w.nil?

      bands = [ anomaly.active_bands, @site.substring_count ].min
      [ (@rated_w * bands / @site.substring_count.to_f / 1000).round(3), "作動した帯 #{bands} 本 / 帯の総数 #{@site.substring_count} 本から算出" ]
    when "module_wide" then [ nil, LOSS_BASIS["module_wide"] ]
    else [ nil, LOSS_BASIS["pending"] ]
    end
  end

  def kw(panels) = (@rated_w * panels / 1000.0).round(3)
end
