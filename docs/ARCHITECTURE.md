# ARCHITECTURE（現状）

Phase 0 時点（2026-09-27、ブランチ `phase-0`）のコードを読んでまとめた、**現在の**構成です。移行後の設計は [IMPROVEMENT_PLAN.md](IMPROVEMENT_PLAN.md) を参照してください。

---

## 1. 全体像

```
ブラウザ（Turbo / Stimulus）
   │
   ▼
Rails 8.1（Puma）
   ├─ ApplicationController   発電所の選択（params[:site_id] → session → Site.first）
   ├─ 各コントローラー         dashboard / sites / inspections / alerts / revenues / pages
   ├─ AnalyzePanelImageJob     開発: :inline（リクエスト内で同期実行）/ 本番: Solid Queue（Puma 内）
   │     └─ ClaudePanelAnalyzer → Claude API（vision）
   ├─ PostgreSQL               本番は primary / cache / queue / cable の4DB
   └─ Active Storage           開発: storage/、テスト: tmp/storage/（:test）、本番: storage/（Docker ボリューム）
```

- 認証なし。どの発電所のデータも誰でも閲覧・操作できる
- 画面の選択中の発電所は session に保持。未選択なら `Site.first`

## 2. 画面とルーティング

| パス | コントローラー | 内容 |
|---|---|---|
| `/` | `pages#home` | トップページ（レイアウトなし） |
| `/dashboard` | `dashboard#show` | パネルマップ、状態別件数、未読アラート、直近の点検、点検数と売電のグラフ |
| `/switch_site` | `dashboard#show` | 発電所の切り替え（`site_id` を渡す） |
| `/sites` | `sites` | 発電所の CRUD。**作成時にパネルを自動生成する**（枚数から √n 列の格子で配置。実配置ではない） |
| `/inspections` | `inspections` | 点検の一覧・詳細・新規（画像1枚）・削除。詳細は JSON でステータスも返す |
| `/alerts` | `alerts` | アラート一覧、既読化（Turbo Stream）、一括既読 |
| `/revenues` | `revenues` | 月別の発電量・売電額の登録・編集、年別グラフ |
| `/up` | `rails/health#show` | ヘルスチェック |

## 3. データモデル

```
Site ─┬─< Panel
      ├─< Inspection ──< Alert
      ├─< Alert >── Panel（任意）
      └─< Revenue
```

| モデル | 主な項目・制約 |
|---|---|
| `Site` | name・location 必須、status は `active` / `inactive` / `maintenance` |
| `Panel` | number（発電所内で一意）、position_x / position_y、status は `normal` / `warning` / `error` / `stopped`、last_inspected_at |
| `Inspection` | conducted_at 必須、analysis_status は `pending` / `analyzing` / `completed` / `failed`、severity は `normal` / `warning` / `critical`（**常に必須**。DB も `null: false, default: "normal"`）、anomalies（**json**）、anomaly_count、result、report、画像1枚（`has_one_attached :image`） |
| `Alert` | title 必須、severity は `info` / `warning` / `critical`、read_at |
| `Revenue` | year / month（発電所・年内で一意）、kwh、amount_yen |

## 4. 解析フロー

```
1. /inspections/new で画像を1枚選んで送信（upload_form_controller.js はプレビューのみ）
2. InspectionsController#create
     Inspection を保存（画像は必須ではない）→ AnalyzePanelImageJob.perform_later
     → 詳細画面へリダイレクト
3. AnalyzePanelImageJob#perform
     analysis_status = analyzing
     → ClaudePanelAnalyzer#analyze
          画像を Base64 化 → Claude（モデル名はコード内に固定、max_tokens 1024）
          → 返答テキストから正規表現で JSON を抜き出して JSON.parse
     → analysis_status = result[:error] ? failed : completed
       severity / anomaly_count / anomalies / result / report を保存
     → 発電所の全パネルの last_inspected_at を更新（成功・失敗に関係なく）
     → anomaly_count > 0 なら
          Alert を1件作成
          異常の k 番目を by_position の k 番目のパネルに割り当て、status を warning / error に変更
4. 詳細画面
     analyzing のときだけ auto_refresh_controller.js が3秒ごとに JSON を取得し、
     analyzing 以外になったらページを再読み込み
```

開発環境はジョブが `:inline` のため、手順3はアップロードのリクエスト内で同期実行されます（リダイレクト時には解析が終わっている）。自動更新が意味を持つのは本番（Solid Queue）だけです。

## 5. 既知の問題

[IMPROVEMENT_PLAN.md のセクション0](IMPROVEMENT_PLAN.md) の一覧はすべて実コードと一致しました。以下は Phase 0 で**追加で見つかった**ものです。いずれも `test/` の「現状: …」テストで挙動を記録してあります。

| # | 問題 | 場所 | 対応 |
|---|---|---|---|
| A | **GET の詳細表示で DB に書き戻す。** `result` が JSON 文字列で `anomalies` が空のとき、JSON を読み直して anomalies / anomaly_count / severity を保存する。JSON に severity が無ければ `normal` で上書きする（warning の点検が normal になりうる） | `InspectionsController#show` | Phase 1（読み取り専用にする） |
| B | **severity が常に必須。** validation が `normal` / `warning` / `critical` のいずれかを要求するため、Phase 1 で失敗時に `nil` を保存するとエラーになる | `Inspection` | Phase 1（completed のときだけ必須にする） |
| C | **pending の自動更新は JS 側にも問題がある。** 画面側で pending に自動更新を付けても、JS は「analyzing 以外になったら再読み込み」なので、pending のままだと3秒ごとに再読み込みを繰り返す | `auto_refresh_controller.js` | Phase 1-6 で JS も直す（pending / analyzing の間は再読み込みしない） |
| D | 画像なしでも点検を作成でき、解析ジョブが登録される（ジョブ側で failed になる） | `InspectionsController#create` | Phase 1-9（前倒し） |
| E | ジョブの途中で例外が起きると、`update!` 済みの項目とアラート作成・パネル更新の途中状態が混在しうる（トランザクションなし） | `AnalyzePanelImageJob` | Phase 1-10（前倒し） |
| F | 発電所作成時にパネルを格子状に自動生成しており、位置は実配置と無関係 | `SitesController#generate_panels_for` | Phase 2（`panels` の拡張）で扱いを決める |
| G | モデル名 `claude-opus-4-7` がコード内に固定 | `ClaudePanelAnalyzer::MODEL` | Phase 6（`CLAUDE_MODEL`） |
| H | `PagesController` に存在しない `authenticate_user!` の skip が残っている（`raise: false` のため無害） | `PagesController` | Phase 8 の認証導入時に整理 |

## 6. テスト

- `bin/rails test`: 50件（Phase 0 時点）。services / jobs / controllers / models と主要画面のスモークテスト
- Claude API は呼ばない。`ClaudePanelAnalyzer.new(inspection, client:)` またはクラスレベルの `ClaudePanelAnalyzer.default_client` に偽クライアント（`test/support/fake_anthropic_client.rb`）を渡す。ジョブ経由の場合は `with_fake_claude(client) { ... }` を使う。本番では両方とも nil で、従来どおり `ANTHROPIC_API_KEY` からクライアントを作る
- テスト用画像は合成の 8x8 PNG（`test/fixtures/files/panel.png`）。顧客画像は使わない
- Active Storage はテストで `:test` サービス（`tmp/storage/`）を使う
- テスト名が「現状: …（Phase N で…に変更）」のものは、修正前の問題のある挙動を記録したもの。該当フェーズで期待値を反転させる
