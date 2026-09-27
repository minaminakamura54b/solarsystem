# solarsystem 改善指示書 v2.1（Claude Code 用）

対象リポジトリ: `minaminakamura54b/solarsystem`
配置先: `docs/IMPROVEMENT_PLAN.md`（`CLAUDE.md` から参照する）
目的: 太陽光パネルのサーモ画像解析を「Claude に画像を見せて判定させる方式」から「放射温度データ ＋ ルール判定 ＋ 人の確認」方式へ移行し、実案件（赤外線画像による熱異常スクリーニング）で使える品質にする。

v1 からの主な変更: エラー経路の修正範囲を拡大、ステータス名を既存コードに合わせた、検出と重大度の閾値を分離、パネル群の異常を別テーブル化、モジュール構成への依存を明示、判定ルールのバージョンを保存、DJI SDK の事前検証を追加、グリッド入力 UI を追加、Phase 1 を安全修正に限定、既存データの移行を廃止、誤検出対策を追加、PDF 方式を確定。

v2.1 の変更: `severity` の NOT NULL 制約の解除を Phase 1 に追加、module_wide の面積比を基準温度から定義、MAD に下限を追加、閾値を「ルールセット」単位で管理し正規化ΔT用と生ΔT用を分離、グリッド提案を別サブコマンドに分離、画像の `excluded`（除外承認）状態を追加、パネル群と個別異常の計上ルールを追加、1画像に複数グリッドを許容、RGB 位置合わせを Phase S に追加。

## この指示書の使い方

- Claude Code には **1セッション＝1フェーズ** で依頼する。フェーズをまたいで一気に実装させない。
- 各フェーズの冒頭で「この指示書の該当フェーズを読み、実装計画を提示してから着手する」と指示し、承認後に進める。
- 各フェーズの最後に「受け入れ確認」を人が行う。
- 指示書と実コードが食い違っていたら、実装せずに報告させる。

---

## 0. 現状（コードレビューで確認済みの事実）

### 技術スタック
- Rails 8.1 / PostgreSQL / Propshaft / importmap / Turbo / Stimulus / jbuilder
- `anthropic` gem 0.4.1 — **非公式 gem**（`Anthropic::Client.new(access_token:)` 形式）。公式 SDK 1.x は同名だが API が別物なので、移行は書き直しになる
- `solid_queue`（本番）、開発環境のジョブは `:inline`
- `image_processing`、`aws-sdk-s3`、`chartkick` / `groupdate`、`kamal`

### データモデル
- `sites` / `panels` / `inspections` / `alerts` / `revenues`。`users` なし（認証なし）
- `inspections.anomalies` は **json**（jsonb ではない）
- `inspections.analysis_status` は `pending` / `analyzing` / `completed` / `failed`。views で `completed?` を多用している

### 既知の問題
| # | 問題 | 影響 |
|---|------|------|
| 1 | Claude が疑似カラーの色で判定しており温度を測っていない | 精度の根本原因 |
| 2 | JSON パース失敗 → `normal` | 見逃し |
| 3 | `error_result`（画像なし・ダウンロード失敗・API エラー）も `severity: "normal"` | 見逃し |
| 4 | 解析失敗時も全パネルの `last_inspected_at` を更新 | 失敗しても「点検済み」に見える |
| 5 | 異常をパネルの並び順で機械的に割り当て | マップの異常位置が実際と無関係 |
| 6 | `pending` 状態では自動更新されない | 画面が止まって見える |
| 7 | 画像を縮小せずに送信 | 大きな画像で API エラー |
| 8 | 1 Inspection = 1 画像 | 実案件（数百枚）に対応できない |
| 9 | テストが事実上ない（`test_helper.rb` のみ） | 回帰を検出できない |
| 10 | `CLAUDE.md` がない | 規律の参照先がない |
| 11 | 認証なし・本番ストレージがローカルディスク | 顧客公開前に必須 |

---

## 1. 設計原則（全フェーズ共通・最優先）

1. **異常か正常かの判定は、温度データとルールで行う。Claude には判定させない。** Claude の役割は確定した数値をもとに所見・原因候補・推奨対応・報告文を書くことに限定する。
2. **解析失敗・API エラー・データ不足を `normal` にしない。** 必ず `failed` または `needs_review`。
3. **失敗した解析は、パネルや Site の状態を一切変更しない**（`last_inspected_at` も含む）。
4. **「分からない」を正式な結果にする。**
5. **根拠の数値を必ず保存し、報告書に出す。**
6. **確信度（%）を出さない。** 代わりに証拠レベル（A/B/C）を使う。
7. **閾値をハードコードしない。** DB または設定ファイルに持ち、バージョンを付ける。
8. **判定時のルールバージョンと閾値のスナップショットを異常ごとに保存する。確定済みの異常は、後から閾値を変えても変わらない。**
9. **パネルへの紐付けは、位置情報または人の指定でのみ行う。** 並び順による機械的な割り当ては禁止。
10. **人のレビューを経て初めて「確定」。** 未確定は報告書で「候補」と区別する。
11. **報告書に個人名を載せない。** 会社名・屋号のみ。
12. **今回やらないこと**: YOLO の学習、SCADA 連携、オルソモザイク、年間損失額の精密計算、修理タスク管理。

---

## 2. ステータスの定義（既存の `completed` を維持する）

`inspections.analysis_status` と `inspection_images.analysis_status` で同じ値を使う。

| 値 | 意味 |
|---|---|
| `pending` | 登録済み・未処理 |
| `analyzing` | 解析中 |
| `completed` | 解析が正常に終わった（異常の有無は問わない） |
| `needs_review` | 品質不足・温度データなし・パネル抽出不可など。人の確認が必要 |
| `failed` | プログラムや API のエラー |
| `excluded` | 画像のみ。`needs_review` / `failed` の画像を、人が「この点検では使わない」と承認した状態 |

`needs_review` の理由は `review_reason`（string。`no_radiometric` / `low_irradiance` / `low_resolution` / `grid_required` / `panel_extraction_failed` / `insufficient_baseline` など）に入れる。`excluded` にするときは `exclusion_note`（理由）を必須にする。

Inspection 全体のステータスは画像のステータスから次の優先順で集計する（`excluded` の画像は集計対象外）:
1. `pending` または `analyzing` の画像が1枚でもある → `analyzing`
2. `failed` の画像がある → `failed`（件数を表示）
3. `needs_review` の画像がある → `needs_review`（件数を表示）
4. 残りがすべて `completed` → `completed`

`excluded` の画像は報告書の「除外・要確認画像の一覧」に理由付きで載せる。

---

## 3. 目標アーキテクチャ

```
ブラウザ（複数画像アップロード、グリッド指定）
        │
        ▼
Rails: InspectionImage を画像ごとに作成 → AnalyzeInspectionImageJob（solid_queue）
        │
        ├─ ① 品質チェック（Rails 側 / EXIF・XMP・解像度・日射量）
        │       └ 不合格 → needs_review（解析しない）
        │
        ├─ ② Python 解析エンジン（analyzer/、CLI）
        │       R-JPEG → 温度行列（DJI Thermal SDK）
        │       → パネル領域（手動グリッド優先、自動抽出は補助）
        │       → 除外判定（画像端で切れたパネル、グレア疑い）
        │       → パネルごとの温度特徴量・基準温度・ΔT
        │       → 検出（ロバスト統計）→ 発熱パターン分類（ルール）
        │       → 構造化 JSON
        │
        ├─ ③ Rails: SeverityRuleEngine（ルールのスナップショットを保存）
        │
        ├─ ④ 人のレビュー（確定 / 修正 / 却下 / パネル割当）→ 確定で固定
        │
        ├─ ⑤ Claude: 確定データから所見・原因候補・推奨対応・報告文
        │
        └─ ⑥ 影響容量（kW）算出 → PDF 報告書
```

Python は `analyzer/` に置き、Rails のジョブから `Open3` で呼ぶ。本番は **linux/amd64** 前提（DJI SDK の制約）。

---

## 4. データモデル（Phase 2 で実施）

### 4.1 `inspection_images`（新規）
| カラム | 型 | 説明 |
|---|---|---|
| inspection_id | references | |
| thermal（Active Storage） | | R-JPEG 原本。**変換・縮小せず保存** |
| rgb（Active Storage） | | 同時撮影 RGB（任意） |
| sequence | integer | 撮影順 |
| captured_at | datetime | EXIF |
| camera_model | string | EXIF |
| is_radiometric | boolean | |
| width / height | integer | |
| gps_lat / gps_lng / altitude_m / gimbal_pitch / gimbal_yaw | decimal | 任意 |
| irradiance_w_m2 | decimal | 日射量 |
| irradiance_type | string | `poa`（モジュール面）/ `ghi`（水平面）/ `unknown` |
| wind_speed_m_s / air_temp_c / humidity | decimal | 任意 |
| quality_report | jsonb | 品質チェック結果 |
| analysis_status | string | セクション2 |
| review_reason | string | |
| exclusion_note | text | `excluded` にした理由 |
| panel_grids | jsonb | 画像に適用したグリッドの**配列**（通路・架台の切れ目がある画像では複数）。各要素は `{grid_template_id, rows, cols, corners, panel_orientation, start_panel_ref}`。テンプレートから適用した後に微調整した値を保存する |
| grid_proposal | jsonb | 自動抽出によるグリッド提案（`propose-grid` の出力） |
| analyzer_version | string | |
| raw_analysis | jsonb | Python 出力をそのまま保存 |
| error_message | text | |

### 4.2 `grid_templates`（新規）
同じ高度・ジンバル角・向きで撮った画像にグリッドを使い回すためのもの。1枚の画像に複数のテンプレートを適用できる。

| カラム | 型 | 説明 |
|---|---|---|
| inspection_id | references | |
| name | string | 例「A列 往路」 |
| rows / cols | integer | 画像内のパネル行数・列数 |
| corners | jsonb | 4隅の座標（0〜1 正規化） |
| panel_orientation | string | `portrait` / `landscape` |
| altitude_m / gimbal_pitch / gimbal_yaw | decimal | 適用条件の目安 |
| start_panel_ref | jsonb | 左上パネルの行・位置（パネルID割当用、任意） |

### 4.3 `anomalies`（新規。1パネル単位の異常）
| カラム | 型 | 説明 |
|---|---|---|
| inspection_image_id / inspection_id | references | |
| anomaly_group_id | references, null可 | 複数パネルの異常群に属する場合 |
| panel_id | references, null可 | レビューで確定したパネル |
| panel_index_in_image | integer | 画像内の通し番号（複数グリッドの場合は grid 順に連番） |
| anomaly_type | string | `hotspot` / `multi_hotspot` / `substring_bypass` / `module_wide` / `partial_module` / `other` |
| severity | string | `mild` / `warning` / `critical` |
| bbox | jsonb | 0〜1 正規化 |
| t_max / t_mean / t_min | decimal | |
| baseline_temp | decimal | |
| delta_t | decimal | 生のΔT。算出方法は `measure` による（下記 5.6） |
| measure | string | ΔT の算出方法。`region_max` / `region_mean` / `panel_mean` |
| normalized_delta_t | decimal, null可 | POA 日射量がある場合のみ |
| threshold_basis | string | 重大度判定に使った値。`normalized`（正規化ΔT）/ `raw`（生ΔT） |
| area_ratio | decimal | 定義は種類ごと（5.6） |
| shape_features | jsonb | 分類根拠を含む |
| flags | jsonb | `glare_suspect`（グレア疑い）、`unnormalized`、`edge_adjacent` など |
| evidence_level | string | A / B / C |
| electrical_evidence | jsonb | 電気測定結果（IVカーブ、ストリング電流など。A 判定に必須） |
| rule_set_id / rule_version | references / string | 判定に使ったルールセット |
| rule_snapshot | jsonb | 判定時の閾値のコピー |
| review_status | string | `pending` / `confirmed` / `corrected` / `rejected` |
| final_anomaly_type / final_bbox / final_severity | | 修正後の値 |
| reviewed_at / reviewer_note | | |
| locked | boolean | 確定・修正・却下で true。true の異常は再判定しない |
| cause_candidates / recommended_action / explanation / prompt_version | | Claude 出力 |
| affected_dc_kw / estimated_loss_kw / loss_basis | | 影響算出 |

### 4.4 `anomaly_groups`（新規。複数パネルにまたがる異常）
| カラム | 型 | 説明 |
|---|---|---|
| inspection_image_id / inspection_id | references | |
| group_type | string | `panel_row_group`（画像内で連続するパネル群） |
| panel_count | integer | |
| panel_indices | jsonb | 群に含まれる `panel_index_in_image` |
| delta_t / normalized_delta_t / threshold_basis | | 群全体の panel_mean ΔT（構成パネルの中央値） |
| severity / rule_set_id / rule_version / rule_snapshot | | |
| electrical_string_ref | string, null可 | ストリング図と照合できた場合のみ |
| review_status / locked | | |
| affected_dc_kw / loss_basis | | |

**計上ルール（二重計上の防止）**: 群を構成する module_wide は `anomalies` にも1パネル1レコードで作り、`anomaly_group_id` で群に紐付ける（パネルごとの数値とパネル割当のため）。ただし次の集計では**群を1件として数え、構成パネルの異常は数えない**:
- 件数（種類別・重大度別）、Inspection の集計重大度
- アラート（群の severity で判定。構成パネルごとには作らない）
- 影響容量（群の `affected_dc_kw` のみ。構成パネル側は合計に含めない）

レビューは群単位で行う。群を確定・却下すると構成パネルの異常にも同じ `review_status` と `locked` が入る。群から特定のパネルだけ外す操作（その異常を単独に戻す）もできるようにする。

**「ストリング異常」とは呼ばない。** 画像内で並んでいるパネル群は電気的なストリングと一致するとは限らない。`panels.string_number` が登録されていて、群のパネルが同一ストリングと一致した場合のみ、報告書で「ストリング異常の疑い」と表記する。

### 4.5 `rule_sets` / `severity_rules`（新規）
閾値は**ルールセット単位**でバージョン管理する。有効（active）にできるのは常に1セットだけ。

`rule_sets`
| カラム | 型 | 説明 |
|---|---|---|
| version | string, unique | 例 `2026-10-v1` |
| active | boolean | 全体で1件のみ true（部分ユニークインデックス） |
| note | text | 変更理由・合意先 |
| detection_params | jsonb | MAD 下限・k 値・基準パネル必要数など、検出側のパラメータ（5.6） |

`severity_rules`（ルールセットの子。作成後は編集不可）
| カラム | 型 | 説明 |
|---|---|---|
| rule_set_id | references | |
| anomaly_type | string | `panel_row_group` を含む |
| measure | string | ΔT の算出方法。`region_max` / `region_mean` / `panel_mean` |
| normalized_mild / normalized_warning / normalized_critical | decimal | 正規化ΔT（POA 日射量あり）に適用 |
| raw_mild / raw_warning / raw_critical | decimal | 生ΔT（日射量が GHI・不明）に適用 |

- **適用ルール**: 正規化ΔT が計算できれば `normalized_*` を使い、`threshold_basis = normalized`。計算できなければ `raw_*` を使い、`threshold_basis = raw`、`unnormalized` フラグを立てる。報告書にはどちらで判定したかを明記する
- **mild = 検出の最小値**。これ未満は異常として出力しない。Python には active ルールセットを JSON で渡し、検出にもこの値を使う（検出と重大度の閾値を一元化する）
- **バリデーション**: 各系列で `mild < warning < critical`。1つのセットに全 anomaly_type が揃っていること
- 閾値を変えるときは既存のセットを編集せず、**新しいセットを作って active を切り替える**

初期値（暫定。商用製品の公開基準を参考にした値であり、案件ごとに依頼元と合意して変更する）:
| anomaly_type | measure | mild | warning | critical |
|---|---|---|---|---|
| hotspot | region_max | 2 | 5 | 15 |
| multi_hotspot | region_max | 1 | 2.5 | 7.5 |
| substring_bypass | region_mean | 1.5 | 3 | 8 |
| module_wide | panel_mean | 1.5 | 3 | 8 |
| partial_module | region_mean | 1.5 | 3 | 8 |
| panel_row_group | panel_mean | 1.5 | 2 | 5 |

`raw_*` も初期値は同じ値を入れる。ただし生ΔTは日射条件で大きく変わるため、**`raw` で判定した異常は `critical` でも自動でアラートを出さず、レビューで確定したときにだけ出す**。`raw_*` の値は依頼元と合意したうえで見直す。

`detection_params` の初期値:
```json
{"panel_mad_k": 4, "panel_mad_floor_c": 0.3, "min_region_offset_c": 1.0,
 "baseline_mad_k": 3, "baseline_mad_floor_c": 0.5,
 "baseline_min_panels": 6, "baseline_min_ratio": 0.5,
 "row_group_min_panels": 3}
```

### 4.6 既存テーブルの拡張
- `sites`: `module_model`, `module_rated_w`, `cell_layout`（`full_cell` / `half_cut` / `other`）, `substring_count`（default 3）, `bypass_pattern`（jsonb。モジュール型式ごとの発熱パターン定義）, `specific_yield_kwh_per_kw`（任意）, `fit_price_yen_per_kwh`（任意）
- `panels`: `row_number`, `string_number`, `position_in_string`, `gps_lat`, `gps_lng`（任意）
- `inspections`: `review_reason`, `weather_note`, `reviewed_at`, `report_pdf`（Active Storage）。`severity` は Phase 1 で null 可・デフォルトなしに変更済み（null =「判定なし」）

### 4.7 既存データの扱い
既存の `inspections.anomalies`（json）は温度も bbox もなく、新テーブルに合わないため**移行しない**。`legacy_anomalies` に名前を変えて読み取り専用で残し、旧データの詳細画面でのみ表示する。

---

## 5. 解析エンジン仕様（`analyzer/`）

### 5.1 構成
```
analyzer/
  pyproject.toml            # Python 3.11+, numpy, opencv-python-headless, pillow, pydantic
  Dockerfile                # linux/amd64
  README.md                 # セットアップ手順、DJI SDK の入手と配置
  bin/                      # DJI SDK バイナリ（.gitignore）
  analyzer/
    __main__.py
    contract.py             # 入出力スキーマ（pydantic、schema_version 付き）
    thermal/dji_reader.py   # R-JPEG → float32 温度行列
    thermal/tiff_reader.py  # radiometric TIFF（将来用、スタブ可）
    thermal/quality.py      # ブレ・温度レンジ
    vision/grid.py          # グリッド → パネル領域（主）
    vision/panel_segmenter.py # 自動抽出（補助。グリッド提案用）
    vision/exclusions.py    # 画像端・グレア疑い
    analysis/features.py
    analysis/baseline.py
    analysis/detection.py   # ロバスト統計による検出
    analysis/patterns.py    # 発熱パターン分類
    config/default_params.json
  tests/
    fixtures/make_synthetic.py
    test_*.py
```

### 5.2 CLI 契約
サブコマンドは2つ。**解析とグリッド提案を分ける。**

**(a) 解析: `analyze`**（グリッド必須）
```
python -m analyzer analyze \
  --thermal DJI_0001_T.JPG [--rgb DJI_0001_V.JPG] \
  [--irradiance 742 --irradiance-type poa] \
  --panel-grids '[{"rows":4,"cols":12,"corners":[[x,y],...],"panel_orientation":"landscape"}, ...]' \
  --module '{"cell_layout":"full_cell","substring_count":3,"bypass_pattern":{...}}' \
  --rules rules.json \
  --out result.json
```
- `--panel-grids` は配列（1画像に複数グリッド可）。未指定・空なら終了コード 3（`grid_required`）で、解析はしない
- `--rules` は Rails が active なルールセット（`severity_rules` と `detection_params`）から書き出す
- 終了コード: 0=成功、2=温度データなし、3=グリッドなし、4=基準パネル不足、1=その他エラー

**(b) グリッド提案: `propose-grid`**
```
python -m analyzer propose-grid --thermal DJI_0001_T.JPG --out proposal.json
```
- 自動抽出（`panel_segmenter.py`）でグリッド候補を返すだけ。解析はしない
- 終了コード: 0=提案あり、3=提案できない（抽出失敗）、2=温度データなし、1=その他エラー
- Rails は画像登録後（品質チェック合格時）にこれを実行し、結果を `inspection_images.grid_proposal` に保存する。グリッド入力 UI はこれを初期値として表示する。**提案をそのまま解析に使わない**（人が確認・保存したグリッドだけを `panel_grids` に入れる）

### 5.3 出力 JSON（抜粋）
```json
{
  "schema_version": "2.0",
  "analyzer_version": "thermal_rules_v1",
  "status": "completed | needs_review | failed",
  "review_reason": null,
  "image": {"width": 640, "height": 512, "is_radiometric": true, "t_min": 21.3, "t_max": 68.1, "blur_score": 0.83},
  "irradiance": {"value": 742, "type": "poa"},
  "rule_version": "2026-10-v1",
  "baseline": {"temp": 42.4, "method": "median_of_normal_panels", "panel_count": 38, "mad": 0.42, "mad_used": 0.5},
  "panels": [{"index": 0, "grid_index": 0, "bbox": {}, "t_max": 43.1, "t_mean": 42.2, "t_min": 40.9, "p95": 42.9,
              "excluded": false, "exclude_reason": null, "is_baseline": true}],
  "anomalies": [{"panel_index": 7, "anomaly_type": "hotspot", "bbox": {},
                 "measure": "region_max", "delta_t": 25.4, "normalized_delta_t": 34.2,
                 "threshold_basis": "normalized",
                 "area_ratio": 0.028, "shape": {}, "flags": ["glare_suspect"]}],
  "groups": [{"type": "panel_row_group", "panel_indices": [12,13,14,15],
              "measure": "panel_mean", "delta_t": 3.1, "normalized_delta_t": 4.2, "threshold_basis": "normalized"}]
}
```
Python は severity を出さない。群の構成パネルは `anomalies` にも module_wide として出力する（計上ルールは 4.4）。

### 5.4 温度行列の取得（`dji_reader.py`）
- DJI Thermal SDK の `dji_irp` を subprocess で呼ぶ。**オプション名と出力形式は Phase S（検証）で確認した内容に合わせる。**
- 放射率・反射温度・湿度・距離は設定値として渡す。
- R-JPEG でない、SDK が失敗した場合は終了コード 2。**色からの逆算はしない。**
- SDK バイナリはコミットしない。`DJI_IRP_PATH` で指定。

### 5.5 パネル領域
- **主はグリッド**（`grid.py`）。グリッドごとに4隅と行列数から射影変換でパネル領域を生成する。通路や架台の切れ目をまたぐ場合は、1画像に複数のグリッドを置く。パネル番号は grid 順・各グリッド内は左上から行優先で連番にする
- 基準温度は**画像内の全グリッドのパネルをまとめて**計算する
- 「同一行で隣接」（panel_row_group）は**同じグリッド内の同じ行**でのみ判定する
- 自動抽出（`panel_segmenter.py`）は `propose-grid` の**提案**にだけ使う。
- 除外（`exclusions.py`）:
  - 画像の端に接している、または面積が期待値の 70% 未満のパネル → `excluded: edge_cut`。解析対象外（隣の画像で拾う前提）
  - 極小（例: パネル面積の 0.3% 未満）かつ周囲より極端に高温で、形状がセル境界と無関係な点 → `glare_suspect` フラグ。検出はするが自動確定の対象にせず、レビューで確認
  - 影は「低温側」の異常として扱わず、検出対象外。ただし影によるバイパス作動は発熱パターンとして検出されるので、原因候補として「影」をレビュー時に選べるようにする

### 5.6 基準温度と検出
パラメータはすべて `rules.json` の `detection_params`（4.5）から読む。以下の数値は既定値。

**MAD の下限**: 温度がほぼ均一だと MAD ≈ 0 になり、わずかな揺らぎで外れ値・異常と判定されてしまう。そのため MAD を使うときは常に `mad_used = max(MAD × 1.4826, floor)` とする（1.4826 は正規分布の標準偏差相当への換算係数）。下限は基準温度用 `baseline_mad_floor_c = 0.5℃`、パネル内用 `panel_mad_floor_c = 0.3℃`。

**基準温度** = 除外パネルと異常候補パネルを除いた「正常パネル」の t_mean の中央値
1. 除外されていない全パネルの t_mean の中央値 `m` と `mad_used` を出す
2. `m ± baseline_mad_k(3) × mad_used` を外れるパネルを除外する
3. 残りの中央値を基準温度にする
4. 残った正常パネル数が `max(baseline_min_panels(6), ceil(除外されていないパネル数 × baseline_min_ratio(0.5)))` 未満なら終了コード 4（`insufficient_baseline`）。パネル群全体が温まっている画像で、基準温度が引き上げられるのを防ぐ

**ΔT の算出方法（measure）は種類ごとに分ける**（v1 の「基準 + 3℃ で一律に切る」をやめる）:
- **パネル内の高温領域**: パネル内で `パネル中央値 + panel_mad_k(4) × mad_used(パネル内)` と `パネル中央値 + min_region_offset_c(1.0℃)` の大きい方を超える連結領域。hotspot / multi_hotspot / substring_bypass / partial_module の形状判定に使う
- `region_max`（hotspot / multi_hotspot）: 高温領域の t_max − 基準温度
- `region_mean`（substring_bypass / partial_module）: 高温領域の t_mean − 基準温度
- `panel_mean`（module_wide / panel_row_group）: パネル t_mean − 基準温度。**パネル内の高温領域を通さずに評価する**ので、全体が +2℃ 程度のモジュールも取りこぼさない

**面積比（area_ratio）の定義**:
- hotspot / multi_hotspot / substring_bypass / partial_module: 高温領域の画素数 / パネル画素数
- module_wide: **基準温度 + その種類の mild を超える画素数 / パネル画素数**。パネル全体が均一に温まっていると「パネル自身の中央値」から見た高温領域は空になるため、module_wide だけは基準温度から測る

**出力の条件**: 正規化ΔT が計算できれば `normalized_mild`、できなければ `raw_mild` 以上のものだけを異常として出力する。

**正規化ΔT** = ΔT × 1000 / 日射量。**日射量が POA のときのみ計算する。** GHI・不明のときは null とし `unnormalized` フラグ、`threshold_basis = raw`。

**判定の順序**（1パネルに複数の条件が当てはまるときの優先順位）: module_wide を先に評価する。module_wide に該当したパネルは、パネル内の高温領域の判定（hotspot 等）を行わず、module_wide 1件として出力する。

### 5.7 発熱パターン分類（`patterns.py`、すべて設定値）
| パターン | 条件（既定値） |
|---|---|
| hotspot | 領域数 1、面積比 < 0.10、縦横比 < 3 |
| multi_hotspot | 領域数 ≥ 2、各領域が hotspot 条件 |
| substring_bypass | `bypass_pattern` の定義に一致（下記） |
| module_wide | panel_mean の ΔT が mild 以上、かつ面積比（基準温度から測る。5.6）≥ 0.80 |
| partial_module | 帯状・部分的な発熱だが `bypass_pattern` に一致しない、またはモジュール構成が不明 |
| panel_row_group | 同じグリッドの同じ行で隣接する module_wide が `row_group_min_panels`（既定 3）枚以上 → `groups` に出力。構成パネルは `anomalies` にも module_wide として出す |
| other | 上記以外 |

**`bypass_pattern`** はモジュール型式ごとに Site に登録する。例（フルセル・3サブストリング）:
```json
{"layout": "full_cell", "bands": 3, "band_axis": "short_side", "band_area_ratio": 0.333, "tolerance": 0.12}
```
ハーフカットなどで発熱形状が異なる型式は、その型式の実際の形状を確認してから定義を追加する。**定義がない、または `cell_layout` が不明な場合は `substring_bypass` と判定せず `partial_module` にする。**

### 5.8 テスト
- `make_synthetic.py` で合成温度行列を作る:
  - 正常、単セル hotspot、複数 hotspot、1/3 帯状、モジュール全体 +2℃（module_wide として検出され、面積比 ≥ 0.80 になる）
  - 連続4枚 +3℃（基準不足にならないケースとなるケース両方）
  - **温度がほぼ均一（ノイズ ±0.05℃）の正常画像** → MAD 下限が効き、異常ゼロ・終了コード 0
  - 画像端で切れたパネル、極小高温点（グレア疑い）
  - 通路をはさむ2グリッドの画像（群が通路をまたいで結合されない）
  - 日射量が GHI（正規化ΔT が null、`threshold_basis = raw`）
- `propose-grid` がグリッドの明瞭な合成画像で提案を返し、構造のない画像で終了コード 3 を返す
- `analyze` がグリッドなしで終了コード 3 を返す
- 期待どおりの分類・除外・終了コードになることを `pytest` で確認する
- 顧客の実画像はリポジトリに入れない

---

## 6. フェーズ別タスク

### Phase S: DJI SDK 検証（最初に行う。半日）
Phase 0 より前に、前提が成り立つかを確かめる。

1. 使用予定の機体・カメラで撮った **R-JPEG を1枚**用意する（人が用意）
2. DJI Thermal SDK の対応機種一覧に、そのカメラが含まれているか確認する
3. linux/amd64 の Docker コンテナで `dji_irp` を実行し、温度行列（float32）を取り出す
4. 取り出した行列の最小・最大・中央値を出し、カメラ付属アプリや DJI Thermal Analysis Tool の表示値と比べて整合するか確認する
5. **RGB との位置合わせを確認する**: 同時撮影の RGB（`_V`）がある場合、サーモとの画角・解像度・中心のずれを調べる。同じ対象（パネルの角など）を両方の画像で数点指定し、サーモ座標 → RGB 座標の変換（拡大率とオフセット、必要ならアフィン変換）が機体・カメラごとに固定値で済むかを確認する。結果は Phase 5 の「RGB 同位置の切り出し」に使う
6. 温度データの有無を Rails 側で判定するための EXIF/XMP タグ名（例: 放射温度データの存在を示すタグ）を記録する（Phase 2 の品質チェックで使う）
7. 使ったコマンド、オプション、出力形式、変換パラメータ、注意点を `docs/spike_dji_sdk.md` に記録する

**判定**: 温度行列が取れない場合は Phase 3 以降の前提が崩れるため、ここで止めて方針を再検討する（機材の変更、別形式への対応など）。RGB の位置合わせが固定値で済まない場合は、Phase 5 の RGB 切り出しを「おおよその位置」と明示して表示するか、手動で合わせる操作を加えるかを決める。

### Phase 0: 土台づくり（1日）
1. リポジトリ全体を読み、`docs/ARCHITECTURE.md` に現状の構成・フロー・既知の問題をまとめる（セクション0と食い違いがあれば報告）
2. `CLAUDE.md` を作成する。内容: プロジェクト概要、この指示書への参照、設計原則の要約、コマンド（テスト・lint・起動）、禁止事項（「失敗を normal にしない」「閾値をハードコードしない」「秘密情報・SDK・顧客画像をコミットしない」）
3. `.env.example`（`ANTHROPIC_API_KEY`, `CLAUDE_MODEL`, `DJI_IRP_PATH`）、`.gitignore` の更新
4. **テストの土台を作る**: fixtures（site, panels, inspection）、Anthropic 呼び出しをスタブするヘルパー、既存の `AnalyzePanelImageJob` と `ClaudePanelAnalyzer` に対する現状の挙動テスト（Phase 1 で修正すべき挙動を「現状こうなっている」と記録するテスト）
5. `README.md` をセットアップ・起動・テスト手順に書き換える

受け入れ確認: `bin/rails test` で実質的なテストが走る。`CLAUDE.md` から指示書にたどれる。

### Phase 1: 安全修正のみ（1日）
現行の Claude 画像判定は Phase 6 で廃止するため、ここでは**危険な挙動を止めることだけ**を行う。SDK 移行・tool use 化はしない。

1. **マイグレーション（可逆）を最初に行う**:
   - `inspections.severity` の `null: false` と `default: "normal"` を外す。**これをしないと、失敗時に severity を設定しなくてもデフォルト値の `normal` が入る**
   - `inspections.error_message`（text）を追加する
   - 既存データのうち `analysis_status = 'failed'` の行は `severity` を `NULL` に更新する（`down` では `normal` に戻す）
   - `Inspection` モデルの validation・scope、dashboard などで `severity` が必ずある前提の箇所を洗い出して直す
2. `parse_response` の失敗時に `normal` を返さない。`analysis_status: failed` と `error_message` を保存する
3. **`error_result` も同様に修正する**（画像なし・ダウンロード失敗・API エラー）。`severity` は `nil` のまま保存し、views が `nil` を「判定なし」と表示するようにする
4. **失敗時はパネル・Site の状態を一切更新しない**（`last_inspected_at` の更新を成功時のみに移す）
5. 並び順によるパネル割り当てと、それに伴うパネル `status` 更新を削除する
6. `auto_refresh_controller.js` が `pending` でもポーリングする
7. 同一 Inspection に対するアラートの重複作成を防ぐ
8. （Phase 6 までに今のアプリを実案件で使う場合のみ）送信前に長辺 1568px の派生画像を作って送る。原本は残す
9. 上記すべてにテストを書く

受け入れ確認: API エラー・壊れた JSON のモックで `failed` になり、`severity` が `NULL`（`normal` ではない）で、パネルの `last_inspected_at` と `status` が変わらない。`pending` の画面が自動更新される。

### Phase 2: データモデルと品質チェック（2〜3日）
1. セクション4のマイグレーション（すべて可逆）。`inspections.anomalies` → `legacy_anomalies` へリネーム
2. 複数画像アップロード（Thermal と RGB を `_T` / `_V` のファイル名規則で自動ペアリング、手動修正可）。Active Storage への直接アップロード
3. EXIF/XMP 読み取り（`exiftool`。Dockerfile に追加）
4. `ImageQualityChecker`:
   - 温度データの有無（Phase S で記録した XMP タグ、最終的には Python の判定）
   - 解像度 ≥ 640×512
   - `captured_at` あり、GPS なしは warning
   - 日射量: 未入力 → warning、`poa` で < 600 W/m² → `needs_review (low_irradiance)`、`ghi` のみ → warning（正規化しない旨を表示）
5. 気象データの入力画面（Inspection 単位、時刻付きで複数行。画像の撮影時刻で補間して割り当て。日射量の種類 POA/GHI を必須入力）
6. Site のモジュール仕様入力（型番、定格W、`cell_layout`、`substring_count`、`bypass_pattern`）
7. Inspection 詳細を「複数画像のセッション」前提に作り直す（画像ごとのステータス・理由・品質結果）。`needs_review` / `failed` の画像を、理由を入力して `excluded` にする操作と、`excluded` を取り消す操作を付ける。Inspection のステータスはセクション2の優先順で集計する
8. `rule_sets` / `severity_rules` のシードと管理画面（一覧・既存セットを複製して新セット作成・active 切替。既存セットの編集は不可）

受け入れ確認: 温度データのない JPEG が `needs_review (no_radiometric)` になり、理由が画面に出る。その画像を `excluded` にすると Inspection のステータスから外れる。ルールセットに不整合な閾値を入れると保存できない。active なセットは常に1つだけ。

### Phase 3: 解析エンジン（3〜5日）
セクション5の仕様どおりに `analyzer/` を実装する。順序:
1. `contract.py` と `make_synthetic.py`
2. `grid.py`（射影変換でパネル領域）
3. `baseline.py` / `detection.py` / `patterns.py` / `exclusions.py`（合成データでテストしながら）
4. `dji_reader.py`（Phase S の記録に合わせる。SDK がなければ終了コード 2）
5. `panel_segmenter.py` と `propose-grid` サブコマンド（精度が低くてもよい。提案できなければ終了コード 3）
6. `analyzer/README.md` と Dockerfile

受け入れ確認: `pytest` が通る。合成データの全ケースが期待どおり分類・除外される。モジュール全体 +2℃ が検出される。温度がほぼ均一な正常画像で誤検出がない。連続群で正常パネルが不足する画像は終了コード 4 になる。

### Phase 4: グリッド入力 UI と Rails 接続（3〜4日）
1. **グリッド入力 UI**（Stimulus + canvas）:
   - サーモ画像上で4隅をクリックし、行数・列数・向きを入力 → パネル枠を重ねて表示
   - **1画像に複数のグリッドを追加できる**（通路・架台の切れ目をまたぐ場合）
   - 「テンプレートとして保存」→ `grid_templates`
   - 同じ高度・ジンバル角（許容差は設定値）の画像に**テンプレートを一括適用**
   - 画像ごとに4隅をドラッグで微調整でき、調整結果は `panel_grids` に保存
   - `grid_proposal`（`propose-grid` の結果）がある場合は、それを初期値として表示。保存するまで解析には使わない
   - キーボードで前後の画像へ移動
2. `GridProposalJob`: 品質チェックに合格した画像に `propose-grid` を実行し `grid_proposal` に保存（失敗しても画像のステータスは変えない）
3. `ThermalAnalyzerClient`: CLI を実行し、出力を契約で検証する。**`Open3.capture3` にはタイムアウト機能がない**ため、`Open3.popen3` で起動し、120 秒（設定値）を超えたらプロセスグループごと終了させて `failed (timeout)` にする。一時ファイルは `ensure` で削除する
4. `AnalyzeInspectionImageJob`: 品質チェック → `panel_grids` がなければ `needs_review (grid_required)` → 解析 → `raw_analysis` 保存 → `Anomaly` / `AnomalyGroup` 作成。終了コードでステータスを決める。グリッドを保存したら、その画像の解析ジョブを再投入する
5. `SeverityRuleEngine`: active ルールセットで severity を付け、`rule_set_id` / `rule_version` / `rule_snapshot` / `threshold_basis` を保存する。`locked` の異常は対象外。**再判定は「未確定の異常のみ」かつ明示的な操作でだけ行う**
   - 注意: Python は mild 未満を出力しないため、**mild を下げた場合は Rails 側の再判定では新しい候補は増えない**。その場合は画像の再解析（未確定の異常を削除して解析し直す。`locked` の異常は残す）が必要であることを画面に表示する
6. Inspection の集計（確定済みのみで重大度を算出。未確定は「候補」件数として別表示。群は 4.4 の計上ルールに従う）
7. critical の異常・群が確定したときのみアラートを作成（重複させない。群の構成パネルごとには作らない）
8. Dockerfile に Python・`exiftool`・DJI SDK の配置を追加。Kamal の設定を amd64 に

受け入れ確認: 実画像（Phase S の画像）でグリッドを指定して解析でき、パネルごとの温度と異常候補が出る。テンプレートを他の画像に一括適用できる。1画像に2つのグリッドを置いて解析できる。新しいルールセットを active にしても確定済みの異常の severity は変わらない。解析エンジンが時間切れになると `failed (timeout)` になり、プロセスが残らない。

### Phase 5: レビュー UI と学習データ（3〜4日）
1. 異常候補一覧（画像ごと、群ごと）。各候補にサーモ切り出し（bbox 重畳）、RGB 同位置の切り出し（Phase S で決めた変換を使う。固定値で合わない場合は「おおよその位置」と表示）、数値、判定に使った値（正規化ΔT / 生ΔT）、分類根拠、フラグ（グレア疑い・未正規化・端）を表示
2. 操作: 確定 / 種類を修正 / 位置を修正（bbox ドラッグ）/ 誤検出として却下（理由選択: グレア・影・汚れ・その他）/ パネルを割当（`panel_grids` の `start_panel_ref` から自動提案、人が確認）/ 原因候補の選択
   - 群（panel_row_group）は群単位で確定・却下し、構成パネルにも反映する。特定のパネルを群から外す操作も付ける（4.4）
3. 見逃しの手動追加
4. 確定・修正・却下で `locked = true`。元の判定値は保持する
5. 電気測定結果の入力（`electrical_evidence`）。入力があれば証拠レベル A
6. `bin/rails dataset:export[OUT_DIR]`: 確定・修正済みを YOLO 形式で書き出す。却下された候補と異常なし画像を負例として含める。`manifest.csv` に撮影条件と数値
7. キーボード操作（j/k 移動、c 確定、x 却下）

受け入れ確認: 候補の確定・修正・却下・手動追加ができ、`dataset:export` で YOLO 形式が出る。

### Phase 6: Claude の役割変更と SDK 移行（2日）
1. **ここで一度だけ** 公式 Anthropic Ruby SDK に書き直す（非公式 gem 0.4.1 を削除）
2. `ClaudePanelAnalyzer` を削除し、`AnomalyExplainer` を作る。入力は構造化データのみ（切り出し画像の添付は任意）
3. 出力は tool use の固定スキーマ: `cause_candidates[]`, `reasoning`, `additional_checks[]`, `recommended_action`, `report_text`。**severity や正常/異常の判断は出力に含めない。含まれても無視する**
4. プロンプトは `app/prompts/anomaly_explainer_v1.txt`、`prompt_version` を保存
5. 確定済みの異常・群に対してのみ実行
6. Inspection 全体の総括文も同方式
7. モデル名は `CLAUDE_MODEL` で切替
8. 旧 `legacy_anomalies` の表示は残す

受け入れ確認: 確定済み異常に所見・原因候補・推奨対応が付く。Claude が severity を返しても DB は変わらない。非公式 gem が Gemfile から消えている。

### Phase 7: 影響容量と PDF 報告書（2〜3日）
1. `ImpactCalculator`:
   - `affected_dc_kw` = 定格W / 1000 × 対象枚数
   - `estimated_loss_kw`:
     - substring_bypass（`bypass_pattern` が定義済みの型式のみ）: 定格W × 作動バンド数 / バンド総数 / 1000
     - module_wide: null。`loss_basis`「モジュール全体の発熱。開放・短絡の可能性があり、電気測定で確認が必要」
     - hotspot / multi_hotspot / partial_module: null。`loss_basis`「算定保留（サーモのみでは出力低下量を確定できない）」
     - panel_row_group: 影響容量のみ（群の `affected_dc_kw`。構成パネル側の値は合計に含めない。4.4）
   - 年間損失（kWh・円）は `specific_yield_kwh_per_kw` と `fit_price_yen_per_kwh` がある場合のみ、「概算」と明記して出す
2. PDF は **grover（HTML → PDF、Chromium）** で作る。Dockerfile に Chromium と **日本語フォント（Noto Sans CJK JP）** を入れる。既存の Markdown レポートは廃止
3. 報告書の構成:
   - 表紙（サイト名・点検日・屋号。個人名なし）
   - 撮影条件（機材・時刻・日射量と種類（POA/GHI）・風速・気温・画像枚数・品質判定結果）
   - 判定基準（使用した `rule_version` と閾値。異常ごとの `rule_snapshot` から作る。正規化ΔTで判定したか生ΔTで判定したかの件数も出す）
   - 総括（Claude の総括文、種類別・重大度別件数、影響容量の合計。群は1件として数える）
   - 異常一覧（パネルID・種類・重大度・証拠レベル・ΔTと算出方法・正規化ΔT・判定に使った値（正規化/生）・影響容量・推定損失または算定保留・推奨する追加検査）
   - 異常ごとの詳細（サーモ・RGB 切り出し、数値、所見、原因候補、推奨対応）
   - 除外（`excluded`）・要確認画像の一覧と理由
   - 免責（赤外線サーモグラフィによる熱異常スクリーニングであり確定診断ではない。IEC TS 62446-3 を参考にしているが準拠を保証するものではない）
4. **確定済みの異常のみ**を報告書の本表に載せる。未確定が残っている場合は PDF 生成時に警告し、「候補」として別表に分ける
5. PDF を `inspections.report_pdf` に保存しダウンロード可能に

受け入れ確認: PDF に個人名が含まれない。日本語が化けない。算定保留の異常に数値が入っていない。閾値を変えた後に再出力しても、確定済みの数値と判定基準が変わらない。

### Phase 8: 顧客公開前の必須対応
1. 認証（`bin/rails generate authentication`）とサイト単位のアクセス制御
2. 本番ストレージを S3 に（R-JPEG 原本は削除しない）
3. バックアップ、`solid_queue` の監視
4. 将来: 自動パネル検出の改善、YOLO（OBB）学習、SAHI、SCADA 連携、修理タスク管理

---

## 7. Claude Code への共通ルール

- `CLAUDE.md` とこの指示書に従う。矛盾があれば「設計原則」を優先し、矛盾点を報告する
- 着手前に実装計画（変更ファイル・マイグレーション・テスト項目）を提示し、承認を待つ
- 小さくコミットする。コミットメッセージは日本語で「何を・なぜ」
- タスクごとに `bin/rails test`、`rubocop`、`brakeman`、（Python 変更時）`pytest` を実行し、結果を報告する
- マイグレーションは可逆に
- 秘密情報・SDK バイナリ・顧客画像をコミットしない
- 閾値・モデル名・パスをハードコードしない
- UI の文言は日本語
- **解析失敗・API エラー・パース失敗・データ不足を `normal` として保存するコードは書かない**
- **失敗した処理でパネルや Site の状態を変更しない**
- **`locked` の異常を自動で書き換えない**
- 確信度（%）を表示・保存しない
- 判定ロジックの追加、閾値の変更、パネルへの自動割り当ては、指示なく行わない。迷ったら質問する
- 変更を `docs/CHANGELOG.md` に日付付きで追記する

---

## 8. 投入プロンプト例

### Phase S
```
docs/IMPROVEMENT_PLAN.md の Phase S を読んでください。
tmp/spike/ に R-JPEG と同時撮影の RGB を1組置きました。linux/amd64 の Docker で DJI Thermal SDK を使い、
温度行列を取り出すまでを検証してください。SDK のバイナリは analyzer/bin/ に置いてあります。
あわせて RGB との位置合わせと、温度データの有無を示す XMP タグも確認してください。
手順を提示してから実行し、結果を docs/spike_dji_sdk.md にまとめてください。
```

### Phase 0
```
docs/IMPROVEMENT_PLAN.md を読んでください。Phase 0 を実施します。
まずリポジトリ全体を読み、セクション0の記述と実コードの食い違いを報告してください。
そのうえで CLAUDE.md の下書きと、テストの土台づくりの計画を提示してください。承認後に着手してください。
```

### Phase 1
```
docs/IMPROVEMENT_PLAN.md の設計原則と Phase 1 を読んでください。
安全修正のみを行います。SDK の移行と tool use 化はしません。
1〜7 の変更ファイル・マイグレーション・テストを一覧にして提示してください。
特に severity の NOT NULL／デフォルト解除のマイグレーション、error_result、last_inspected_at の扱いを確認してください。
```

### Phase 3
```
docs/IMPROVEMENT_PLAN.md のセクション5と Phase 3 を読んでください。
analyzer/ を新規作成します。まず contract.py、make_synthetic.py、grid.py を作り、
合成データで detection.py と patterns.py のテストが通るところまでを最初の区切りにしてください。
dji_reader.py は docs/spike_dji_sdk.md の記録に合わせて実装してください。
```

### Phase 4
```
docs/IMPROVEMENT_PLAN.md の Phase 4 を読んでください。
最初にグリッド入力 UI（4隅指定、テンプレート保存、一括適用、微調整）を作ります。
画面の構成案を先に提示してください。
```

### Phase 6
```
docs/IMPROVEMENT_PLAN.md の Phase 6 を読んでください。
非公式 anthropic gem を削除し、公式 Ruby SDK で AnomalyExplainer を実装します。
入力は構造化データのみ、出力は tool use の固定スキーマ、severity は出力しない（含まれても無視）という制約を守ってください。
プロンプト本文を先に提示して承認を得てください。
```

---

## 9. 用語

| 用語 | 意味 |
|---|---|
| R-JPEG | DJI の放射温度データ入り JPEG。画素ごとの温度を持つ |
| 基準温度 | 同一画像内の正常パネルの平均温度の中央値 |
| ΔT | 異常の温度 − 基準温度。算出方法（measure）は種類ごとに region_max / region_mean / panel_mean |
| 正規化ΔT | ΔT × 1000 / POA 日射量 |
| threshold_basis | 重大度判定に使った値。`normalized`（正規化ΔT）/ `raw`（生ΔT。日射量が GHI・不明のとき） |
| MAD | 中央値絶対偏差。外れ値に強いばらつきの指標。均一な画像で 0 に近づくため下限を設ける |
| ルールセット | 閾値と検出パラメータの組。バージョン単位で作成し、active は常に1つ |
| POA / GHI | モジュール面日射量 / 水平面日射量 |
| substring_bypass | バイパスダイオード作動による帯状の発熱。モジュール型式の定義がある場合のみ判定 |
| partial_module | 部分的な発熱だが、型式の定義と一致しない、または構成不明のもの |
| panel_row_group | 同じグリッドの同じ行で隣接するパネル群の発熱。電気的なストリングとは限らない。集計では群を1件と数える |
| 証拠レベル | A: サーモ＋RGB＋電気データ / B: サーモ＋RGB / C: サーモのみ |
| locked | 人が確定・修正・却下した異常。自動で再判定しない |
| needs_review | 人の確認が必要な状態。「正常」ではない |
| excluded | `needs_review` / `failed` の画像を、人が理由付きで「この点検では使わない」と承認した状態。報告書には除外画像として載る |
