Rails.application.routes.draw do
  root "pages#home"

  get  "dashboard",   to: "dashboard#show", as: :dashboard
  get  "switch_site", to: "dashboard#show", as: :switch_site

  resources :sites do
    # 実配置の登録（CSV）と、割り当て直しが必要な異常の一覧（show）
    resource :panel_layout, only: %i[new create show] do
      post :preview
      get :template
    end
  end
  resources :inspections, only: %i[index show new create destroy] do
    member do
      post :rejudge
      get :review
      post :complete_review
      post :explain
      patch :measurement
    end
    resources :anomalies, only: %i[create] do
      member do
        patch :confirm
        patch :correct
        patch :reject
        patch :assign_panel
        patch :electrical
        patch :remove_from_group
      end
    end
    resources :anomaly_groups, only: [] do
      member do
        patch :confirm
        patch :reject
      end
    end
    resources :inspection_images, only: %i[update], path: "images" do
      member do
        patch :exclude
        patch :unexclude
        delete :rgb, action: :remove_rgb
        get :grid
        patch :grids
        post :reanalyze
      end
    end
    resources :grid_templates, only: %i[create] do
      member { post :apply }
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
