require "active_support/core_ext/integer/time"

# 実案件用（ローカル運用。docs/LOCAL_OPERATION.md）。Mac の上で一人で使い、顧客に渡すのは PDF の報告書だけ。
# - bin/local で起動する（RAILS_ENV=work。Rails は "local" という名前を予約しているため work）
# - データベースは開発用と別（solarsystem_work）、画像の置き場所はリポジトリの外（~/SolarSightData/storage）
# - 解析は Solid Queue で裏で並列に動かす（開発の :inline と違い、アップロードの処理の中では解析しない）
# - 画面は 127.0.0.1 だけで開く（ログイン機能が無いため。bin/local が -b 127.0.0.1 で起動する）
Rails.application.configure do
  data_dir = ENV.fetch("SOLARSIGHT_DATA_DIR", File.expand_path("~/SolarSightData"))

  config.enable_reloading = false
  config.eager_load = true

  # 使うのは本人だけ（127.0.0.1）なので、エラーの詳細を画面に出す
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  config.cache_store = :memory_store

  # 画像（原本の R-JPEG・RGB・報告書の PDF）はリポジトリの外に置く（config/storage.yml の work_data）
  config.active_storage.service = :work_data

  # ログもリポジトリの外に置く（ファイル名などの案件の情報を含むため）
  config.paths["log"] = File.join(data_dir, "log", "work.log")
  config.log_level = :info
  config.log_tags = [ :request_id ]

  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # アセットはプリコンパイルせずに配る（Mac の上で動かすため）
  config.assets.server = true
  config.assets.quiet = true

  config.active_support.deprecation = :log
  config.active_record.dump_schema_after_migration = false
  config.active_record.migration_error = :page_load
  config.action_mailer.perform_deliveries = false
  config.action_mailer.default_url_options = { host: "localhost", port: 3000 }
end
