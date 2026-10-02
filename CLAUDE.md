# CLAUDE.md

太陽光パネルのサーモ（赤外線）画像から熱異常をスクリーニングする Rails アプリ（画面上の名称: SolarSight AI）。

現在は「Claude に画像を見せて判定させる方式」から「放射温度データ ＋ ルール判定 ＋ 人の確認」方式へ移行中。
**作業の前に必ず [docs/IMPROVEMENT_PLAN.md](docs/IMPROVEMENT_PLAN.md) を読むこと。** 仕様・フェーズ・データモデルはすべてそこにある。

## 作業の進め方

- **1セッション＝1フェーズ。** 指示されたフェーズ以外に手を広げない。
- **自律して進めてよい範囲・必ず止まって確認する場面・禁止事項は [docs/IMPROVEMENT_PLAN.md の末尾「作業の進め方（自律して進めてよい範囲）」](docs/IMPROVEMENT_PLAN.md) に従う。** フェーズごとにブランチを作り、テスト・rubocop・brakeman と GitHub Actions がすべて通ったら merge commit で main にマージして push してよい。force push・公開済み履歴の書き換え・main への直接コミットは禁止。
- 「止まって確認する場面」に当たるときは、実装計画を提示して承認を待つ。**ユーザーの指示と違う方法や、指示より広い範囲で実装しようとするときも同じ**（例: 指示された修正に、関連する別の条件まで加える場合）。
- 指示書と実コードが食い違っていたら、実装せずに報告する。
- CLAUDE.md・指示書・依頼内容が矛盾したら、指示書の「設計原則」を優先し、矛盾点を報告する。
- 仕様に迷ったら実装せずに質問する。特に **判定ロジックの追加、閾値の変更、パネルへの自動割り当て** は指示なく行わない。
- 小さくコミットする。コミットメッセージは日本語で「何を・なぜ」。
- 変更内容を `docs/CHANGELOG.md` に日付付きで追記する。

## 絶対に守ること（点検アプリとしての安全性）

1. **解析失敗・API エラー・パース失敗・データ不足を `normal`（正常）として保存するコードを書かない。** 必ず `failed` または `needs_review`。`severity` を「とりあえず normal」で埋めない。
2. **失敗した処理で Panel や Site の状態を変更しない**（`last_inspected_at`、`status` を含む）。
3. **異常か正常かの判定は温度データとルールで行う。Claude には判定させない。** Claude の役割は、確定済みの数値から所見・原因候補・推奨対応・報告文を書くことだけ。Claude の出力に severity が含まれていても使わない。
4. **パネルへの紐付けは位置情報か人の指定でのみ行う。** 並び順などによる機械的な割り当ては禁止。
5. **人が確定・修正・却下した異常（`locked`）を自動で書き換えない。** 閾値を変えても確定済みの severity は変わらない。
6. **確信度（%）を表示・保存しない。** 代わりに証拠レベル（A/B/C）を使う。
7. **閾値・モデル名・パスをハードコードしない。** 閾値は DB のルールセット、モデル名は `CLAUDE_MODEL`、SDK のパスは `DJI_IRP_PATH`。
8. **報告書に個人名を載せない。** 会社名・屋号のみ。
9. **コミットしないもの**: 秘密情報（`.env`、`config/*.key`）、DJI Thermal SDK のバイナリ（`analyzer/bin/`）、顧客の画像。テストには合成データを使う。
10. R-JPEG の原本は変換・縮小・削除しない。Claude に送る場合は派生画像を作る。

## コマンド

```bash
bin/setup                 # 依存関係のインストールと DB 準備
bin/dev                   # 開発サーバー起動（http://localhost:3000）
bin/rails test            # テスト
bin/rubocop               # Lint（rubocop-rails-omakase）
bin/brakeman --no-pager   # セキュリティ静的解析
bin/ci                    # 上記をまとめて実行（config/ci.rb）
cd analyzer && uv run pytest   # 解析エンジン（Python 3.12・uv）のテスト
```

各タスクの完了時に `bin/rails test`、`bin/rubocop`、`bin/brakeman`（Python を変更したら `pytest` も）を実行し、結果を報告する。

## 技術スタックと注意点

- Rails 8.1 / Ruby 3.3.10 / PostgreSQL / Propshaft / importmap / Turbo / Stimulus
- **exiftool が必要**（画像のメタデータ読み取り。テストでも実際に使う）。gem は使わず `ExifReader` がコマンドを呼ぶ
- 品質チェックの閾値・温度データの手がかりにするタグ・撮影時刻のタイムゾーンは `config/image_quality.yml`。重大度の閾値は DB のルールセット（初期値は `db/seeds/rule_sets.rb`）
- ジョブ: 開発は `:inline`（アップロードと同時に同期実行）、本番は `solid_queue`（Puma 内で実行）
- `anthropic` gem 0.4.1 は**非公式 gem**（`Anthropic::Client.new(access_token:)` 形式）。公式 SDK 1.x は同名だが API が別物。移行は Phase 6 で一度だけ行う予定なので、それまで SDK を変えない。
- `inspections.analysis_status` は `pending` / `analyzing` / `completed` / `needs_review` / `failed`、画像（`inspection_images`）はこれに `excluded` が加わる。**`completed` を `analyzed` などに改名しない**。
- 点検には新方式（`inspection_images` を持つ）と旧方式（画像1枚・Claude 判定。`Inspection#legacy?`）がある。旧方式は表示だけで、新しく作らない。旧方式の結果は `legacy_anomalies`（読み取り専用）。
- 本番サーバーは **linux/amd64** 前提（DJI Thermal SDK の制約）。
- マイグレーションは必ず可逆にする。既存データの移行が必要なら rake タスクを分ける。
- UI の文言は日本語。既存の画面構成は極力維持する。

## 主要ファイル

- `app/jobs/process_inspection_image_job.rb` — 画像ごとのメタデータ読み取り・気象データ割り当て・品質チェック
- `app/services/image_quality_checker.rb` ほか — 品質チェック、`ImageMetadataExtractor`、`WeatherInterpolator`、`ImagePairing`
- `app/services/claude_panel_analyzer.rb` / `app/jobs/analyze_panel_image_job.rb` — 旧方式の Claude 画像判定（新しい点検では使わない。Phase 6 で置き換え予定）
- `app/controllers/inspections_controller.rb` — 点検の登録・表示（JSON でステータスを返し、自動更新に使う）
- `app/javascript/controllers/auto_refresh_controller.js` — 解析中画面のポーリング
- `analyzer/` — Python 解析エンジン（Python 3.12・uv。仕様と使い方は analyzer/README.md。Rails からの呼び出しは Phase 4）
- `docs/IMPROVEMENT_PLAN.md` — 改善指示書（仕様の正本）
