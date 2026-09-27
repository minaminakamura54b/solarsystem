# CHANGELOG

## 2026-09-27 — Phase 0: 土台づくり（ブランチ `phase-0`）

### 追加
- `docs/ARCHITECTURE.md`: 現状の構成・画面・データモデル・解析フロー・既知の問題（指示書に無かった A〜H を含む）
- テストの土台（それまでテストは0件）
  - fixtures（site / panel / inspection / alert）と合成の 8x8 PNG
  - 偽クライアント `FakeAnthropicClient` と `with_fake_claude` ヘルパー
  - 現状の挙動テスト 50件（services / jobs / controllers / models / 主要画面のスモーク）
  - Phase 1 で直す挙動は「現状: …（Phase 1 で…に変更）」の名前で記録
- `docs/CHANGELOG.md`（このファイル）

### 変更
- `ClaudePanelAnalyzer`: `client:` 引数とクラスレベルの `default_client` を追加（テストで偽クライアントを差し込むため）。本番は両方 nil で挙動は変わらない
- `.gitignore`: `.env.example` をコミット対象にし、`analyzer/bin/`（DJI SDK）と `tmp/spike/`（検証用の実画像）を除外対象に追加
- `.env.example`: `CLAUDE_MODEL` と `DJI_IRP_PATH` を追加
- `README.md`: 環境変数の手順を `.env.example` のコピーに変更、テストとブランチ運用の説明を追加
- `docs/IMPROVEMENT_PLAN.md`: Phase 1 に「show の読み取り専用化」「severity の validation を completed のときだけ必須に」「自動更新の JS 側の修正」を追記。既知の問題 D（画像なしの点検作成）と E（ジョブのトランザクション）を Phase 1 に前倒し
- `Gemfile.lock`: brakeman を 8.0.4 → 8.0.6 に更新（`bin/brakeman` の `--ensure-latest` で終了コード 5 になり CI が失敗していたため）

### 確認したこと
- git の全履歴に `.env`・`config/master.key`・API キーらしき文字列のコミットはない（`config/credentials.yml.enc` は暗号化済みのファイルで問題なし）
- テスト環境の Active Storage は `:test` サービス（`tmp/storage/`）を使う設定になっている
