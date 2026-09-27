# CHANGELOG

## 2026-09-27 — Phase 1: 安全修正（ブランチ `phase-1`）

### 変更
- **解析失敗を normal（正常）として保存しない**
  - マイグレーション: `inspections.severity` の NOT NULL とデフォルト `normal` を外し、`error_message` を追加。既存の `failed` の点検は severity を NULL にする（開発 DB では9件が対象）
  - `Inspection`: severity は completed のときだけ必須。nil は「判定なし」（グレーのバッジ）
  - `ClaudePanelAnalyzer`: 失敗の経路（壊れた JSON・途中で切れた応答・JSON なし・severity の欠落や想定外の値・API エラー・例外・画像なし）はすべて `error` 付き・`severity: nil`
- **失敗時にパネル・アラートを変更しない**。`failed` への更新はトランザクションの外で `update_columns`（`updated_at` も更新）
- **ジョブの保存処理をトランザクション化**（結果保存・`last_inspected_at` 更新・アラート作成）。途中で失敗したら何も残さない
- **並び順によるパネル status の割り当てを削除**
- **アラートは1つの点検につき1件**。再解析で更新し、重大度が上がったら未読に戻す。再解析の失敗・異常0件では既存のアラートを変更しない
- **点検詳細を読み取り専用に**（GET で DB に書き戻し、normal で上書きしていた処理を削除）
- **pending でも自動更新**（画面と JS の両方。JS は pending / analyzing の間は再読み込みしない）
- **画像なしの点検は作成不可**（422、解析ジョブも登録しない）
- 失敗時の詳細画面に `error_message` と「正常とは限りません」を表示。ダッシュボードの直近の点検で、完了していない点検の重要度を表示しない
- テスト: 「現状: …」の18件を反転し、72件に（トランザクション・アラート方針・読み取り専用などを追加）

### 見送り
- 送信前の画像縮小（Phase 1 の項目 11）。現行の Claude 方式は実案件に使わないため

### 記録した既知の問題
- I: ワーカーが落ちると `analyzing` のまま残る → Phase 4 にタイムアウト処理として追記
- J: `anomaly_count` が無い・食い違う応答でアラートが出ないことがある → 判定ロジックのため未対応

### 確認したこと
- 開発 DB のアラートに、同じ点検への重複はない（アラート8件・重複0件）。本番 DB は未確認

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
