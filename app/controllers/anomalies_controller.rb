# 異常のレビュー操作（docs/IMPROVEMENT_PLAN.md Phase 5）。処理は AnomalyReview に任せる
class AnomaliesController < ApplicationController
  before_action :require_site
  before_action :find_inspection
  before_action :find_anomaly, except: :create

  # 見逃しの手動追加
  def create
    image = @inspection.inspection_images.find(params[:image_id])
    AnomalyReview.add_manual!(
      image, anomaly_type: params[:anomaly_type], severity: params[:severity], bbox: parse_bbox(params[:bbox]),
      panel_index: params[:panel_index], causes: params[:causes], rgb_checked: checked?(:rgb_checked), note: params[:note]
    )
    back_to(image, notice: "見逃しを追加しました")
  rescue AnomalyReview::Error, ActiveRecord::RecordInvalid => e
    back_to(image, alert: e.message)
  end

  def confirm
    review { |r| r.confirm!(rgb_checked: checked?(:rgb_checked), causes: params[:causes], note: params[:note]) }
  end

  def correct
    review do |r|
      r.correct!(final_anomaly_type: params[:final_anomaly_type], final_bbox: parse_bbox(params[:final_bbox]),
                 final_severity: params[:final_severity],
                 rgb_checked: checked?(:rgb_checked), causes: params[:causes], note: params[:note])
    end
  end

  def reject
    review { |r| r.reject!(reason: params[:rejection_reason].to_s, note: params[:note]) }
  end

  def assign_panel
    panel = params[:panel_id].present? ? @inspection.site.panels.find_by(id: params[:panel_id]) : nil
    review { |r| r.assign_panel!(panel) }
  end

  def electrical
    review { |r| r.record_electrical!(method: params[:method].to_s, result: params[:result], measured_on: params[:measured_on]) }
  end

  def remove_from_group
    review(&:remove_from_group!)
  end

  private

  def review
    yield AnomalyReview.new(@anomaly)
    back_to(@anomaly.inspection_image, notice: "異常（画像 #{@anomaly.inspection_image.sequence}・パネル #{@anomaly.panel_index_in_image || '-'}）を更新しました", anchor: "anomaly_#{@anomaly.id}")
  rescue AnomalyReview::Error, ActiveRecord::RecordInvalid => e
    back_to(@anomaly.inspection_image, alert: e.message, anchor: "anomaly_#{@anomaly.id}")
  end

  def back_to(image, anchor: nil, **flash)
    redirect_to review_inspection_path(@inspection, image: image&.sequence, anchor: anchor), flash
  end

  def checked?(key)
    params[key] == "1"
  end

  def parse_bbox(value)
    return nil if value.blank?

    JSON.parse(value)
  rescue JSON::ParserError
    nil
  end

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:inspection_id])
  end

  def find_anomaly
    @anomaly = @inspection.anomalies.find(params[:id])
  end
end
