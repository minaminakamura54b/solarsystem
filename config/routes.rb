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
    # 架台の登録（架台の CSV。docs/LAYOUT_OVERLAY_DESIGN.md の A）
    resource :block_layout, only: %i[new create] do
      post :preview
      get :template
      get :export
    end
    # 発電所ごとの部材の位置（案 A）。一覧と削除だけ（登録はパネルごとの候補の「部材・構造物」の却下から）
    resources :structure_positions, only: %i[index destroy]
    # 点検の画像から作る架台の地図の候補（docs/LAYOUT_OVERLAY_DESIGN.md の A-3）
    resources :block_map_proposals, only: %i[create show] do
      get :csv, on: :member
    end
  end
  resources :inspections, only: %i[index show new create destroy] do
    # パネルごとの候補（同じパネルの同じ場所の異常をまとめたもの。docs/LAYOUT_OVERLAY_DESIGN.md の C-1）
    resource :panel_review, only: :show do
      post :rebuild
      post :bulk_reject
    end
    resources :panel_candidates, only: [], controller: "panel_reviews" do
      member do
        post :confirm
        post :reject
      end
    end
    # 点検の対象範囲（見直し R1）
    resource :scope, only: %i[show update destroy], controller: "inspection_scopes"
    # 報告書の版（Phase 7）
    resources :reports, only: %i[index show create] do
      get :preview, on: :collection
      member do
        get :pdf
        post :regenerate_pdf
      end
    end
    # 要確認・失敗の画像を理由ごとにまとめて除外する（Phase 7）
    resource :bulk_exclusion, only: %i[show create]
    # 架台・段の候補（案 X 改）
    resources :block_row_findings, only: [], controller: "panel_reviews" do
      member do
        post :confirm_row
        post :reject_row
      end
    end
    member do
      post :rejudge
      get :review
      post :complete_review
      post :explain
      patch :measurement
      patch :claude_setting
      patch :findings
      patch :report_settings
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
