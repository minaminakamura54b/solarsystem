# ARCHITECTURE（現状）

Phase 0 時点（2026-09-27）のコードを読んでまとめ、Phase 1・Phase 2（ブランチ `phase-2`）の変更を反映した、**現在の**構成です。移行後の設計は [IMPROVEMENT_PLAN.md](IMPROVEMENT_PLAN.md) を参照してください。

---

## 1. 全体像

```
ブラウザ（Turbo / Stimulus / Active Storage 直接アップロード）
   │
   ▼
Rails 8.1（Puma）
   ├─ ApplicationController   発電所の選択（params[:site_id] → session → Site.first）
   ├─ 各コントローラー         dashboard / sites / inspections / inspection_images / weather_readings /
   │                           rule_sets / alerts / revenues / pages
   ├─ ジョブ                   開発: :inline（リクエスト内で同期実行）/ 本番: Solid Queue（Puma 内）
   │     ├─ ProcessInspectionImageJob     画像ごとのメタデータ読み取り（exiftool）→ 気象データ割り当て → 品質チェック
   │     ├─ RecheckInspectionQualityJob   気象データの変更後に、全画像の気象データ割り当てと品質チェックをやり直す
   │     └─ AnalyzePanelImageJob          旧方式（Claude の画像判定）。Phase 2 以降は新しい点検では登録しない
   ├─ exiftool（コマンド）     EXIF / XMP / メーカー独自タグの読み取り。gem は使わない
   ├─ PostgreSQL               本番は primary / cache / queue / cable の4DB
   └─ Active Storage           開発: storage/、テスト: tmp/storage/（:test）、本番: storage/（Docker ボリューム）
```

- 認証なし。どの発電所のデータも誰でも閲覧・操作できる
- 画面の選択中の発電所は session に保持。未選択なら `Site.first`
- 解析エンジン（`analyzer/`、Python）は Phase 3 で作成し、Phase 4 で接続する。それまで新しい点検は品質チェックまでで止まる

## 2. 画面とルーティング

| パス | コントローラー | 内容 |
|---|---|---|
| `/` | `pages#home` | トップページ（レイアウトなし） |
| `/dashboard` | `dashboard#show` | パネルマップ（仮配置なら注記）、状態別件数、未読アラート、直近の点検、グラフ |
| `/switch_site` | `dashboard#show` | 発電所の切り替え（`site_id` を渡す） |
| `/sites` | `sites` | 発電所の登録・編集・削除（モジュール仕様を含む）。作成時にパネルを**仮配置**で自動生成する。詳細画面（show）のビューは無い |
| `/inspections` | `inspections` | 点検の一覧・詳細・新規（複数画像）・削除。詳細は JSON でステータス（`in_progress` を含む）も返す |
| `/inspections/:id/images/:id` | `inspection_images` | RGB の手動添付・差し替え・削除、画像の除外・除外の取り消し |
| `/inspections/:id/weather_readings` | `weather_readings` | 気象データ（時刻付き）の登録・削除 |
| `/rule_sets` | `rule_sets` | 判定基準（閾値）の一覧・詳細・複製して作成・有効化。**編集・削除は無い** |
| `/alerts` | `alerts` | アラート一覧、既読化（Turbo Stream）、一括既読 |
| `/revenues` | `revenues` | 月別の発電量・売電額の登録・編集、年別グラフ |
| `/up` | `rails/health#show` | ヘルスチェック |

## 3. データモデル

```
Site ─┬─< Panel
      ├─< Inspection ─┬─< InspectionImage ─┬─< Anomaly（Phase 4 以降）
      │               │                    └─< AnomalyGroup（Phase 4 以降）
      │               ├─< WeatherReading
      │               ├─< GridTemplate（UI は Phase 4）
      │               └─< Alert
      ├─< Alert >── Panel（任意）
      └─< Revenue

RuleSet ──< SeverityRule（閾値。Anomaly / AnomalyGroup が判定時のルールセットを参照する）
```

| モデル | 主な項目・制約 |
|---|---|
| `Site` | name・location 必須、status。モジュール仕様: module_model、module_rated_w、cell_layout（full_cell / half_cut / other）、substring_count（既定 3）、bypass_pattern（JSON）。specific_yield_kwh_per_kw・fit_price_yen_per_kwh（任意、Phase 7 で使用） |
| `Panel` | number（発電所内で一意）、position_x / position_y、status、last_inspected_at、row_number / string_number / position_in_string / GPS（任意）、**layout_source**（`auto` = 自動生成の仮配置 / `manual` = 実配置） |
| `Inspection` | conducted_at、analysis_status（`pending` / `analyzing` / `completed` / `needs_review` / `failed`）、severity（completed のときだけ必須。それ以外は NULL =「判定なし」）、error_message、weather_note、review_reason、reviewed_at、report_pdf（Phase 7）。旧方式の項目: legacy_anomalies（**旧 anomalies**。読み取り専用）、anomaly_count、result、report、image（画像1枚） |
| `InspectionImage` | thermal（R-JPEG 原本。変換・縮小しない）、rgb（任意）、sequence、thermal_filename、メタデータ（captured_at、camera_model、width / height、GPS、altitude_m、gimbal_pitch / gimbal_yaw、metadata JSON）、is_radiometric（**メタデータによる仮判定**。NULL = 判定できない）、気象データ（irradiance_w_m2 / irradiance_type / wind / 気温 / 湿度）、quality_report、analysis_status（`pending` / `analyzing` / `completed` / `needs_review` / `failed` / `excluded`）、review_reason、exclusion_note、panel_grids・grid_proposal・raw_analysis・analyzer_version（Phase 3〜4） |
| `WeatherReading` | observed_at、irradiance_w_m2（入力したら irradiance_type = `poa` / `ghi` / `unknown` 必須）、wind_speed_m_s、air_temp_c、humidity |
| `RuleSet` | version（一意）、active（全体で1つ。部分ユニークインデックス）、note、detection_params（JSON。必須キーあり）。**作成後は active 以外変更不可、削除不可** |
| `SeverityRule` | anomaly_type（6種類すべて必須）、measure、normalized_mild / warning / critical、raw_mild / warning / critical（各系列で mild < warning < critical）。**作成後は読み取り専用** |
| `Anomaly` / `AnomalyGroup` / `GridTemplate` | テーブルのみ（書き込みは Phase 4 以降）。項目は IMPROVEMENT_PLAN 4.2〜4.4 のとおり |
| `Alert` | title 必須、severity は `info` / `warning` / `critical`、read_at |
| `Revenue` | year / month（発電所・年内で一意）、kwh、amount_yen |

## 4. 点検の流れ

### 4.1 新方式（Phase 2 以降の点検）

```
1. /inspections/new でサーモ画像と RGB 画像をまとめて選択（Active Storage の直接アップロード）
     upload_form_controller.js がサーバーと同じ規則でペアを一覧表示する
2. InspectionsController#create
     ImagePairing: ファイル名末尾の _T（サーモ）/ _V（RGB）でペアにする（大文字小文字は区別しない）。
       末尾に _T / _V が無いファイルはサーモ画像。対になるサーモ画像が無い RGB は登録しない（通知に表示）
     画像ファイル以外・画像0枚は 422。Inspection と InspectionImage を保存
     → 画像ごとに ProcessInspectionImageJob を登録（旧方式の Claude 判定は行わない）
3. ProcessInspectionImageJob（画像1枚ごと）
     exiftool でタグを読む → ImageMetadataExtractor で属性にする
       撮影時刻: OffsetTimeOriginal があればそれ、無ければ capture_time_zone（Asia/Tokyo）の現地時刻として解釈
       温度データ: config/image_quality.yml の radiometric_tags のいずれかがあれば「あり」（仮判定）
     → InspectionImageQuality: 気象データを補間して割り当て → ImageQualityChecker
     → rejected の項目があれば needs_review（review_reason = 最初の rejected 項目）、無ければ pending（解析エンジン待ち）
     → 例外は failed（error_message）。どの場合も正常扱いにはしない
     → Inspection#refresh_status! で点検全体のステータスを集計
4. 気象データの登録・削除（WeatherReadingsController）
     時刻は capture_time_zone の現地時刻として解釈 → RecheckInspectionQualityJob で全画像をやり直す
5. 詳細画面（表示のみ。DB には書き込まない）
     品質チェック待ちの画像がある間だけ自動更新（JSON の in_progress）
     画像ごとに状況・要確認の理由・品質チェックの詳細を表示。要確認・失敗の画像は理由付きで除外できる
```

**品質チェック**（`config/image_quality.yml`、`ImageQualityChecker`）

| 項目 | 結果 |
|---|---|
| 温度データ（メタデータの仮判定） | なし → rejected（`no_radiometric`）、判定できない → rejected（`metadata_unreadable`） |
| 解像度 640×512 以上 | 未満・不明 → rejected（`low_resolution`） |
| 撮影時刻 | 無し → rejected（`missing_captured_at`。気象データを割り当てられないため） |
| GPS | 無し → warning |
| 日射量 | 未入力 → warning、POA で 600 W/m² 未満 → rejected（`low_irradiance`）、GHI・種類不明 → warning（正規化しない） |

**気象データの補間**（`WeatherInterpolator`）: 項目ごとに、撮影時刻の前後 30 分以内で値のある観測値を使う。前後両方あれば線形補間、片方だけなら近い方の値。補間に使った観測値の日射量の種類が食い違えば `unknown`。

**点検全体のステータス**（`Inspection#aggregated_status`。`excluded` の画像は除く）: pending / analyzing があれば `analyzing` → failed があれば `failed` → needs_review があれば `needs_review` → すべて completed なら `completed`。すべて除外なら `needs_review`。`refresh_status!` は、severity の判定が必要な `completed` にはしない（Phase 4 で実装）。一覧・詳細では、品質チェック済みで解析エンジン待ちの画像だけなら「解析待ち（解析エンジン未接続）」と表示する。

### 4.2 旧方式（Phase 1 までの点検。表示のみ）

`inspection_images` を持たない点検は旧方式（`Inspection#legacy?`）として、`inspections/_legacy.html.erb` で従来どおり表示する（DB には書き込まない）。新しく作る手段は無い。`AnalyzePanelImageJob` / `ClaudePanelAnalyzer` はコードとして残っている（Phase 6 で `AnomalyExplainer` に置き換え）。結果は `legacy_anomalies` に保存する。

**アラートの方針**（旧方式のジョブ）: 1つの点検につき1件。再解析で異常があれば更新し、重大度が warning → critical に上がったら未読に戻す。再解析の失敗・異常0件では既存のアラートを変更も削除もしない。

## 5. 既知の問題

[IMPROVEMENT_PLAN.md のセクション0](IMPROVEMENT_PLAN.md) の #2〜#6 は Phase 1、#8（1点検1画像）は Phase 2 で対応済み。以下は Phase 0 以降に**追加で見つかった**ものです。

| # | 問題 | 場所 | 対応 |
|---|---|---|---|
| A〜E | show の DB 書き戻し、severity の常時必須、pending の自動更新、画像なしの点検作成、ジョブのトランザクション | — | **Phase 1 で対応済み** |
| F | 発電所作成時にパネルを格子状に自動生成しており、位置は実配置と無関係 | `SitesController#generate_panels_for` | **Phase 2 で対応済み**（ユーザー承認: 仮配置として残す）。`panels.layout_source` を追加し、既存・新規とも `auto`。ダッシュボードとフォームに「仮配置」と表示。実配置の登録手段（CSV 取込など）は未実装で、後のフェーズで検討 |
| G | モデル名 `claude-opus-4-7` がコード内に固定 | `ClaudePanelAnalyzer::MODEL` | Phase 6（`CLAUDE_MODEL`） |
| H | `PagesController` に存在しない `authenticate_user!` の skip が残っている（無害） | `PagesController` | Phase 8 の認証導入時に整理 |
| I | ワーカーが途中で落ちると `analyzing` のまま残り、自動更新が止まらない。Phase 2 では、品質チェックのジョブが落ちた画像も `pending`（品質チェック待ち）のまま残り、同様に自動更新が止まらない | `AnalyzePanelImageJob` / `ProcessInspectionImageJob` / `auto_refresh_controller.js` | Phase 4-9（タイムアウト処理）。品質チェック待ちのまま残った画像も対象に含める |
| J | Claude の応答の件数・重大度・異常一覧の食い違い | `ClaudePanelAnalyzer#parse_response` | **Phase 1 で対応済み** |
| K | **アプリのタイムゾーンが UTC のまま。** 点検日時などの表示は UTC。撮影時刻と気象データの時刻だけは `config/image_quality.yml` の `capture_time_zone`（Asia/Tokyo）で解釈・表示している | `config/application.rb` | 未対応（アプリ全体の表示が変わるため、指示を受けて対応） |
| L | 発電所の詳細画面（`sites/show`）のビューが無く、更新後の `site_path` へのリダイレクトでエラーになっていた | `SitesController#update` | **Phase 2 で最小限の修正**（更新後は発電所一覧に戻す）。詳細画面は未作成 |
| N | 発電所フォームの `defined?(method)` が Ruby 組み込みの `method` メソッドを指し、**新規登録画面が開けなかった**（Phase 2 以前から） | `sites/_form.html.erb` | **Phase 2 で修正**（`local_assigns.fetch(:method, :post)`） |
| M | 温度データの有無はメタデータのタグによる仮判定。実際の R-JPEG でどのタグが出るかは未確認 | `config/image_quality.yml` の `radiometric_tags` | Phase S で実画像を確認して見直す。最終判定は Phase 3 の解析エンジン |

## 6. テスト

- `bin/rails test`: 177件（Phase 2 時点）。services / jobs / controllers / models と主要画面のスモークテスト
- Claude API は呼ばない。`ClaudePanelAnalyzer.default_client` に偽クライアントを渡す（`with_fake_claude`）
- exiftool は**実際に動かす**テストと、**偽の読み取りクラスに差し替える**テストがある。本物の R-JPEG の熱画像タグは exiftool で書き込めないため、温度データありの場合は `ProcessInspectionImageJob.exif_reader` を `with_fake_exif(tags:)` で差し替える（本番では常に `ExifReader`）。開発機・CI とも exiftool が必要（CI は apt で導入）
- テスト用画像はすべて合成: `panel.png`（8×8）、`thermal_plain_T.jpg`（640×512、EXIF あり・温度データなし）、`lowres_T.jpg`（320×256）、`rgb_V.jpg`、`memo.txt`（画像以外）。顧客画像は使わない
- 受け入れ確認「温度データの無い JPEG が needs_review（no_radiometric）になり、理由が画面に表示される」は、実際の exiftool を使うジョブのテストと結合テストで確認している
- Active Storage はテストで `:test` サービス（`tmp/storage/`）を使う
- トランザクションのテストは、アラート作成で例外を起こすジョブのサブクラスをテスト内だけで定義して使う
