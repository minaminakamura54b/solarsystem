# Phase S 手順書（DJI Thermal SDK の検証）

R-JPEG と DJI Thermal SDK が届いたら、この手順で進める。結果は [spike_dji_sdk.md](spike_dji_sdk.md) に記入する。
仕様の正本は [IMPROVEMENT_PLAN.md の Phase S](IMPROVEMENT_PLAN.md)。目安は 1〜2 日。

**守ること**

- SDK のバイナリ・顧客の画像はコミットしない（`analyzer/bin/` は `.gitignore` 済み）。顧客の画像はリポジトリの外の `~/SolarSightData/development/spike/`（以下 `$SPIKE`。`SPIKE=~/SolarSightData/development/spike`）に置く（2026-11-09 に `$SPIKE/` から移した）
- SDK のオプション名・出力形式・測定パラメータの渡し方は、**SDK 同梱の README とヘルプの出力で確かめてから**記録する。推測で書かない
- 温度行列が取れない場合は、ここで止めて方針を相談する（機材の変更、別形式への対応など）

---

## 0. 届くもの・用意するもの

| もの | 内容 | 置き場所 |
|---|---|---|
| R-JPEG（サーモ） | 使用予定の機体・カメラで撮影したもの。**できれば 3 組以上**（高度・角度・時刻が違うもの） | `$SPIKE/`（例: `DJI_0001_T.JPG`） |
| 同時撮影の RGB | サーモと同じ番号の `_V` | `$SPIKE/`（例: `DJI_0001_V.JPG`） |
| DJI Thermal SDK | DJI の開発者サイトから取得した zip。**版番号と利用規約を確認**する | 展開して `analyzer/bin/dji_thermal_sdk/` |
| 機体・カメラの情報 | 機体名・カメラ名・ファームウェアの版 | 記録用紙（spike_dji_sdk.md） |
| 撮影時の条件 | 日時・天候・雲量・風速・日射量（POA か GHI か）・気温・湿度 | 記録用紙 |
| 比較用の温度 | DJI Thermal Analysis Tool（または機体のアプリ）で見た、数点の温度 | 記録用紙 |

11 月は日射量 600 W/m²（POA）以上になる時間が短い（晴天の正午前後の 2〜3 時間）。撮影はその時間帯に合わせる。
解像度は 1 セル 5 画素四方以上を目安にする（M4T・真下向き・対地約 40 m で約 5 画素とぎりぎり。今後の撮影はもう少し低い高度を検討。下の「撮影条件の目安」）。

### 撮影条件の目安（記録。2026-11-03 ユーザー指示）

| 項目 | 目安 | 根拠・状態 |
|---|---|---|
| 解像度 | 1 セル 5×5 画素以上 | 規格の目安（原文で要確認）。2026-07-16 のデータ（M4T・対地約 40 m）は約 5 画素でぎりぎり。今後はもう少し低い高度かズームを検討 |
| 日射量 | POA 600 W/m² 以上 | アプリの品質チェック（`config/image_quality.yml`）。夕方（例: 7 月の 17:48）は下回る可能性が高い |
| 日射量の記録 | 撮影中に POA（モジュール面）で記録する | GHI だけだと ΔT を正規化できない |
| 雲量・風速 | 記録する（雲量はアプリの気象データに記録欄あり） | 品質チェックへの反映は Phase S の後（規格の原文で確認するまでは警告） |
| カメラの向き | 真下（ジンバル −90°）。機首・ジンバルの向きを飛行中ずっと固定する | 配置との位置合わせ（真下向きだけを自動の対象にしている）と、見え方の影響の関数（架台・段の候補）のため。2026-11-08 追記（ユーザー指示） |
| 隣の飛行ラインとの重なり | 画像の縦の幅の半分以上 | 各架台の段が、画像の上側にも下側にも写るようにする（写る位置が片側だけの段は「判断の材料が足りない」になる。飛行 008 の試しで確認）。2026-11-08 追記 |

11 月の撮影では業者が求める条件を優先し、上の 2 行と両立できるかは業者の条件が届いてから確認する（2026-11-08 ユーザー指示）。

## 1. 対応機種の確認

1. SDK 同梱の README・リリースノートで、対応カメラの一覧に今回のカメラがあるかを確かめる
2. SDK の版番号、対応 OS・CPU（x86_64 Linux か）を記録する

→ 記録: spike_dji_sdk.md「1. SDK と機材」

## 2. メタデータの確認（Mac でそのまま実行できる）

```bash
exiftool -a -G1 -s $SPIKE/DJI_0001_T.JPG > $SPIKE/DJI_0001_T.exif.txt
exiftool -a -G1 -s $SPIKE/DJI_0001_V.JPG > $SPIKE/DJI_0001_V.exif.txt
grep -i -E "thermal|emissiv|distance|humid|reflect|ambient|calib|raw" $SPIKE/DJI_0001_T.exif.txt
grep -i -E "altitude|gimbal|pitch|yaw|gps|datetime|focal|fov" $SPIKE/DJI_0001_T.exif.txt
```

確かめること:

- 温度データの有無を示すタグ名（今の仮の一覧は `config/image_quality.yml` の `radiometric_tags`。既知の問題 M）
- 撮影時にカメラへ設定されていた測定パラメータ（放射率・距離・湿度・反射温度）のタグ名と値
- 撮影時刻・GPS・高度・ジンバル角が、今の読み取り（`ImageMetadataExtractor`）で取れるか
- サーモと RGB の画像サイズ・画角（焦点距離）

→ 記録: spike_dji_sdk.md「2. メタデータ」

## 3. linux/amd64 のコンテナを用意する（Apple Silicon の Mac）

SDK は x86_64 Linux 向け。Mac では Docker の linux/amd64 で動かす（エミュレーションのため遅いが検証には足りる）。

```bash
# SDK の実行ファイルは展開しただけでは実行権限が無い（Mac 側で一度だけ）
chmod +x analyzer/bin/dji_thermal_sdk/*/utility/bin/linux/release_x64/dji_*

# UV_PROJECT_ENVIRONMENT を付けないと、マウントした analyzer/.venv（Mac 用）を Linux 用で上書きしてしまう
docker run --rm -it --platform linux/amd64 -e UV_PROJECT_ENVIRONMENT=/opt/venv \
  -v "$PWD/analyzer:/work/analyzer:ro" -v "$SPIKE:/work/spike" \
  -w /work/analyzer python:3.12-slim bash

# コンテナの中で（libgomp1 は dji_irp が使う OpenMP。無いと起動しない）
apt-get update && apt-get install -y --no-install-recommends file libgomp1 && rm -rf /var/lib/apt/lists/*
pip install uv && uv sync --frozen
file bin/dji_thermal_sdk/**/dji_irp 2>/dev/null || find bin/dji_thermal_sdk -name 'dji_irp*'
```

`dji_irp` の場所が分かったら、置き場所の確認コマンドを実行する（SDK の機能は呼ばない。ファイル・実行権限・x86_64 かだけ）:

```bash
export DJI_IRP_PATH=/work/analyzer/bin/dji_thermal_sdk/<dji_irp のパス>
# 共有ライブラリが dji_irp と別の場所にあるときだけ
# export DJI_IRP_LIB_DIR=/work/analyzer/bin/dji_thermal_sdk/<ライブラリのディレクトリ>
uv run python -m analyzer check-sdk
```

`"ok": true` にならなければ、`message` の理由を直す（実行権限が無い・x86_64 でない・ライブラリの場所が無い など）。

→ 記録: spike_dji_sdk.md「3. 実行環境」（dji_irp とライブラリの SDK 内の位置）

## 4. 温度行列を取り出す

1. ヘルプを保存する: `"$DJI_IRP_PATH" -h > /work/spike/dji_irp_help.txt 2>&1`（ヘルプの出し方は README で確認）
2. README とヘルプから、**温度（℃）を float32 で出力する**指定を探し、1 枚で実行する。実行するときは
   `LD_LIBRARY_PATH` に SDK のライブラリの場所を足す（解析エンジンも同じ方法で呼ぶ: `analyzer/analyzer/thermal/sdk.py` の `subprocess_env`）
3. 出力を読み、大きさと値を確かめる:

```bash
uv run python - <<'PY'
import numpy as np
W, H = 640, 512          # 手順 2 で確かめたサーモ画像のサイズ
DTYPE = np.float32       # README で確かめた出力の型（int16 で 0.1℃ 単位などの場合は変換する）
t = np.fromfile("/work/spike/DJI_0001_T.raw", dtype=DTYPE).reshape(H, W)
print("min", t.min(), "max", t.max(), "median", np.median(t))
for x, y in [(100, 100), (320, 256), (500, 400)]:   # Thermal Analysis Tool で見た点
    print((x, y), t[y, x])
PY
```

4. DJI Thermal Analysis Tool（または機体のアプリ）で同じ点の温度を見て、差を記録する（目安: 0.5℃ 以内か）

→ 記録: spike_dji_sdk.md「4. 温度行列」（コマンド・出力形式・型・単位・比較結果）

## 5. 測定パラメータの効き方

アプリには、点検ごとの放射率・反射温度・距離と、気象データの湿度を解析エンジンに渡す受け皿がある（`--measurement`）。

1. README で、放射率・反射温度・湿度・距離の指定方法と、**受け付ける範囲**を確かめる
2. 何も指定しないとき、R-JPEG に記録された撮影時の値が使われるかを確かめる（手順 2 のタグの値と比べる）
3. 放射率を 2 通り（例: 0.85 と 0.95）にして同じ画像を処理し、温度が変わることと、変わり方を記録する

→ 記録: spike_dji_sdk.md「5. 測定パラメータ」

## 6. RGB との位置合わせ

1. サーモと RGB の両方で、同じ対象（パネルの角など）を **4 点以上、画像の四隅付近に広げて**選び、ピクセル座標を読む
   （Mac のプレビューなどで座標を読む。サーモは疑似カラーの JPEG で見てよい）
2. 対応点を JSON にする:

```json
{"thermal_size": [640, 512], "rgb_size": [4000, 3000],
 "points": [{"thermal": [102, 88], "rgb": [655, 540]}, {"thermal": [530, 95], "rgb": [3350, 560]}]}
```

3. 変換を求める（Mac でそのまま実行できる）:

```bash
cd analyzer && uv run python scripts/fit_rgb_alignment.py $SPIKE/points_0001.json
```

4. 「拡大率＋ずれ」と「アフィン変換」の誤差（RGB 画像上のピクセル）を見る。**別の画像（高度・角度が違うもの）でも同じ値で合うか**を確かめる
5. 固定値で足りるか（誤差がパネル 1 枚の大きさより十分小さいか）を判断する。足りなければ「おおよその位置」のまま（Phase 7 は承認済みの扱い: 広めに切り出し、枠を描かず注記）

→ 記録: spike_dji_sdk.md「6. RGB との位置合わせ」

## 7. グリッドの自動提案の評価（実画像・エリア撮影。最優先。2026-11-03 ユーザー指示）

エリア撮影では 1 回の飛行で 200 枚以上になり、アレイの写る位置が画像ごとに変わる。手でグリッドを指定するのは現実的でないため、
温度が読めたら**最初に**自動提案がどこまで使えるかを確かめる。

1. 手順 4 の読み取りを `dji_reader` に仮に組み込める状態にしてから（または温度行列を `.npy` に保存して）、
   飛行 1 回分の画像（少なくとも 30 枚。アレイの写り方が違うものを含める）に `propose-grid` を実行する
2. 1 枚ずつグリッド入力画面で提案を読み込み、次の 4 つに分ける
   - **そのまま使える**: 行数・列数が合い、4 隅のずれがパネル 1 枚の大きさより十分小さい
   - **直せば使える**: 角のドラッグ・行数や列数の修正で済む。直すのにかかった時間（秒）を記録する
   - **使えない**: 提案が無い（`panel_extraction_failed`）、または別の場所を指している
   - **アレイが複数・切れ目がある**: 今の自動提案は 1 画像に 1 グリッドだけを返す。通路で切れたアレイや、端で切れたアレイがある画像で、どこまで手で足す必要があるか
3. 合計して報告する: 各分類の枚数と割合、直す時間の平均と合計、200 枚に換算した作業時間、外れ方の傾向（低い日射量・地面の温度・アレイの端・切れ目など）
4. 精度が足りない場合の改善案（例: 複数のグリッドの提案、前後の画像の提案を引き継ぐ、撮影位置からの推定）を、実装する前に提示する

→ 記録: spike_dji_sdk.md「7. 注意点・分かったこと」と、報告

## 8. 記録と判定

1. spike_dji_sdk.md をすべて埋める（使ったコマンド・オプション・出力形式・変換パラメータ・注意点）
2. 判定を書く: 温度行列が取れたか／Thermal Analysis Tool と整合したか／RGB の位置合わせを固定値にするか
3. 取れなかった場合は、ここで止めて相談する

---

## 11 月の案件の手順（代わりの手順。2026-11-06 ユーザー指示）

位置情報を使った画像の選び方と異常の重複のまとめは、11 月の案件の後に着手する。それまでは次の手順で進める。

1. 撮影フォルダの `_T` のメタデータ（位置）から、`analyzer/scripts/select_images.py` で解析する画像を選ぶ（飛行ラインを原則 2 本おき・撮影を原則 3 枚おき。使い方は analyzer/README.md）。一覧は `$SPIKE/` に置き、コミットしない
2. 選んだ画像の `_T` と `_V` を点検に登録する（組み合わせは番号と撮影時刻の差 2 秒以内）
3. 人が架台ごとに 1 回だけグリッドを指定する（同じ架台が 2 枚に丸ごと写っていれば、片方だけでよい）。パネルが写っていない画像は「この点検では使わない」にする
4. ~~最初の 5 枚でグリッド入力の時間を測り、全体の作業時間の見込みを直す~~（2026-11-06 中止。配置図と位置情報でパネルを自動で特定する方式に切り替える。設計案は [LAYOUT_OVERLAY_DESIGN.md](LAYOUT_OVERLAY_DESIGN.md)。この手順は自動で特定できない場合の予備）
5. 解析・レビュー・報告書は通常どおり。Thermal Analysis Tool との照合は報告書を出す前までに行う（ユーザー）

## Phase S の後に行うこと（実画像への対応。2026-10-22 ユーザー指示の順番）

1. ~~`analyzer/analyzer/thermal/dji_reader.py` の SDK 呼び出しを、spike_dji_sdk.md の記録どおりに実装する（`sdk.subprocess_env` を使う。測定パラメータの渡し方と範囲も）~~ **2026-11-06 済み**（測定距離は画像ごとのレーザー距離 → 点検の入力 → 画像の記録値。放射率は根拠のある値が分かるまで未設定）
2. `config/image_quality.yml` の `radiometric_tags` を実際のタグ名に直す（既知の問題 M）
3. 品質チェックの追加（風速・視野角・パネル当たり画素数）。閾値は `config/image_quality.yml` に置き、**規格の原文で確認するまでは「警告」**（不合格にしない）
4. 雲量を品質チェックに反映する（記録欄は 2026-11-03 に実装済み。気象データの雲量（オクタ）を画像に割り当て、規格の原文で確認するまでは「警告」）
5. RGB の位置合わせを固定値にできた場合は、その値を設定に置き、レビュー画面の「おおよその位置」の表示を切り替える（既知の問題 S）
6. 実画像で `min_region_pixels`・`band_axis` の解釈・閾値の初期値を見直し、Phase 4 の受け入れ確認（実画像が要るもの）を行う。グリッドの自動提案は手順 7 の評価の結果に合わせて改善する（改善案は実装前に提示）
7. 本番サーバーに SDK を置く（付録）。本番の Dockerfile への `libgomp1` の追加は 2026-11-06 済み

## 付録: SDK の置き場所（設計。2026-10-22）

| 環境 | SDK の場所 | 設定 |
|---|---|---|
| 開発（Mac） | `analyzer/bin/dji_thermal_sdk/`（コミットしない）。実行は Docker の linux/amd64 の中だけ | `DJI_IRP_PATH`（必要なら `DJI_IRP_LIB_DIR`）をコンテナ内のパスで指定 |
| 本番（Kamal・linux/amd64） | サーバーの `/opt/dji_thermal_sdk/` に展開し、コンテナの同じパスに**読み取り専用**でマウント（`config/deploy.yml` の `volumes`。今はコメント） | `config/deploy.yml` の `env.clear` に `DJI_IRP_PATH`（必要なら `DJI_IRP_LIB_DIR`） |

- SDK はライセンス上、Docker イメージにもリポジトリにも含めない
- コンテナは uid 1000（rails）で動く。SDK のファイルは uid 1000 から読めて、`dji_irp` は実行できるようにする
- 解析エンジンは `dji_irp` を呼ぶとき、`LD_LIBRARY_PATH` の先頭に `DJI_IRP_LIB_DIR`（省略時は `dji_irp` と同じディレクトリ）を足す（`analyzer/analyzer/thermal/sdk.py`）
- 本番で置き場所を確かめる: `bin/kamal app exec --reuse "bash -c 'cd analyzer && .venv/bin/python -m analyzer check-sdk'"`（解析エンジンは `/rails/analyzer` で動く。SDK の機能は呼ばない）
- 本番サーバーへの操作（SDK の配置・deploy.yml の有効化・デプロイ）は、ユーザーの確認を得てから行う
