Rails.application.routes.draw do
  root "pages#home"

  get  "dashboard",   to: "dashboard#show", as: :dashboard
  get  "switch_site", to: "dashboard#show", as: :switch_site

  resources :sites
  resources :inspections, only: %i[index show new create destroy] do
    resources :inspection_images, only: %i[update], path: "images" do
      member do
        patch :exclude
        patch :unexclude
        delete :rgb, action: :remove_rgb
      end
    end
    resources :weather_readings, only: %i[create destroy]
  end
  resources :rule_sets, only: %i[index show new create] do
    member { patch :activate }
  end
  resources :revenues,    only: %i[index new create edit update]
  resources :alerts,      only: %i[index update] do
    collection do
      post :mark_all_read
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
