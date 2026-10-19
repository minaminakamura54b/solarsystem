# 実配置の登録（docs/IMPROVEMENT_PLAN.md Phase 5b）。CSV のアップロード → 確認画面 → 確定。
# 置き換えの処理は PanelLayoutImport に任せる。show は割り当て直しが必要な異常の一覧
class PanelLayoutsController < ApplicationController
  before_action :find_site

  def new; end

  def template
    send_data PanelLayoutImport.template_csv, filename: "panel_layout_template.csv", type: "text/csv; charset=utf-8"
  end

  # CSV を読んで、置き換えの内容を表示する（まだ何も変えない）
  def preview
    file = params[:file]
    return render_new_with_errors([ "CSV ファイルを選んでください" ]) unless file.respond_to?(:read)

    @csv_text = PanelLayoutImport.decode(file.read)
    @import = PanelLayoutImport.new(@site, @csv_text)
    return render_new_with_errors(@import.errors) unless @import.valid?

    @plan = @import.plan
    render :preview
  rescue PanelLayoutImport::Error => e
    render_new_with_errors([ e.message ])
  end

  # 確認画面の内容で置き換える。確認画面の後にデータが変わっていたら、確認画面を出し直す
  def create
    @csv_text = params[:csv_text].to_s
    @import = PanelLayoutImport.new(@site, @csv_text)
    return render_new_with_errors(@import.errors) unless @import.valid?

    plan = @import.apply!(expected_digest: params[:plan_digest].to_s)
    notice = "実配置のパネル #{@import.rows.size} 枚を登録しました"
    notice += "。パネルの割り当てが外れた異常が #{plan.reassignment_anomalies.size} 件あります。割り当て直してください" if plan.reassignment_anomalies.any?
    redirect_to site_panel_layout_path(@site), notice: notice
  rescue PanelLayoutImport::StalePlan => e
    @plan = @import.plan
    flash.now[:alert] = e.message
    render :preview, status: :conflict
  end

  def show
    @anomalies = Anomaly.joins(:inspection).where(inspections: { site_id: @site.id }, panel_reassignment_required: true)
                        .includes(:inspection, :inspection_image).order("inspections.conducted_at DESC", :id)
    @layout_counts = @site.panels.group(:layout_source).count
  end

  private

  def find_site
    @site = Site.find(params[:site_id])
  end

  def render_new_with_errors(errors)
    @errors = errors
    render :new, status: :unprocessable_entity
  end
end
