# グリッドテンプレートの保存と一括適用（docs/IMPROVEMENT_PLAN.md Phase 4-1）。
# 一括適用は、撮影条件（高度・ジンバル角）がテンプレートの元画像と許容差内で、まだグリッドの無い画像だけに行う
# （人が調整したグリッドを上書きしないため）。許容差は config/analyzer.yml の template_match
class GridTemplatesController < ApplicationController
  before_action :require_site
  before_action :find_inspection

  def create
    source = @inspection.inspection_images.find(params[:source_image_id])
    grid = InspectionImage.normalize_grids([ JSON.parse(params.require(:grid)) ]).first
    template = @inspection.grid_templates.create!(
      name: params[:name].presence || "テンプレート #{@inspection.grid_templates.count + 1}",
      rows: grid["rows"], cols: grid["cols"], corners: grid["corners"], panel_orientation: grid["panel_orientation"],
      altitude_m: source.altitude_m, gimbal_pitch: source.gimbal_pitch, gimbal_yaw: source.gimbal_yaw
    )
    redirect_to grid_inspection_inspection_image_path(@inspection, source), notice: "テンプレート「#{template.name}」を保存しました"
  rescue JSON::ParserError, ArgumentError, ActiveRecord::RecordInvalid, ActionController::ParameterMissing => e
    redirect_back_or_to inspection_path(@inspection), alert: "テンプレートを保存できませんでした: #{e.message}"
  end

  def apply
    template = @inspection.grid_templates.find(params[:id])
    result = GridTemplateApplier.new(template, AnalyzerConfig.current.template_match).apply!
    @inspection.refresh_status!
    redirect_back_or_to inspection_path(@inspection), notice: result.message
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:inspection_id])
  end
end
