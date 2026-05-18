class SitesController < ApplicationController
  before_action :find_site, only: %i[show edit update destroy]

  def index
    @sites = Site.order(:name)
  end

  def show
    @panels = @site.panels.by_position
    @panel_status_summary = @site.panel_status_summary
    @recent_revenues = @site.revenues.chronological.last(6)
  end

  def new
    @site = Site.new
  end

  def create
    @site = Site.new(site_params)
    if @site.save
      generate_panels_for(@site)
      session[:current_site_id] = @site.id
      redirect_to dashboard_path(site_id: @site.id), notice: "発電所「#{@site.name}」を登録しました"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @site.update(site_params)
      redirect_to site_path(@site), notice: "発電所情報を更新しました"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @site.destroy
    session.delete(:current_site_id) if session[:current_site_id] == @site.id
    redirect_to sites_path, notice: "発電所を削除しました"
  end

  private

  def find_site
    @site = Site.find(params[:id])
  end

  def site_params
    params.require(:site).permit(:name, :location, :panel_count, :capacity_kw, :status, :description)
  end

  def generate_panels_for(site)
    count = site.panel_count.clamp(1, 200)
    cols = Math.sqrt(count).ceil
    panels = count.times.map do |i|
      {
        site_id: site.id,
        number: format("P%03d", i + 1),
        position_x: i % cols,
        position_y: i / cols,
        status: "normal",
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    Panel.insert_all(panels)
  end
end