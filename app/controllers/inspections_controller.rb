class InspectionsController < ApplicationController
  before_action :require_site
  before_action :find_inspection, only: %i[show destroy]

  def index
    @inspections = current_site.inspections.recent.includes(:site)
  end

  def show
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
end