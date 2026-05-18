class AlertsController < ApplicationController
  before_action :require_site

  def index
    @alerts = current_site.alerts.recent.includes(:inspection, :panel)
    @unread_count = current_site.alerts.unread.count
  end

  def update
    @alert = current_site.alerts.find(params[:id])
    @alert.mark_as_read!

    respond_to do |format|
      format.html { redirect_to alerts_path }
      format.turbo_stream
    end
  end

  def mark_all_read
    current_site.alerts.unread.update_all(read_at: Time.current)
    redirect_to alerts_path, notice: "すべての通知を既読にしました"
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end
end
