# SolarSight AI（solarsystem）

ドローンで撮影した太陽光パネルのサーモ（赤外線）画像から熱異常をスクリーニングし、発電所ごとの点検結果・アラート・売電実績を管理する Rails アプリケーションです。

> **移行中です。** 現在の解析は「Claude に画像を見せて判定させる方式」で、温度を測っていないため精度に根本的な限界があります。これを「放射温度データ ＋ ルール判定 ＋ 人の確認」方式に作り替えています。計画と仕様は [docs/IMPROVEMENT_PLAN.md](docs/IMPROVEMENT_PLAN.md) を参照してください。

---

## 主な機能（現在）

| 機能 | 内容 |
|---|---|
| 発電所管理 | 発電所（Site）の登録・編集。所在地、容量（kW）、パネル枚数、モジュール仕様 |
| パネルマップ | パネルの配置と状態を表示（現在は登録時に自動生成した**仮配置**） |
| 点検 | サーモ画像（R-JPEG）と RGB 画像をまとめてアップロード。画像ごとにメタデータを読み取り、品質チェックを行う。気象データを入力すると撮影時刻に合わせて割り当てる |
| 判定基準 | 重大度の閾値をバージョン管理（ルールセット）。作成後は編集できず、複製して新しいバージョンを作る |
| アラート | 異常検出時にアラートを作成。既読管理 |
| 売電実績 | 月別の発電量（kWh）と売電額を記録し、グラフ表示 |
| ダッシュボード | 発電所ごとの状況をまとめて表示。画面上で発電所を切り替える |

---

## ワークフロー

### 現在の点検フロー（Phase 2 時点）

```
点検画面でサーモ画像と RGB 画像をまとめてアップロード
  → ファイル名の _T / _V でペアにして、画像ごとに登録
  → 画像ごとにメタデータ（撮影時刻・カメラ・位置・温度データの有無）を読み取り、品質チェック
       不合格（温度データなし・低解像度・日射量不足など）→ 要確認（理由を表示）。「正常」にはしない
       合格 → 解析待ち（解析エンジンは Phase 4 で接続）
  → 気象データを入力すると、撮影時刻に合わせて各画像に割り当て、品質チェックをやり直す
  → 要確認の画像は、理由を入力して除外できる
```

旧方式（画像1枚を Claude に判定させる方式）で作った点検は、表示だけできます。新しい点検では Claude の判定は行いません。詳しい流れは [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) を参照してください。

### 移行後の点検ワークフロー

```
1. 点検を作成し、サーモ画像（R-JPEG）と RGB 画像をまとめてアップロード
      ファイル名の _T / _V で自動ペアリング
2. 撮影時の気象データ（日射量 POA/GHI・風速・気温）を入力
3. 品質チェック（自動）
      温度データの有無・解像度・撮影時刻・日射量
      不合格 → 要確認（needs_review）。「正常」にはしない
4. グリッド指定（人）
      画像上でパネル配列の4隅を指定。テンプレートとして保存し、同条件の画像に一括適用
5. 解析（自動・Python 解析エンジン）
      温度行列の取得 → パネルごとの温度 → 基準温度との差（ΔT）→ 発熱パターン分類
      重大度はルールセットの閾値で Rails が付与
6. レビュー（人）
      異常候補を 確定 / 修正 / 却下 / パネル割当。確定したものは以後変わらない
7. 所見の作成（Claude）
      確定済みの数値から原因候補・推奨対応・報告文を作成。判定はしない
8. 影響容量の算出と PDF 報告書の出力
```

---

## 構成

### アーキテクチャ（移行後）

```
ブラウザ ──▶ Rails（画面・データ管理・ジョブ）
               │
               ├─ solid_queue ジョブ
               │    ├─ 品質チェック（EXIF/XMP）
               │    ├─ Python 解析エンジン（analyzer/、CLI を Open3 で呼ぶ）
               │    │     └─ DJI Thermal SDK（R-JPEG → 温度行列）
               │    └─ Claude API（確定済み異常の所見作成のみ）
               │
               ├─ PostgreSQL
               └─ Active Storage（画像原本・PDF）
```

### 技術スタック

- Ruby 3.3.10 / Rails 8.1 / PostgreSQL
- フロントエンド: Propshaft、importmap、Turbo、Stimulus、Chartkick
- ジョブ: 開発は `:inline`（同期実行）、本番は Solid Queue（Puma 内で実行）
- キャッシュ・WebSocket: Solid Cache / Solid Cable（本番）
- AI: Anthropic Claude（現在は非公式の `anthropic` gem 0.4.1。Phase 6 で公式 SDK へ移行予定）
- デプロイ: Kamal（Docker、linux/amd64）
- 解析エンジン: Python 3.12・uv（numpy / OpenCV / pydantic）。`analyzer/`。DJI Thermal SDK の呼び出しは Phase S 後に実装

### ディレクトリ

```
app/
  controllers/     dashboard, sites, inspections, alerts, revenues, pages
  models/          Site, Panel, Inspection, Alert, Revenue
  services/        メタデータ読み取り（exif_reader / image_metadata_extractor）、品質チェック（image_quality_checker）、
                   気象データの補間（weather_interpolator）、ペアリング（image_pairing）、旧方式の claude_panel_analyzer
  jobs/            process_inspection_image_job.rb（画像ごとの品質チェック）、recheck_inspection_quality_job.rb、
                   analyze_panel_image_job.rb（旧方式）
  javascript/controllers/
                   auto_refresh_controller.js（解析中の自動更新）
                   upload_form_controller.js（アップロードフォーム）
                   flash_controller.js
config/            ルーティング、環境設定、image_quality.yml（品質チェックの閾値など）、deploy.yml（Kamal）、ci.rb
db/                schema.rb、migrate/、seeds.rb（サンプル発電所2件）
docs/              改善指示書など
test/              テスト（Claude API は偽クライアントに差し替えて実行）
analyzer/          Python 解析エンジン（使い方は analyzer/README.md。Rails からの呼び出しは Phase 4）
```

### データモデル

| テーブル | 主な項目 |
|---|---|
| `sites` | 発電所名、所在地、容量（kW）、パネル枚数、状態、モジュール仕様 |
| `panels` | 発電所、パネル番号、配置座標（x, y）、状態、最終点検日時、配置の種類（仮配置 / 実配置） |
| `inspections` | 発電所、点検日時、解析ステータス、重大度（未判定は空）、天候メモ。旧方式の結果（`legacy_anomalies` など） |
| `inspection_images` | 点検内の画像1枚ごと。サーモ画像（原本）・RGB、メタデータ、気象データ、品質チェック結果、ステータス |
| `weather_readings` | 点検中の気象の観測値（時刻・日射量と種類・風速・気温・湿度） |
| `rule_sets` / `severity_rules` | 重大度の閾値（ルールセット単位でバージョン管理） |
| `anomalies` / `anomaly_groups` / `grid_templates` | 解析結果とグリッド（テーブルのみ。使うのは Phase 4 以降） |
| `alerts` | 発電所、点検、パネル、タイトル、重大度、既読日時 |
| `revenues` | 発電所、年月、発電量（kWh）、売電額（円） |

各テーブルの詳細は [docs/IMPROVEMENT_PLAN.md のセクション4](docs/IMPROVEMENT_PLAN.md) と [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) を参照してください。

---

## セットアップ

### 必要なもの

- Ruby 3.3.10
- PostgreSQL
- libvips（画像処理）
- exiftool（画像のメタデータ読み取り。macOS: `brew install exiftool`、Debian/Ubuntu: `apt install libimage-exiftool-perl`）
- Anthropic API キー（旧方式の点検の再解析にのみ使用）

### 手順

```bash
git clone <このリポジトリ>
cd solarsystem

# 環境変数を設定（下表）
cp .env.example .env   # ANTHROPIC_API_KEY などを記入

bin/setup    # gem のインストール、DB の作成・マイグレーション、サーバー起動
```

`bin/rails db:seed` で、判定基準（閾値）の初期値と、開発用のサンプルデータ（発電所2件とパネル）を作成します。判定基準の初期値は本番でも必要です（`db/seeds/rule_sets.rb`）。

### 環境変数

`.env.example` をコピーした `.env` に記入します（`.env` はコミットしません）。

| 変数 | 必須 | 用途 |
|---|---|---|
| `ANTHROPIC_API_KEY` | ○ | Claude API キー。未設定だと解析が失敗します |
| `CLAUDE_MODEL` | 予定 | 使用する Claude のモデル名（現在はコード内に固定。Phase 6 で環境変数化） |
| `DJI_IRP_PATH` | 予定 | DJI Thermal SDK の `dji_irp` のパス（Phase 3 以降） |
| `DATABASE_URL` | 本番 | 本番 DB の接続先 |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` / `AWS_BUCKET` | 本番（予定） | S3 への画像保存（Phase 8） |

---

## 開発

```bash
bin/dev                   # 開発サーバー起動（http://localhost:3000）
bin/rails test            # テスト
bin/rubocop               # Lint
bin/brakeman --no-pager   # セキュリティ静的解析
bin/ci                    # Lint・監査・テストをまとめて実行
cd analyzer && uv sync && uv run pytest   # 解析エンジンのテスト（uv が必要）
```

テストは Claude API を呼びません（偽クライアントに差し替え）。仕組みと、テスト名「現状: …」の意味は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) の「テスト」を参照してください。

GitHub Actions（`.github/workflows/ci.yml`）でも brakeman、bundler-audit、importmap audit、rubocop、テストを実行します。

### 開発ルール

- Claude Code で作業するときのルールは [CLAUDE.md](CLAUDE.md) にまとめています。
- 現在の構成と既知の問題は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、変更履歴は [docs/CHANGELOG.md](docs/CHANGELOG.md) にあります。
- フェーズごとにブランチ（`phase-0`、`phase-1` …）を切って作業し、確認後に `main` へマージします。
- 解析失敗やデータ不足を「正常」として保存しないこと、閾値をハードコードしないこと、秘密情報・SDK バイナリ・顧客画像をコミットしないことが特に重要です。

---

## デプロイ

Kamal でデプロイします（`config/deploy.yml`）。

```bash
bin/kamal setup    # 初回
bin/kamal deploy   # 更新
```

- `config/deploy.yml` のサーバーとレジストリは初期値のままです。実際の環境に合わせて設定してください。
- 本番のジョブは Puma 内の Solid Queue で動きます（`SOLID_QUEUE_IN_PUMA: true`）。
- 本番サーバーは linux/amd64 前提です（DJI Thermal SDK の制約）。
- 現在の本番ストレージはローカルディスク（Docker ボリューム）です。顧客公開前に S3 へ切り替えます。
- **認証はまだありません。** 顧客に公開する前に Phase 8 の対応（認証・S3・バックアップ）が必須です。

---

## ロードマップ

| フェーズ | 内容 |
|---|---|
| Phase S | DJI Thermal SDK で温度データが取り出せるかの検証 |
| Phase 0 | 土台づくり（CLAUDE.md、テストの土台、README） |
| Phase 1 | 安全修正（失敗を「正常」にしない、誤ったパネル割り当ての削除 など） |
| Phase 2 | 複数画像の点検セッション、品質チェック、ルールセット |
| Phase 3 | Python 解析エンジン（`analyzer/`） |
| Phase 4 | グリッド入力 UI、Rails と解析エンジンの接続 |
| Phase 5 | レビュー UI、学習データの書き出し |
| Phase 6 | Claude の役割を所見作成に限定、公式 SDK へ移行 |
| Phase 7 | 影響容量の算出、PDF 報告書 |
| Phase 8 | 顧客公開前の対応（認証・S3・バックアップ） |

詳細は [docs/IMPROVEMENT_PLAN.md](docs/IMPROVEMENT_PLAN.md) を参照してください。

---

## 免責

本アプリの解析は赤外線サーモグラフィによる熱異常のスクリーニングであり、確定診断ではありません。
