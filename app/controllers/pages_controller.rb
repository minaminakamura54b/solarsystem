class PagesController < ApplicationController
  skip_before_action :authenticate_user!, raise: false

  def home
    render layout: false
  end
end
