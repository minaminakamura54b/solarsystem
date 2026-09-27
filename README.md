# SolarSight AI（solarsystem）

ドローンで撮影した太陽光パネルのサーモ（赤外線）画像から熱異常をスクリーニングし、発電所ごとの点検結果・アラート・売電実績を管理する Rails アプリケーションです。

> **移行中です。** 現在の解析は「Claude に画像を見せて判定させる方式」で、温度を測っていないため精度に根本的な限界があります。これを「放射温度データ ＋ ルール判定 ＋ 人の確認」方式に作り替えています。計画と仕様は [docs/IMPROVEMENT_PLAN.md](docs/IMPROVEMENT_PLAN.md) を参照してください。

---

## 主な機能（現在）

| 機能 | 内容 |
|---|---|
| 発電所管理 | 発電所（Site）の登録・編集。所在地、容量（kW）、パネル枚数 |
| パネルマップ | パネルの配置と状態（正常・注意・異常・停止）を表示 |
| 点検 | 画像をアップロードすると AI 解析を実行し、重大度・異常一覧・レポートを表示 |
| アラート | 異常検出時にアラートを作成。既読管理 |
| 売電実績 | 月別の発電量（kWh）と売電額を記録し、グラフ表示 |
| ダッシュボード | 発電所ごとの状況をまとめて表示。画面上で発電所を切り替える |

---

## ワークフロー

### 現在の解析フロー

```
点検画面で画像を1枚アップロード
  → Inspection を作成し AnalyzePanelImageJob を登録
  → ClaudePanelAnalyzer が画像を Claude（vision）へ送信
  → 返答の JSON を保存（重大度・異常一覧・レポート）
  → 異常があればアラートを作成
  → 解析中の画面は3秒ごとに自動更新
```

現行方式には既知の問題があります（解析失敗が「正常」として保存される、異常がパネルに正しく紐付かない など）。一覧は [docs/IMPROVEMENT_PLAN.md のセクション0](docs/IMPROVEMENT_PLAN.md) にあり、Phase 1 で修正します。

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
- 予定: Python 3.11+ の解析エンジン（numpy / OpenCV / pydantic）、DJI Thermal SDK、exiftool

### ディレクトリ

```
app/
  controllers/     dashboard, sites, inspections, alerts, revenues, pages
  models/          Site, Panel, Inspection, Alert, Revenue
  services/        claude_panel_analyzer.rb（現行の AI 解析）
  jobs/            analyze_panel_image_job.rb（現行の解析ジョブ）
  javascript/controllers/
                   auto_refresh_controller.js（解析中の自動更新）
                   upload_form_controller.js（アップロードフォーム）
                   flash_controller.js
config/            ルーティング、環境設定、deploy.yml（Kamal）、ci.rb
db/                schema.rb、migrate/、seeds.rb（サンプル発電所2件）
docs/              改善指示書など
test/              テスト（Claude API は偽クライアントに差し替えて実行）
analyzer/          Python 解析エンジン（Phase 3 で作成予定）
```

### データモデル（現在）

| テーブル | 主な項目 |
|---|---|
| `sites` | 発電所名、所在地、容量（kW）、パネル枚数、状態 |
| `panels` | 発電所、パネル番号、配置座標（x, y）、状態、最終点検日時 |
| `inspections` | 発電所、点検日時、解析ステータス、重大度、異常一覧、レポート。画像1枚を添付 |
| `alerts` | 発電所、点検、パネル、タイトル、重大度、既読日時 |
| `revenues` | 発電所、年月、発電量（kWh）、売電額（円） |

移行後に追加するテーブル（`inspection_images`、`anomalies`、`anomaly_groups`、`grid_templates`、`rule_sets`、`severity_rules`）は [docs/IMPROVEMENT_PLAN.md のセクション4](docs/IMPROVEMENT_PLAN.md) を参照してください。

---

## セットアップ

### 必要なもの

- Ruby 3.3.10
- PostgreSQL
- libvips（画像処理）
- Anthropic API キー

### 手順

```bash
git clone <このリポジトリ>
cd solarsystem

# 環境変数を設定（下表）
cp .env.example .env   # ANTHROPIC_API_KEY などを記入

bin/setup    # gem のインストール、DB の作成・マイグレーション、サーバー起動
```

サンプルデータ（発電所2件とパネル）は `bin/rails db:seed` で作成できます。

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
