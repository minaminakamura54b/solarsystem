class DashboardController < ApplicationController
  def show
    return unless current_site

    @panels = current_site.panels.by_position
    @panel_status_summary = current_site.panel_status_summary
    @recent_alerts = current_site.alerts.unread.recent.limit(5)
    @latest_inspection = current_site.latest_inspection
    @recent_inspections = current_site.inspections.recent.limit(5)

    # 直近7日間の点検数（グラフ用）
    @inspection_chart_data = current_site.inspections
      .where(conducted_at: 7.days.ago..Time.current)
      .group_by_day(:conducted_at)
      .count

    # 月別売電収益（直近6ヶ月）
    last_6_months = (0..5).map { |i| Date.today - i.months }.reverse
    @revenue_chart_data = last_6_months.map do |d|
      rev = current_site.revenues.find_by(year: d.year, month: d.month)
      [ "#{d.month}月", rev&.amount_yen.to_i ]
    end.to_h

    @kwh_chart_data = last_6_months.map do |d|
      rev = current_site.revenues.find_by(year: d.year, month: d.month)
      [ "#{d.month}月", rev&.kwh.to_f ]
    end.to_h
  end
end