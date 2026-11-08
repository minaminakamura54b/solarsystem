# 発電所ごとの部材の位置（案 A。2026-11-08 ユーザー承認）の一覧と削除。登録はパネルごとの候補の「部材・構造物」の却下から
class StructurePositionsController < ApplicationController
  before_action :find_site

  def index
    @positions = @site.structure_positions.includes(:source_inspection).order(:block_row, :block_col, :v_bin, :u_bin)
  end

  def destroy
    position = @site.structure_positions.find(params[:id])
    position.destroy!
    redirect_to site_structure_positions_path(@site), notice: "部材の位置（#{position.description}）を削除しました。次に候補を作り直すときから目印を付けません"
  end

  private

  def find_site
    @site = Site.find(params[:site_id])
  end
end
