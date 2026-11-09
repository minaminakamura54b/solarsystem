# 報告書の PDF（ferrum_pdf。docs/IMPROVEMENT_PLAN.md Phase 7）。
# - Chromium のサンドボックスは外さない（"no-sandbox" を browser_options に入れない。FERRUM_CHROME_DOCKERIZE も使わない）。
#   Docker では config/seccomp/chromium.json で動かす（config/seccomp/README.md）
# - ブラウザの場所は Ferrum が探す（Mac は Google Chrome、Docker は chromium）。違う場所なら環境変数 BROWSER_PATH
# - 報告書の HTML には外部のものを入れないので、JavaScript は動かさない
FerrumPdf.configure do |config|
  config.process_timeout = 30
  config.page_options.javascript_enabled = false
  config.page_options.wait_for_idle_options = { timeout: 30 }
end
