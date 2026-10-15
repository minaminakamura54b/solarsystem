# 異常群（隣接パネル群）のレビュー操作。群単位で確定・却下し、構成パネルにも反映する
class AnomalyGroupsController < ApplicationController
  before_action :require_site
  before_action :find_group

  def confirm
    review { |r| r.confirm!(note: params[:note]) }
  end

  def reject
    review { |r| r.reject!(reason: params[:rejection_reason].to_s, note: params[:note]) }
  end

  private

  def review
    yield AnomalyReview.new(@group)
    redirect_to review_inspection_path(@inspection, image: @group.inspection_image.sequence, anchor: "group_#{@group.id}"),
                notice: "隣接パネル群（#{@group.panel_count}枚）を更新しました"
  rescue AnomalyReview::Error, ActiveRecord::RecordInvalid => e
    redirect_to review_inspection_path(@inspection, image: @group.inspection_image.sequence, anchor: "group_#{@group.id}"), alert: e.message
  end

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_group
    @inspection = current_site.inspections.find(params[:inspection_id])
    @group = @inspection.anomaly_groups.find(params[:id])
  end
end
