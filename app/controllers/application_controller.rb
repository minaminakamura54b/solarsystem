class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  stale_when_importmap_changes

  before_action :set_current_site
  before_action :set_sites

  helper_method :current_site

  private

  def set_sites
    @sites = Site.order(:name)
  end

  def set_current_site
    if params[:site_id].present?
      @current_site = Site.find(params[:site_id])
      session[:current_site_id] = @current_site.id
    elsif session[:current_site_id].present?
      @current_site = Site.find_by(id: session[:current_site_id])
    end
    @current_site ||= Site.first
  end

  def current_site
    @current_site
  end
end
