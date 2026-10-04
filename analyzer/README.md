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
  contract.py               入出力の約束（pydantic、schema_version 2.1）
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

## 分類の決まりごと

パネルごとに2つの判定を独立に行い、それぞれの結果を出力します（出力の `detection` に、どちらの判定かが入ります）。

- **局所的な判定**（`local`）: パネル自身の中央値から見た高温領域で、hotspot / multi_hotspot / substring_bypass / partial_module を判定
- **基準温度からの判定**（`baseline`）: パネル平均の ΔT が **module_wide の mild** 以上のとき、「基準温度 + module_wide の mild を超える画素」で領域を取り直し、module_wide（面積比 ≥ 0.80）/ substring_bypass（帯に一致）/ partial_module を判定。パネルの 50〜80% が温まると、パネル自身の中央値が高温側になり局所的な判定では見つからないため（2026-10-04 追加。既知の問題 O への対応）
- **両方に当てはまれば別々に出力**（例: 2/3 の帯 ＋ その中のホットスポット、module_wide ＋ その中のホットスポット）。ただし基準温度からの判定で異常が出たパネルでは、局所的な判定の substring_bypass / partial_module は同じ発熱の二重計上になるため出さない
- **substring_bypass は作動した帯の本数を `active_bands` に出す**（連続した k 本、または離れた複数の帯の合計。Phase 7 の損失計算で使う）
- **どれにも当てはまらない高温領域**: すべて `partial_module`。ルールセットに `other` の閾値が無いため、解析エンジンは `other` を出さない（`other` はレビューで人が使う）
- **グレア疑い**: 面積がパネルの 0.3% 未満の高温領域があればフラグを付ける（検出は消さない）。「セル境界と無関係」は、セル配置の情報が無いため判定しない（TODO）
- **高温領域の最小画素数**: `config/default_params.json` の `min_region_pixels`（既定 1）。これより小さい連結領域は使わない。**実画像を見てから調整する**

### 帯の向き（band_axis）の解釈 — 仮

**実画像で確認するまでの仮の解釈です。** `band_axis` の辺を `bands` 等分した帯として扱います（`short_side` なら短辺を等分し、帯は長辺方向に伸びる）。k 本の帯との一致の条件は、与えられた値だけで作っています:

- 面積比が `k × band_area_ratio ± tolerance`
- 帯が伸びる方向に、パネルの `(1 − tolerance)` 以上にわたっている
- 等分する方向の幅が、パネルの `(k × band_area_ratio + tolerance)` 以下

Phase S 以降に実画像でバイパス発熱の向きを確認し、解釈が違えば見直します（2026-10-03 ユーザー確認、2026-10-04 仮の解釈として明記）。

## 既知の問題

- ~~O: パネルの 50〜80% が温まったケースを検出できない~~ → 2026-10-04 に「基準温度からの判定」を追加して対応済み
