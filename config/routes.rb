Rails.application.routes.draw do
  root "pages#home"

  get  "dashboard",   to: "dashboard#show", as: :dashboard
  get  "switch_site", to: "dashboard#show", as: :switch_site

  resources :sites
  resources :inspections, only: %i[index show new create destroy]
  resources :revenues,    only: %i[index new create edit update]
  resources :alerts,      only: %i[index update] do
    collection do
      post :mark_all_read
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
