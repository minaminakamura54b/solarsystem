# 点検内の画像ごとの操作（RGB の手動添付・削除、除外、除外の取り消し）
class InspectionImagesController < ApplicationController
  before_action :require_site
  before_action :find_image

  # RGB 画像を手動で添付・差し替える（ファイル名の _T / _V で自動ペアリングできなかった場合など）
  def update
    rgb = params.dig(:inspection_image, :rgb)
    if rgb.blank?
      redirect_to inspection_path(@inspection), alert: "RGB 画像を選択してください"
    else
      @image.rgb.attach(rgb)
      redirect_to inspection_path(@inspection, anchor: "image_#{@image.id}"), notice: "画像 #{@image.sequence} に RGB 画像を添付しました"
    end
  end

  def remove_rgb
    @image.rgb.purge_later if @image.rgb.attached?
    redirect_to inspection_path(@inspection, anchor: "image_#{@image.id}"), notice: "画像 #{@image.sequence} の RGB 画像を外しました"
  end

  def exclude
    @image.exclude!(params.dig(:inspection_image, :exclusion_note))
    redirect_to inspection_path(@inspection, anchor: "image_#{@image.id}"), notice: "画像 #{@image.sequence} を除外しました"
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    redirect_to inspection_path(@inspection, anchor: "image_#{@image.id}"), alert: e.message.delete_prefix("バリデーションに失敗しました: ")
  end

  def unexclude
    @image.unexclude!
    redirect_to inspection_path(@inspection, anchor: "image_#{@image.id}"), notice: "画像 #{@image.sequence} の除外を取り消しました"
  rescue ArgumentError => e
    redirect_to inspection_path(@inspection), alert: e.message
  end

  # グリッド入力画面
  def grid
    images = @inspection.inspection_images.to_a
    position = images.index(@image)
    @previous_image = position.positive? ? images[position - 1] : nil
    @next_image = images[position + 1]
    @templates = @inspection.grid_templates.order(:created_at)
  end

  # グリッドを保存し、品質チェックに合格していれば解析ジョブを登録する
  def grids
    grids = InspectionImage.normalize_grids(JSON.parse(params.require(:panel_grids)))
    @image.update!(panel_grids: grids)
    if !@image.ready_for_analysis?
      notice = "グリッドを保存しました（品質チェックに合格していないため、解析はしません）"
    elsif grids.empty?
      @image.update!(analysis_status: "needs_review", review_reason: "grid_required")
      notice = "グリッドを削除しました"
    else
      @image.update!(analysis_status: "pending", review_reason: nil, error_message: nil)
      AnalyzeInspectionImageJob.perform_later(@image.id)
      notice = "グリッド #{grids.size} 個を保存し、解析を始めました"
    end
    @inspection.refresh_status!
    redirect_to grid_inspection_inspection_image_path(@inspection, @image), notice: notice
  rescue JSON::ParserError, ArgumentError, ActionController::ParameterMissing => e
    redirect_to grid_inspection_inspection_image_path(@inspection, @image), alert: "グリッドを保存できませんでした: #{e.message}"
  end

  # 未確定の異常を作り直して解析し直す（確定済み＝locked の異常は残る）。
  # 判定基準の mild を下げたときに新しい候補を出すには、再判定ではなく再解析が必要
  def reanalyze
    if @image.ready_for_analysis? && @image.panel_grids.present?
      @image.update!(analysis_status: "pending", review_reason: nil, error_message: nil)
      AnalyzeInspectionImageJob.perform_later(@image.id)
      @inspection.refresh_status!
      redirect_to inspection_path(@inspection, anchor: "image_#{@image.id}"), notice: "画像 #{@image.sequence} の再解析を始めました"
    else
      redirect_to inspection_path(@inspection, anchor: "image_#{@image.id}"), alert: "品質チェックに合格し、グリッドを指定した画像だけ再解析できます"
    end
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_image
    @inspection = current_site.inspections.find(params[:inspection_id])
    @image = @inspection.inspection_images.find(params[:id])
  end
end
