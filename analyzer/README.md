# 解析エンジン（analyzer/）

サーモ画像の温度行列から、パネルごとの温度・基準温度との差（ΔT）・発熱パターンを求める Python の CLI です。仕様は [docs/IMPROVEMENT_PLAN.md のセクション5](../docs/IMPROVEMENT_PLAN.md) にあります。

- **異常か正常かの判定（severity）はしません。** 重大度は Rails がルールセットの閾値で付けます（Phase 4）
- 温度データを取得できないときは終了コード 2 を返します。推定や色からの逆算はしません
- Rails からは Phase 4 で `Open3` を使って呼び出します

## セットアップ

Python 3.12 と [uv](https://docs.astral.sh/uv/) を使います。依存関係は `pyproject.toml` と `uv.lock` で固定しています。

```bash
cd analyzer
uv sync              # Python 3.12 と依存関係（numpy・opencv-python-headless・pydantic、開発用に pytest）を用意
uv run pytest        # テスト（合成データのみ。顧客の実画像は使わない）
```

uv が Python 3.12 を自動で用意するので、Mac に入っている別のバージョンの Python には触れません。

## 使い方

```bash
# 解析（グリッド必須）
uv run python -m analyzer analyze \
  --thermal DJI_0001_T.JPG \
  [--irradiance 742 --irradiance-type poa] \
  --panel-grids '[{"rows":4,"cols":12,"corners":[[x,y],[x,y],[x,y],[x,y]],"panel_orientation":"landscape"}]' \
  --module '{"cell_layout":"full_cell","substring_count":3,"bypass_pattern":{"bands":3,"band_axis":"short_side","band_area_ratio":0.333,"tolerance":0.12}}' \
  --rules rules.json \
  --out result.json

# グリッドの提案（解析はしない）
uv run python -m analyzer propose-grid --thermal DJI_0001_T.JPG --out proposal.json
```

- `corners` は**左上・右上・右下・左下**の順で、画像サイズで正規化した 0〜1 の座標です
- `--rules` は Rails が有効なルールセットから書き出す JSON です（`version`・`detection_params`・`severity_rules`）。解析エンジンが使うのは、検出の最小値（mild）と検出パラメータだけです
- `--thermal` には、開発・テスト用に `.npy`（float32 の温度行列、単位 ℃）も指定できます
- 解析パラメータのうちルールセットに含まれないもの（hotspot の面積比・縦横比、module_wide の面積比、グレア疑いの面積比など）は `analyzer/config/default_params.json` にあり、`--params` で差し替えられます

### 終了コード

| コード | 意味 | 出力 JSON の status / review_reason |
|---|---|---|
| 0 | 成功（propose-grid は提案あり） | completed / proposed |
| 1 | その他のエラー | failed（file_not_found、invalid_input、dji_reader_not_implemented など） |
| 2 | 温度データなし | needs_review（no_radiometric、sdk_unavailable、unsupported_format） |
| 3 | グリッドなし・提案できない | needs_review（grid_required、panel_extraction_failed） |
| 4 | 基準温度を出すための正常パネルが足りない | needs_review（insufficient_baseline） |

どの終了コードでも、可能なかぎり `--out` に JSON を書き、理由を stderr に出します。

## DJI Thermal SDK

R-JPEG から温度行列を得るには、DJI Thermal SDK の `dji_irp` が必要です。

- **SDK はリポジトリにコミットしません**（ライセンス上）。`analyzer/bin/` に置くと `.gitignore` で除外されます
- 環境変数 `DJI_IRP_PATH` で `dji_irp` のパスを指定します
- SDK は x86_64 Linux 向けです。Apple Silicon の Mac では Docker（linux/amd64）で動かします
- 入手方法: DJI の開発者サイトから DJI Thermal SDK をダウンロードし、利用規約を確認してください

**現在の実装状況（Phase S 未実施）**: `thermal/dji_reader.py` は「JPEG でない（終了コード 2、`no_radiometric`）」「SDK が無い（終了コード 2、`sdk_unavailable`）」の判定までです。SDK のオプション名・出力形式・測定パラメータ（放射率・反射温度・湿度・距離）の渡し方は、Phase S で SDK 同梱の README と実画像を確認してから実装します（TODO）。それまでは、SDK があっても終了コード 1（`dji_reader_not_implemented`）を返します。

### 手元の R-JPEG で試す手順（Phase S 以降）

顧客の画像はリポジトリに入れず、`tmp/spike/`（`.gitignore` 済み）などに置いて試してください。

```bash
DJI_IRP_PATH=$PWD/bin/dji_irp uv run python -m analyzer propose-grid --thermal ../tmp/spike/DJI_0001_T.JPG --out /tmp/proposal.json
```

## Docker

```bash
docker build --platform linux/amd64 -t solarsystem-analyzer analyzer
docker run --rm -v "$PWD/work:/work" solarsystem-analyzer analyze --thermal /work/x.npy --panel-grids '[...]' --rules /work/rules.json --out /work/result.json
```

イメージに SDK は含めません。SDK を使うときのマウント方法は Phase S・Phase 4 で決めます。

## 構成

```
analyzer/
  contract.py               入出力の約束（pydantic、schema_version 2.0）
  pipeline.py               解析の流れ
  params.py / config/       ルールセットに含まれない解析パラメータ
  errors.py                 終了コードに対応する例外
  thermal/reader.py         拡張子で読み込み方法を選ぶ
  thermal/dji_reader.py     R-JPEG（DJI Thermal SDK。呼び出し部分は TODO）
  thermal/tiff_reader.py    radiometric TIFF（未対応）
  thermal/npy_reader.py     .npy（テスト・開発用）
  thermal/quality.py        温度レンジ・ブレの指標（記録のみ）
  vision/grid.py            グリッド → パネル領域（射影変換）
  vision/exclusions.py      画像端のパネルの除外
  vision/panel_segmenter.py グリッドの自動提案
  analysis/features.py      パネルごとの温度の特徴量
  analysis/baseline.py      基準温度（MAD の下限つき）
  analysis/detection.py     パネル内の高温領域、mild の換算
  analysis/patterns.py      発熱パターンの分類、隣接パネル群
tests/
  fixtures/make_synthetic.py 合成の温度行列
```

## 分類の決まりごと（2026-10-03 ユーザー確認済み）

- **bypass_pattern の band_axis**: その辺を `bands` 等分した帯として扱う（`short_side` なら短辺を等分し、長辺方向に伸びる帯）。一致の条件は、高温領域が1つ・面積比が `band_area_ratio ± tolerance`・帯が伸びる方向にパネルの `(1 − tolerance)` 以上・等分する方向の幅が `(band_area_ratio + tolerance)` 以下
- **グレア疑い**: 面積がパネルの 0.3% 未満の高温領域があればフラグを付ける（検出は消さない）。「セル境界と無関係」は、セル配置の情報が無いため判定しない（TODO）
- **どれにも当てはまらない高温領域**: すべて `partial_module`。ルールセットに `other` の閾値が無いため、解析エンジンは `other` を出さない（`other` はレビューで人が使う）
- **高温領域の最小画素数**: 設けない（1画素から高温領域とする。見逃さない側に倒す）

## 既知の問題

- **O: パネルの 50〜80% が温まったケースを検出できない**。module_wide の条件（基準温度から測った面積比 ≥ 0.80）を満たさず、パネル自身の中央値が高温側になるため、パネル内の高温領域も見つからない（例: 3つのバイパスダイオードのうち2つが作動）。補う判定の追加はユーザーの確認待ち。`tests/test_patterns.py` の xfail のテストで明示している
