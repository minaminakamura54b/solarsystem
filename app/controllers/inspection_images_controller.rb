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

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_image
    @inspection = current_site.inspections.find(params[:inspection_id])
    @image = @inspection.inspection_images.find(params[:id])
  end
end
