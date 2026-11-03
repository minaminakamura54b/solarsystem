# DJI Thermal SDK の検証の記録（Phase S）

手順は [PHASE_S_RUNBOOK.md](PHASE_S_RUNBOOK.md)。**一部記入済み**（2026-11-03。R-JPEG 1 枚でメタデータまで確認。SDK は未入手のため 3 章以降は未実施）。
顧客の画像のファイル名・撮影場所など、個人や顧客を特定できる情報は書かない。

## 判定

| 項目 | 結果 |
|---|---|
| 温度行列（float32・℃）が取れたか | （未記入） |
| DJI Thermal Analysis Tool の表示と整合したか（差） | （未記入） |
| RGB の位置合わせを固定値にするか | （未記入） |
| Phase 3 以降の前提が成り立つか | （未記入） |

## 1. SDK と機材

- SDK の版: （未入手。2026-11-03 時点）
- 利用規約で確認したこと（再配布・商用利用など）: （未確認）
- 対応カメラの一覧に今回のカメラがあるか: （未確認。**M4T が対応機種に入っているかが最重要**。入っていない場合は DJI Thermal Analysis Tool での書き出しなど別の道を相談する）
- 機体・カメラ: DJI Matrice 4T（`Model` / `DroneModel` = `M4T`、`UniqueCameraModel` = `DJI M4T`）のサーモカメラ（`ImageSource` = `InfraredCamera`）。レンズ 12 mm f/1（35 mm 換算 52 mm）
- ファームウェア: `Software` = `10.00.21.17`。XMP（drone-dji）の版 1.6
- 確認に使った画像: 2026-07-16 撮影のエリア撮影（対地約 40 m）のサーモ 1 枚（`tmp/spike/`。コミットしない）。同じフォルダに同じ番号の `_T.JPG` と `_V.JPG` が並んでいることはユーザーが確認済み（今の組み合わせ方で扱える）

## 2. メタデータ

- 温度データの有無を示すタグ名（→ `config/image_quality.yml` の `radiometric_tags`）: `[DJI] ThermalData`（655,360 バイト = 640×512×2 バイト。画素ごとに 16 ビットの値）、`[DJI] ThermalCalibration`（8,176 バイト）、`[DJI] SensorID`。**今の `radiometric_tags`（ThermalData・ThermalCalibration）で「温度データあり」と仮判定できた**。`ThermalData` は温度そのものではなくセンサーの値と考えられ、温度への変換は SDK で行う（Phase S で確認）
- 撮影時の測定パラメータのタグ名と値（放射率・距離・湿度・反射温度）: **exiftool では見つからない**（`Emissivity`・`ObjectDistance`・湿度・反射温度のタグが無い）。撮影時の値が R-JPEG のどこにあるか、SDK が既定で何を使うかは Phase S で確認する。距離の手がかりとして、レーザー距離計の `LRFTargetDistance`（この画像では約 39 m、`LRFStatus` = `Normal`）がある
- 撮影時刻・GPS・高度・ジンバル角のタグ名と、今の読み取りで取れたか: **すべて今の読み取り（`ImageMetadataExtractor`）で取れた**
  - 撮影時刻: `DateTimeOriginal`（タイムゾーンなし。`capture_time_zone` の Asia/Tokyo として解釈し、ずれは無い）
  - 位置: EXIF の `GPSLatitude` / `GPSLongitude`（WGS-84）と XMP の同名タグ。RTK は FIX（`RtkFlag` = 50、`AltitudeType` = `RtkAlt`、`RtkStdLat/Lon/Hgt` は数 mm）
  - 高度: `RelativeAltitude`（離陸地点からの高さ。この画像は約 40.7 m）→ `altitude_m`。`AbsoluteAltitude` もある
  - ジンバル角: `GimbalPitchDegree` = −90（真下）→ `gimbal_pitch`、`GimbalYawDegree` → `gimbal_yaw`。機体の角度（`FlightYawDegree` など）と速度もある
  - exiftool の警告「Possibly incorrect maker notes offsets」（minor）が出るが、読み取りには影響なし
- サーモと RGB の画像サイズ・焦点距離: サーモ 640×512、12 mm（35 mm 換算 52 mm）。RGB（`_V`）は未入手のため未確認
- 品質チェック（アプリにそのまま通した結果。DB には保存していない）: 「警告」。温度データあり・解像度・撮影時刻・位置情報は合格。警告は日射量が未入力のため
- その他: サーモ画像の表示用の色は `ImageDescription` = `IronRed`。同じフォルダの `.MRK` は RTK の撮影位置の記録（この飛行で 237 件）で、アプリでは使っていない

## 3. 実行環境

- SDK 内の `dji_irp` の位置（→ `DJI_IRP_PATH`）:
- 共有ライブラリの位置（→ `DJI_IRP_LIB_DIR`。`dji_irp` と同じなら不要）:
- `check-sdk` の結果:
- 必要だった OS のパッケージ:

## 4. 温度行列

- 使ったコマンドとオプション（そのまま貼る）:
- 出力の形式（ファイル形式・型・単位・バイト順・大きさ）:
- 1 枚の処理時間（linux/amd64 のエミュレーション / 本番相当）:
- 最小・最大・中央値:
- Thermal Analysis Tool との比較（点・SDK の値・ツールの値・差）:

| 点 (x, y) | SDK | ツール | 差 |
|---|---|---|---|
| | | | |

## 5. 測定パラメータ

- 放射率・反射温度・湿度・距離の指定方法（オプション名）:
- 受け付ける範囲:
- 指定しないときに使われる値（R-JPEG の値か、SDK の既定値か）:
- 放射率を変えたときの温度の変わり方:

## 6. RGB との位置合わせ

- 対応点の JSON（`tmp/spike/` に置いたファイル名）:
- `fit_rgb_alignment.py` の結果（拡大率＋ずれ・アフィン変換の誤差）:
- 別の画像でも同じ値で合ったか:
- 結論（固定値にする / 「おおよその位置」のまま）:

## 7. 注意点・分かったこと

- **解像度（撮影条件として記録。2026-11-03 ユーザー指示）**: この画像（対地約 40 m、真下向き）ではパネル 1 枚が約 30×55 画素、1 セルが約 5 画素四方で、規格の目安（セル当たり 5×5 画素程度。原文で要確認）ぎりぎり。今回のデータは高度を変えられないので、この画像で検証を進める。今後の撮影では、もう少し低い高度（またはズーム）を検討する
- **撮影時刻**: 17:48（7 月）で日が傾いており、パネル面の日射量は 600 W/m² を下回っていた可能性が高い。日射量（POA）を入れると「要確認（日射量不足）」になる。セル単位のホットスポットは見逃しやすい条件
- **エリア撮影**: 1 回の飛行で 200 枚以上（MRK 237 件）。アレイの写る位置が画像ごとに変わるため、グリッドテンプレートの一括適用は効きにくい。**Phase S で温度が読めたら、グリッドの自動提案の精度と、外れたときに直す手間を最優先で確かめる**（ユーザー指示。手順書の手順 7）
