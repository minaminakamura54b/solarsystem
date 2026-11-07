# 架台の登録（docs/LAYOUT_OVERLAY_DESIGN.md の A）。架台の CSV のアップロード → 確認画面 → 確定。
# 置き換えの処理は BlockLayoutImport（パネルは Phase 5b の PanelLayoutImport）に任せる
class BlockLayoutsController < ApplicationController
  before_action :find_site

  def new
    @blocks = @site.pv_blocks.order(:label).to_a
  end

  def template
    send_data BlockLayoutImport.template_csv, filename: "block_layout_template.csv", type: "text/csv; charset=utf-8"
  end

  def export
    send_data BlockLayoutImport.export_csv(@site), filename: "block_layout_site#{@site.id}.csv", type: "text/csv; charset=utf-8"
  end

  # CSV を読んで、置き換えの内容を表示する（まだ何も変えない）
  def preview
    file = params[:file]
    return render_new_with_errors([ "CSV ファイルを選んでください" ]) unless file.respond_to?(:read)

    @csv_text = PanelLayoutImport.decode(file.read)
    @import = BlockLayoutImport.new(@site, @csv_text)
    return render_new_with_errors(@import.errors) unless @import.valid?

    @plan = @import.plan
    render :preview
  rescue PanelLayoutImport::Error => e
    render_new_with_errors([ e.message ])
  end

  def create
    @csv_text = params[:csv_text].to_s
    @import = BlockLayoutImport.new(@site, @csv_text)
    return render_new_with_errors(@import.errors) unless @import.valid?

    plan = @import.apply!(expected_digest: params[:plan_digest].to_s)
    notice = "架台 #{@import.blocks.size} 個・パネル #{@import.panel_rows.size} 枚を登録しました"
    reassign = plan.panel_plan.reassignment_anomalies.size
    notice += "。パネルの割り当てが外れた異常が #{reassign} 件あります。割り当て直してください" if reassign.positive?
    redirect_to new_site_block_layout_path(@site), notice: notice
  rescue BlockLayoutImport::StalePlan => e
    @plan = @import.plan
    flash.now[:alert] = e.message
    render :preview, status: :conflict
  end

  private

  def find_site
    @site = Site.find(params[:site_id])
  end

  def render_new_with_errors(errors)
    @errors = errors
    @blocks = @site.pv_blocks.order(:label).to_a
    render :new, status: :unprocessable_entity
  end
end
