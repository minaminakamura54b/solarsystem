# ARCHITECTURE（現状）

Phase 0 時点（2026-09-27）のコードを読んでまとめ、Phase 1〜6（ブランチ `phase-6`）の変更を反映した、**現在の**構成です。移行後の設計は [IMPROVEMENT_PLAN.md](IMPROVEMENT_PLAN.md) を参照してください。

---

## 1. 全体像

```
ブラウザ（Turbo / Stimulus / Active Storage 直接アップロード）
   │
   ▼
Rails 8.1（Puma）
   ├─ ApplicationController   発電所の選択（params[:site_id] → session → Site.first）
   ├─ 各コントローラー         dashboard / sites / inspections / inspection_images / grid_templates /
   │                           weather_readings / rule_sets / alerts / revenues / pages
   ├─ ジョブ                   開発: :inline（リクエスト内で同期実行）/ 本番: Solid Queue（Puma 内）
   │     ├─ ProcessInspectionImageJob     画像ごとのメタデータ読み取り（exiftool）→ 気象データ割り当て → 品質チェック
   │     ├─ RecheckInspectionQualityJob   気象データの変更後に、全画像の気象データ割り当てと品質チェックをやり直す（合格した画像は再解析）
   │     ├─ GridProposalJob               品質チェック合格の画像に propose-grid を実行し、グリッドの提案を保存
   │     ├─ AnalyzeInspectionImageJob     グリッドを指定した画像を解析エンジンで解析し、異常・群を保存して重大度を付ける
   │     ├─ StaleAnalysisJob              長時間 analyzing・品質チェック待ちのまま残った画像を failed にする（本番は5分ごと）
   │     └─ ExplainInspectionJob          レビュー完了後に、確定した異常・群の所見と点検の総括文を Claude に書かせる
   ├─ 解析エンジン（コマンド） ThermalAnalyzerClient が python -m analyzer を Open3.popen3 で実行（タイムアウトでプロセスグループごと終了）
   ├─ exiftool（コマンド）     EXIF / XMP / メーカー独自タグの読み取り。gem は使わない
   ├─ Claude API               公式 Ruby SDK（anthropic 1.x）。ClaudeStructuredOutput が structured outputs で固定スキーマの JSON をもらう。所見の作成だけで、判定はしない
   ├─ PostgreSQL               本番は primary / cache / queue / cable の4DB
   └─ Active Storage           開発: storage/、テスト: tmp/storage/（:test）、本番: storage/（Docker ボリューム）
```

- 認証なし。どの発電所のデータも誰でも閲覧・操作できる
- 画面の選択中の発電所は session に保持。未選択なら `Site.first`
- 解析エンジン（`analyzer/`、Python 3.12・uv）は Phase 4 で Rails に接続した。呼び出し方は `config/analyzer.yml`（開発・テストは `uv run`、本番は Docker イメージ内の `/rails/analyzer/.venv/bin/python`）
- DJI Thermal SDK の呼び出しは Phase S の後に実装する（TODO）。それまで実際の R-JPEG は解析エンジンで `needs_review（sdk_unavailable）` になる。開発・テストは .npy の合成データを使う

## 2. 画面とルーティング

| パス | コントローラー | 内容 |
|---|---|---|
| `/` | `pages#home` | トップページ（レイアウトなし） |
| `/dashboard` | `dashboard#show` | パネルマップ（仮配置なら注記）、状態別件数、未読アラート、直近の点検、グラフ |
| `/switch_site` | `dashboard#show` | 発電所の切り替え（`site_id` を渡す） |
| `/sites` | `sites` | 発電所の登録・編集・削除（モジュール仕様を含む）。作成時にパネルを**仮配置**で自動生成する。詳細画面（show）のビューは無い |
| `/inspections` | `inspections` | 点検の一覧・詳細・新規（複数画像）・削除。詳細は JSON でステータス（`in_progress` を含む）も返す |
| `/inspections/:id/images/:id` | `inspection_images` | RGB の手動添付・差し替え・削除、画像の除外・除外の取り消し、グリッド入力画面（`grid`）・グリッドの保存（`grids`）・再解析（`reanalyze`） |
| `/inspections/:id/grid_templates` | `grid_templates` | グリッドテンプレートの保存・一括適用（`apply`） |
| `/inspections/:id/rejudge` | `inspections#rejudge` | 未確定の異常・群を現在の判定基準で判定し直す |
| `/inspections/:id/review` | `inspections#review` | レビュー画面（画像ごと。`?image=番号`）。候補の確定・修正・却下・手動追加、レビュー完了 |
| `/inspections/:id/complete_review` | `inspections#complete_review` | レビュー完了（completed にして重要度を付ける）。所見のジョブを登録する |
| `/inspections/:id/explain` | `inspections#explain` | 所見と総括文を作り直す（レビュー完了済みの点検だけ） |
| `/inspections/:id/anomalies` | `anomalies` | 見逃しの手動追加（create）、確定・修正・却下・パネルの割り当て・電気測定・群から外す |
| `/inspections/:id/anomaly_groups/:id` | `anomaly_groups` | 群の確定・却下（構成パネルにも反映） |
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
| `Inspection` | conducted_at、analysis_status（`pending` / `analyzing` / `completed` / `needs_review` / `failed`）、severity（completed のときだけ必須。それ以外は NULL =「判定なし」）、error_message、weather_note、review_reason、reviewed_at、総括文（summary_text・summary_priority_actions・summary_additional_checks・summary_prompt_version・summary_input_digest・summary_generated_at・summary_error）、report_pdf（Phase 7）。旧方式の項目: legacy_anomalies（**旧 anomalies**。読み取り専用）、anomaly_count、result、report、image（画像1枚） |
| `InspectionImage` | thermal（R-JPEG 原本。変換・縮小しない）、rgb（任意）、sequence、thermal_filename、メタデータ（captured_at、camera_model、width / height、GPS、altitude_m、gimbal_pitch / gimbal_yaw、metadata JSON）、is_radiometric（**メタデータによる仮判定**。NULL = 判定できない）、気象データ（irradiance_w_m2 / irradiance_type / wind / 気温 / 湿度）、quality_report、analysis_status（`pending` / `analyzing` / `completed` / `needs_review` / `failed` / `excluded`）、review_reason、exclusion_note、panel_grids・grid_proposal・raw_analysis・analyzer_version（Phase 3〜4） |
| `WeatherReading` | observed_at、irradiance_w_m2（入力したら irradiance_type = `poa` / `ghi` / `unknown` 必須）、wind_speed_m_s、air_temp_c、humidity |
| `RuleSet` | version（一意）、active（全体で1つ。部分ユニークインデックス）、note、detection_params（JSON。必須キーあり）。**作成後は active 以外変更不可、削除不可** |
| `SeverityRule` | anomaly_type（6種類すべて必須）、measure、normalized_mild / warning / critical、raw_mild / warning / critical（各系列で mild < warning < critical）。**作成後は読み取り専用** |
| `Anomaly` / `AnomalyGroup` / `GridTemplate` | 項目は IMPROVEMENT_PLAN 4.2〜4.4 のとおり。所見（Claude）: cause_candidates・explanation（= reasoning）・additional_checks・recommended_action・report_text・prompt_version・explanation_input_digest・explained_at・explanation_error（群にも同じ列） |
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
     → rejected の項目があれば needs_review（review_reason = 最初の rejected 項目）
     → 合格（ok / warning）なら InspectionImagePipeline: GridProposalJob を登録し、
       グリッドがあれば AnalyzeInspectionImageJob、無ければ needs_review（grid_required）
     → 例外は failed（error_message）。どの場合も正常扱いにはしない
     → Inspection#refresh_status! で点検全体のステータスを集計
3b. グリッドの指定（inspection_images#grid。Stimulus の grid_editor_controller.js + canvas）
     4隅（左上・右上・右下・左下）をクリックし、行数・列数・向きを指定。1画像に複数のグリッドを置ける。角はドラッグで調整
     グリッドの提案（propose-grid）は初期値として読み込めるだけで、保存するまで解析に使わない
     テンプレートとして保存 → 撮影条件（高度・ジンバル角。許容差は config/analyzer.yml）の近い、
       グリッド未指定の画像に一括適用（指定済みの画像は上書きしない）
     保存すると AnalyzeInspectionImageJob を登録する。← / → で前後の画像（未保存の変更があれば移動しない）
3c. AnalyzeInspectionImageJob（画像1枚ごと）
     有効なルールセットを rules.json、Site のモジュール仕様を --module、日射量を渡して解析エンジンを実行
     → 終了コード 0: AnalysisResultImporter が未確定の異常・群を作り直す（locked の異常は残す）。
       群の構成パネル（module_wide）は群に紐付ける。SeverityRuleEngine で重大度・判定時のルールセットと閾値のコピーを保存。
       証拠レベルは RGB があれば B、無ければ C
     → 終了コード 2〜4: needs_review（sdk_unavailable / no_radiometric / grid_required / insufficient_baseline など）
     → 時間切れ: failed（timeout）。出力が約束どおりでない: failed（invalid_output）。パネル・アラートは変えない
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

**点検全体のステータス**（`Inspection#aggregated_status`。`excluded` の画像は除く）: pending / analyzing があれば `analyzing` → failed があれば `failed` → needs_review があれば `needs_review`（`images_need_review`）→ すべて completed でも **completed にせず `needs_review`（`review_pending` = レビュー待ち）**。候補が0件でも同じ（見逃しの手動追加があるため、人が画像を確認するまで「正常」にしない。2026-10-04 ユーザー承認）。completed と重要度（確定済みの異常の最大重大度）は Phase 5 の「レビュー完了」の操作で付ける。すべて除外なら `needs_review`。

**重大度**（`SeverityRuleEngine`）: `threshold_basis` が normalized なら正規化ΔT と `normalized_*`、raw なら生ΔT と `raw_*` の閾値で mild / warning / critical（mild 未満は nil =「基準未満」）。locked の異常は変えない。再判定（`inspections#rejudge`）は未確定のものだけ、明示的な操作のときだけ。mild を下げても新しい候補は増えないため、その場合は画像の再解析が必要（画面に表示）。

**候補の件数**（`Inspection#candidate_count`）: 未確定の異常のうち群の構成パネルを除き、群を1件として数える（指示書 4.4）。

**アラート**（`ConfirmedAnomalyAlert`）: 人が確定・修正した critical の異常・群ごとに1件だけ（修正後の重大度で判定）。群の構成パネルごとには作らない。レビュー操作（`AnomalyReview`）から呼ぶ。

**再解析と人の判断**（`AnalysisResultImporter`）: 未確定の候補は作り直し、locked（確定・修正・却下・手動追加）の異常は残す。locked の異常と同じ画像で bbox の IoU が `locked_overlap_iou`（0.5）以上で重なる候補、locked の群とパネルが重なる群は作らない。証拠レベルは検出時点ではすべて C。

#### 4.1.1 レビュー（Phase 5）

```
レビュー画面（inspections#review、review_controller.js）
  画像ごとに候補（群 → 異常）を一覧。サーモ・RGB の切り出し（RGB は位置合わせ未設定のため「おおよその位置」）、
  数値・判定に使った値（正規化ΔT / 生ΔT）・分類の根拠・フラグ・状態を表示
  キーボード: j / k 移動、c 確定、x 却下（理由が未選択なら選択に案内）
AnomalyReview（すべて locked にし、元の判定値は残す）
  確定: 原因候補（selected_causes）、「RGB で確認した」なら証拠レベル B
  修正: final_anomaly_type / final_bbox（画像の上でドラッグ）。final_severity は、修正後の種類の ΔT の指標（measure）が
        保存されている値の指標と同じなら判定時のルールセットの閾値で付け直し、違えば人が選ぶ（選ばなければ修正しない）
  却下: 理由（グレア・影・汚れ・その他）必須
  群: 群単位で確定・却下し構成パネルにも反映。群から特定のパネルを外せる
  パネルの割り当て: 人がパネルを選ぶ（ロックしない。自動提案は未実装 → 既知の問題 R）
  電気測定: 方法・結果・日付 → 証拠レベル A
  見逃しの手動追加: 画像の上で範囲を指定、種類・重大度は人が選ぶ（detection manual、確定・locked）
  確定・修正した critical → ConfirmedAnomalyAlert。完了済みの点検で操作したらレビュー待ちに戻す
InspectionReview（レビュー完了。2026-10-15 ユーザー承認）
  解析待ち・解析中・要確認・失敗の画像が残っていれば完了できない（除外するか解析を終える）
  「すべての画像を確認し、見逃しがない」ことの確認が必須（候補0件でも）
  未確定の候補が残っていれば警告し、確認のチェックがあるときだけ完了。残った候補は重要度に入れない
  completed・重要度（確定・修正した異常・群の最大重大度。点検の重要度に mild を追加。無ければ normal）・reviewed_at
  完了後に画像のステータスが変わる・レビュー操作をすると、重要度とレビュー完了を取り消してレビュー待ちに戻る
学習データ（bin/rails "dataset:export[OUT_DIR]"、DatasetExporter）
  解析済みで未確定の候補が残っていない画像だけ。確定・修正した異常を YOLO 形式（修正後の種類・位置）、
  却下だけ・異常なしの画像は空のラベル（負例）。manifest.csv・labels_detail.csv。リポジトリ内（tmp/ 以外）には書き出さない
```

```
所見と総括文（Phase 6。2026-10-15 ユーザー承認）
  レビュー完了 → ExplainInspectionJob（「所見を作り直す」は force: true）
    対象: 確定・修正した異常（群の構成パネルを除く）と確定した群。却下・未確定には作らない
  AnomalyExplainer（app/prompts/anomaly_explainer_v1.txt）
    入力: 保存済みの構造化データの文字だけ（種類・ΔT と指標・正規化ΔT・面積比・日射量と種類・モジュール構成・
          証拠レベル・電気測定・人が選んだ原因候補・パネル番号・フラグ）。画像・人のメモ・重大度は送らない
    出力: cause_candidates[]（cause・basis）、reasoning、additional_checks[]、recommended_action、report_text
  InspectionSummaryWriter（app/prompts/inspection_summary_v1.txt）
    入力: 点検日・画像枚数（除外）・日射量・気象・モジュール構成・点検の重要度・確定した異常の件数と内訳と一覧・未確定の候補の件数
    出力: summary_text、priority_actions[]、additional_checks[]
  ClaudeStructuredOutput: モデルは CLAUDE_MODEL（未設定ならリクエストしない）、上限トークン数・タイムアウト・再試行は config/claude.yml
    出力の JSON スキーマに severity は無い（additionalProperties: false）。余計な項目が返っても保存しない
    API エラー・拒否・途中で切れた応答・JSON でない応答・所見文が空 → explanation_error / summary_error に記録
  入力（＋プロンプトの版）の SHA-256 を保存し、同じなら作り直さない。失敗時、入力が変わっていたら古い所見を消す
  書き込むのは所見の列だけ。種類・重大度・状態・パネル・Site には触れない
  画面: 点検詳細の「所見・総括」、レビュー画面のカードの「所見（Claude）」。作成後にデータが変わったら「古い所見」と表示
```

### 4.3 解析エンジン（`analyzer/`）

CLI の `python -m analyzer analyze` / `propose-grid`。詳しくは [analyzer/README.md](../analyzer/README.md)。

```
温度行列（R-JPEG → DJI Thermal SDK。SDK の呼び出しは Phase S 後に実装する TODO。テスト・開発用に .npy）
→ グリッド（4隅・行数・列数）から射影変換でパネル領域 → パネルを長方形に引き伸ばした「整列パッチ」
→ 画像の端に接するパネルを除外（edge_cut）
→ パネルごとの t_max / t_mean / t_min / p95
→ 基準温度（正常パネルの t_mean の中央値。MAD の下限つき。足りなければ終了コード 4）
→ パネルごとに2つの判定を独立に行う（両方に当てはまれば別々に出力。出力の detection に local / baseline）
   基準温度からの判定: パネル平均の ΔT が module_wide の mild 以上なら、基準温度 + その mild を超える領域で
     module_wide（面積比 ≥ 0.80）/ substring_bypass（帯に一致。作動した帯の本数 active_bands）/ partial_module
   局所的な判定: パネル中央値 + max(k × MAD, 1℃) を超える連結領域で
     hotspot / multi_hotspot / substring_bypass / partial_module
   基準温度からの判定で異常が出たパネルでは、局所的な判定の substring_bypass / partial_module は出さない（二重計上の防止）
→ mild（正規化ΔT が出せれば normalized_mild、出せなければ raw_mild を生ΔT に換算）以上だけを出力
→ 同じグリッドの同じ行で隣接する module_wide を panel_row_group にまとめる
```

severity は出さない。終了コード: 0=成功、1=その他エラー、2=温度データなし、3=グリッドなし（提案できない）、4=基準パネル不足。

### 4.2 旧方式（Phase 1 までの点検。表示のみ）

`inspection_images` を持たない点検は旧方式（`Inspection#legacy?`）として、`inspections/_legacy.html.erb` で従来どおり表示する（DB には書き込まない）。新しく作る手段は無い。判定の処理（`AnalyzePanelImageJob` / `ClaudePanelAnalyzer`）は Phase 6 で削除した。結果は `legacy_anomalies` に残っている（読み取り専用）。

**アラートの方針**（旧方式のジョブ。Phase 6 で削除）: 1つの点検につき1件だった。旧方式で作られたアラートはそのまま残る。

## 5. 既知の問題

[IMPROVEMENT_PLAN.md のセクション0](IMPROVEMENT_PLAN.md) の #2〜#6 は Phase 1、#8（1点検1画像）は Phase 2 で対応済み。以下は Phase 0 以降に**追加で見つかった**ものです。

| # | 問題 | 場所 | 対応 |
|---|---|---|---|
| A〜E | show の DB 書き戻し、severity の常時必須、pending の自動更新、画像なしの点検作成、ジョブのトランザクション | — | **Phase 1 で対応済み** |
| F | 発電所作成時にパネルを格子状に自動生成しており、位置は実配置と無関係 | `SitesController#generate_panels_for` | **Phase 2 で対応済み**（ユーザー承認: 仮配置として残す）。`panels.layout_source` を追加し、既存・新規とも `auto`。ダッシュボードとフォームに「仮配置」と表示。実配置の登録手段（CSV 取込など）は未実装で、後のフェーズで検討 |
| G | モデル名 `claude-opus-4-7` がコード内に固定 | `ClaudePanelAnalyzer::MODEL` | **Phase 6 で対応済み**（旧方式の判定を削除し、所見の作成は `CLAUDE_MODEL` を使う） |
| H | `PagesController` に存在しない `authenticate_user!` の skip が残っている（無害） | `PagesController` | Phase 8 の認証導入時に整理 |
| I | ワーカーが途中で落ちると `analyzing`（または品質チェック待ち）のまま残り、自動更新が止まらない | `AnalyzePanelImageJob` / `ProcessInspectionImageJob` / `auto_refresh_controller.js` | **Phase 4 で対応済み**（`StaleAnalysisJob` が `stale_after_minutes` を超えた画像・旧方式の点検を failed に。自動更新の JS にも上限時間） |
| J | Claude の応答の件数・重大度・異常一覧の食い違い | `ClaudePanelAnalyzer#parse_response` | **Phase 1 で対応済み** |
| K | **アプリのタイムゾーンが UTC のまま。** 点検日時などの表示は UTC。撮影時刻と気象データの時刻だけは `config/image_quality.yml` の `capture_time_zone`（Asia/Tokyo）で解釈・表示している | `config/application.rb` | 未対応（アプリ全体の表示が変わるため、指示を受けて対応） |
| L | 発電所の詳細画面（`sites/show`）のビューが無く、更新後の `site_path` へのリダイレクトでエラーになっていた | `SitesController#update` | **Phase 2 で最小限の修正**（更新後は発電所一覧に戻す）。詳細画面は未作成 |
| N | 発電所フォームの `defined?(method)` が Ruby 組み込みの `method` メソッドを指し、**新規登録画面が開けなかった**（Phase 2 以前から） | `sites/_form.html.erb` | **Phase 2 で修正**（`local_assigns.fetch(:method, :post)`） |
| O | 解析エンジンが、パネルの 50〜80% が温まったケースを検出できない（仕様のすき間） | `analyzer/analyzer/pipeline.py` | **Phase 3b で対応済み**（ユーザー承認: 基準温度からの判定を追加。指示書 5.6） |
| R | レビューのパネルの割り当てで、`panel_grids` の `start_panel_ref` からの自動提案が未実装。`start_panel_ref` の形式が決まっておらず、登録済みのパネルがすべて仮配置のため | `AnomalyReview#assign_panel!` | 人がパネルを選ぶ割り当てだけ。形式と実配置の登録方法を決めてから実装（ユーザーの判断待ち） |
| S | レビュー画面の RGB の切り出しは、サーモと同じ正規化座標の「おおよその位置」 | `review_controller.js` | Phase S でサーモと RGB の変換を決めてから対応 |
| T | `csv` は Ruby 3.4 で標準の gem から外れる（Ruby 3.3.10 では警告のみ） | `app/services/dataset_exporter.rb` | Ruby 3.4 に上げるときに Gemfile へ追加（新しい gem の追加のため、そのとき確認） |
| P | Dockerfile の `RUBY_VERSION` が 3.2.9 で、`.ruby-version`（3.3.10）と食い違っていた（Phase 0 以前から） | `Dockerfile` | **Phase 4 で修正**（3.3.10 に合わせた） |
| Q | 解析エンジンの DJI Thermal SDK の呼び出しが未実装のため、実際の R-JPEG は `needs_review（sdk_unavailable）` になる | `analyzer/analyzer/thermal/dji_reader.py` | Phase S の後に実装（TODO） |
| U | 開発環境はジョブが `:inline` のため、レビュー完了のリクエストの中で Claude API を呼ぶ（確定した異常の件数だけ待つ） | `ExplainInspectionJob` | 本番は Solid Queue で非同期。開発で困るようなら指示を受けて対応 |
| V | 所見・総括文は、発電所のモジュール構成や気象データを後から変えても自動では作り直さない（画面に「古い所見」と表示する） | `AnomalyExplainer#current?` | 「所見を作り直す」で作り直す。報告書（Phase 7）の版の管理と合わせて検討 |
| M | 温度データの有無はメタデータのタグによる仮判定。実際の R-JPEG でどのタグが出るかは未確認 | `config/image_quality.yml` の `radiometric_tags` | Phase S で実画像を確認して見直す。最終判定は Phase 3 の解析エンジン |

## 6. テスト

- `bin/rails test`: 263件（Phase 6 時点。旧方式の Claude 判定のテスト 38件はコードと一緒に削除）。services / jobs / controllers / models / integration と主要画面のスモークテスト。`bin/rails test:system`: 6件（グリッド入力画面とレビュー画面の JS をヘッドレス Chrome で確認）
- **本物の解析エンジンを呼ぶテスト**（`test/integration/analyzer_end_to_end_test.rb`）: `analyzer/scripts/make_dev_scenes.py` で合成シーン（.npy）を作り、Rails から `uv run python -m analyzer` を実行する。uv と `cd analyzer && uv sync` が必要（CI の test ジョブも uv を入れている）
- 偽の解析エンジン: `AnalyzeInspectionImageJob.client` を `with_fake_analyzer` で差し替える（本番では常に `ThermalAnalyzerClient`）
- 解析エンジン: `cd analyzer && uv run pytest`（60件）。合成の温度行列（`analyzer/tests/fixtures/make_synthetic.py`）だけを使う。CI の `analyzer-test` ジョブでも実行する
- Claude API は呼ばない。`ClaudeStructuredOutput.default_client` に偽クライアント（`FakeAnthropicClient`。SDK の `Anthropic::Message` を返す）を渡し、`CLAUDE_MODEL` もテスト用の値にする（`with_fake_claude`）
- exiftool は**実際に動かす**テストと、**偽の読み取りクラスに差し替える**テストがある。本物の R-JPEG の熱画像タグは exiftool で書き込めないため、温度データありの場合は `ProcessInspectionImageJob.exif_reader` を `with_fake_exif(tags:)` で差し替える（本番では常に `ExifReader`）。開発機・CI とも exiftool が必要（CI は apt で導入）
- テスト用画像はすべて合成: `panel.png`（8×8）、`thermal_plain_T.jpg`（640×512、EXIF あり・温度データなし）、`lowres_T.jpg`（320×256）、`rgb_V.jpg`、`memo.txt`（画像以外）。顧客画像は使わない
- 受け入れ確認「温度データの無い JPEG が needs_review（no_radiometric）になり、理由が画面に表示される」は、実際の exiftool を使うジョブのテストと結合テストで確認している
- Active Storage はテストで `:test` サービス（`tmp/storage/`）を使う
- トランザクションのテストは、アラート作成で例外を起こすジョブのサブクラスをテスト内だけで定義して使う
