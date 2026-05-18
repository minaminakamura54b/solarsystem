class RevenuesController < ApplicationController
  before_action :require_site

  def index
    year = params[:year]&.to_i || Date.today.year
    @year = year
    @revenues = current_site.revenues.for_year(year).chronological
    @years = current_site.revenues.select(:year).distinct.pluck(:year).sort.reverse
    @years = [ Date.today.year ] if @years.empty?

    @annual_total_yen = @revenues.sum(:amount_yen)
    @annual_total_kwh = @revenues.sum(:kwh)

    @monthly_chart_data = (1..12).map do |m|
      rev = @revenues.find { |r| r.month == m }
      [ "#{m}月", rev&.amount_yen.to_i || 0 ]
    end.to_h
  end

  def new
    @revenue = current_site.revenues.build(year: Date.today.year, month: Date.today.month)
  end

  def create
    @revenue = current_site.revenues.build(revenue_params)
    if @revenue.save
      respond_to do |format|
        format.html { redirect_to revenues_path, notice: "#{@revenue.month_label}の収益を登録しました" }
        format.turbo_stream
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @revenue = current_site.revenues.find(params[:id])
  end

  def update
    @revenue = current_site.revenues.find(params[:id])
    if @revenue.update(revenue_params)
      redirect_to revenues_path, notice: "#{@revenue.month_label}の収益を更新しました"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def revenue_params
    params.require(:revenue).permit(:year, :month, :amount_yen, :kwh)
  end
end