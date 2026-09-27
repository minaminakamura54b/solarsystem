class InspectionsController < ApplicationController
  before_action :require_site
  before_action :find_inspection, only: %i[show destroy]

  def index
    @inspections = current_site.inspections.recent.includes(:site)
  end

  def show
    # 表示用の値を組み立てるだけで、DB には書き込まない。
    # 古いデータは result に Claude の生 JSON が入っていることがあるので、そこから概要などを読む
    @display_anomalies = @inspection.anomalies
    if @inspection.completed? && @inspection.result.to_s.strip.start_with?("{")
      begin
        parsed = JSON.parse(@inspection.result)
        @display_anomalies      = parsed["anomalies"] || [] if @display_anomalies.blank?
        @display_summary        = parsed["summary"]
        @display_recommendation = parsed["recommendation"]
      rescue JSON::ParserError
        @display_summary = nil
      end
    else
      @display_summary        = @inspection.result
      @display_recommendation = recommendation_from_report(@inspection.report)
    end

    respond_to do |format|
      format.html
      format.json do
        render json: {
          id: @inspection.id,
          analysis_status: @inspection.analysis_status,
          severity: @inspection.severity,
          anomaly_count: @inspection.anomaly_count
        }
      end
    end
  end

  def new
    @inspection = current_site.inspections.build(conducted_at: Time.current)
  end

  def create
    @inspection = current_site.inspections.build(inspection_params)
    @inspection.conducted_at ||= Time.current

    if @inspection.save
      # 非同期でAI解析を実行
      AnalyzePanelImageJob.perform_later(@inspection.id)
      redirect_to inspection_path(@inspection),
        notice: "画像をアップロードしました。AI解析を開始します..."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @inspection.destroy
    redirect_to inspections_path, notice: "点検記録を削除しました"
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:id])
  end

  def inspection_params
    params.require(:inspection).permit(:image, :conducted_at)
  end

  def recommendation_from_report(report)
    return nil if report.blank? || report.strip.start_with?("{")
    lines = report.split("\n")
    idx = lines.index { |l| l.include?("推奨アクション") }
    return nil unless idx
    lines[idx + 1..].reject(&:blank?).join("\n").strip.presence
  end
end
