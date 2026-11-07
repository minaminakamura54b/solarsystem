# 点検の画像から架台の地図の候補を作る（docs/LAYOUT_OVERLAY_DESIGN.md の A-3）。
# 候補は確認画面（配置図）と CSV で見て、架台の登録（BlockLayoutsController の確認画面）に進む。自動では登録しない
class BlockMapProposalsController < ApplicationController
  before_action :find_site

  def create
    inspection = @site.inspections.find(params[:inspection_id])
    proposal = @site.block_map_proposals.build(
      inspection:, status: "pending",
      params: {
        "module_width_m" => params[:module_width_m].to_f, "module_length_m" => params[:module_length_m].to_f,
        "rows" => params[:rows].presence&.to_i, "facing_azimuth_deg" => (params[:facing_azimuth_deg].presence || 180).to_f
      }.compact
    )
    if proposal.save
      BuildBlockMapJob.perform_later(proposal.id)
      redirect_to site_block_map_proposal_path(@site, proposal), notice: "架台の地図の候補を作り始めました（画像の枚数によって数分〜数十分かかります）"
    else
      redirect_to inspection_path(inspection), alert: proposal.errors.full_messages.join("。")
    end
  end

  def show
    @proposal = @site.block_map_proposals.find(params[:id])
  end

  def csv
    proposal = @site.block_map_proposals.find(params[:id])
    send_data proposal.to_csv, filename: "block_map_proposal_#{proposal.id}.csv", type: "text/csv; charset=utf-8"
  end

  private

  def find_site
    @site = Site.find(params[:site_id])
  end
end
