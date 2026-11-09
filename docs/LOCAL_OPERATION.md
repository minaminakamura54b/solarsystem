# ローカル運用の手順書（実案件を Mac で扱う）

アプリを使うのは 1 人、顧客に渡すのは PDF の報告書だけ、という前提で、Mac の上でアプリを実際の案件に使うための手順です（2026-11-09 ユーザー承認）。
本番サーバーへの公開（Phase 8）は、他の人が使うようになったときに改めて検討します。

## 1. 置き場所の一覧

| もの | 場所 | 備考 |
|---|---|---|
| 実案件のデータベース | PostgreSQL の `solarsystem_work`（キューは `solarsystem_work_queue`） | 開発用の `solarsystem_development` とは別 |
| 実案件の画像（原本の R-JPEG・RGB・報告書の PDF） | `~/SolarSightData/storage` | Mac の内蔵ディスク。リポジトリの外 |
| 実案件の設定 | `~/SolarSightData/config/work.env` | SECRET_KEY_BASE・DJI_IRP_PATH など。リポジトリに入れない（権限 600） |
| 実案件のログ | `~/SolarSightData/log/` | ファイル名などの案件の情報を含むため、リポジトリの外 |
| 解析の一時ファイル | `~/SolarSightData/tmp/analyzer` | 解析が終わると消える |
| 開発用の画像（顧客の画像を含む。検出の調整・業者の報告書との比較に使う） | `~/SolarSightData/development/storage`（Active Storage）、`~/SolarSightData/development/spike`（試しの画像・npy） | 2026-11-09 にリポジトリの `storage/`・`tmp/spike/` から移した |

- 実案件用は `RAILS_ENV=work` で動きます（Rails は `local` という名前を予約しているため `work`）。`bin/local` が自動で付けるので、ふだん打つ必要はありません
- データの置き場所を変えるときは、環境変数 `SOLARSIGHT_DATA_DIR` を指定します（`bin/local`・`bin/local-backup`・`bin/analyzer-container` が同じ値を使います）

## 2. 最初の準備（1 回だけ）

1. FileVault（ディスクの暗号化）が有効になっていることを確かめる（システム設定 → プライバシーとセキュリティ → FileVault）
2. Docker Desktop を起動する
3. 準備を実行する

   ```bash
   bin/local setup
   ```

   データの置き場所（`~/SolarSightData`）、設定ファイル、データベースを作り、判定基準（ルールセット。すべて暫定の印つき）を入れます。開発用のサンプルデータ（発電所・売電収益など）は入りません。
4. `~/SolarSightData/config/work.env` の `DJI_IRP_PATH` に DJI Thermal SDK の dji_irp のパスを書く（開発で使っているものと同じ。例: `/Users/<ユーザー名>/solarsystem/analyzer/bin/dji_thermal_sdk/<版>/utility/bin/linux/release_x64/dji_irp`）
5. 解析エンジンのコンテナを用意する（データの置き場所もマウントされます）

   ```bash
   bin/analyzer-container up
   ```

## 3. 毎回の起動と停止

```bash
# 起動
open -a Docker              # Docker Desktop が起動していなければ
bin/analyzer-container up   # 解析エンジン（2 回目以降は数秒）
bin/local start             # 画面と裏の解析をまとめて起動
# → ブラウザで http://127.0.0.1:3000 を開く

# 状態の確認（いつでも）
bin/local status

# 停止
bin/local stop
bin/analyzer-container down # 解析エンジンも止めるとき（次の up で作り直すので、ふだんは止めなくてよい）
```

- 画面はこの Mac からだけ開けます（127.0.0.1。ログイン機能が無いため、同じネットワークの他の機器からは開けないようにしています）
- 解析の途中で止めても、途中だった画像は次の起動のあと「失敗（長時間終わらなかった）」になります（正常にはなりません）。画面の「再解析」でやり直せます
- ログを見るときは `bin/local logs`（Ctrl-C で終わる）

`bin/local status` の表示の例:

```
アプリ: 動いています（http://127.0.0.1:3000、pid 12345）
解析エンジン: 動いています
解析待ち・解析中の画像: 0 枚
画像の置き場所: /Users/<ユーザー名>/SolarSightData/storage（使用 12G、ディスクの残り 130 GB）
最後のバックアップ: 2026/11/20 18:30 → /Volumes/<ディスク名>/SolarSightBackup
```

ディスクの残りが 30 GB を下回ると警告を出します（`SOLARSIGHT_MIN_FREE_GB` で変えられます）。

## 4. 1 回の飛行の解析にかかる時間の目安

点検 21（1,124 枚）の実績から見積もった値です（Apple M2・Docker の amd64 のエミュレーションで 1 枚あたり約 5.4 秒）。

| 同時に解析する数 | 1,900 枚の目安 |
|---|---|
| 4（既定） | 約 45 分（点検 21 は毎分 40〜50 枚） |
| 1 | 約 3 時間 |

- このほかにアップロードに数分（サーモの画像だけで約 3 GB、RGB を入れると約 10 GB 増える）、パネルごとの候補・架台・段の候補を作るのに約 1 分
- 同時に解析する数は `SOLARSIGHT_ANALYZE_THREADS`（既定 4）。8 コアの Mac では、5 以上にしても Docker のエミュレーションと取り合って速くなりにくい
- 解析中も画面は使えます（`bin/local status` で残りの枚数を確かめられます）

## 5. バックアップ

### 外付けディスクの準備（1 回だけ）

ディスクユーティリティで、外付けディスクを **「APFS（暗号化）」** で初期化します（顧客の画像・位置情報を含むため）。
`bin/local-backup` は、暗号化されていないディスクには書き込みません。

### バックアップの取り方

```bash
bin/local-backup /Volumes/<ディスク名>
```

- **いつ**: 案件ごとに 3 回（解析が終わったあと・レビュー完了のあと・報告書を発行したあと）と、週 1 回
- **何を**:
  - データベース（`solarsystem_work`）: 日付付きのファイル（`SolarSightBackup/db/`）。直近 10 回分を残します（`SOLARSIGHT_BACKUP_KEEP`）。書き出したあと、読めることを確かめます
  - 画像の置き場所: 前回からの差分だけをコピーします（`SolarSightBackup/storage/`）。アプリで消したファイルもバックアップには残ります
  - 設定（`SolarSightBackup/config/`）
- Time Machine（暗号化あり）を使っているなら、2 つ目の控えになります

### 戻し方（Mac が壊れた・データベースを壊したとき）

```bash
bin/local stop
dropdb solarsystem_work                     # 壊れたデータベースがあれば
createdb solarsystem_work
pg_restore --no-owner -d solarsystem_work /Volumes/<ディスク名>/SolarSightBackup/db/<いちばん新しいファイル>.dump
rsync -a /Volumes/<ディスク名>/SolarSightBackup/storage/ ~/SolarSightData/storage/
rsync -a /Volumes/<ディスク名>/SolarSightBackup/config/ ~/SolarSightData/config/
bin/local start
```

### 戻せるかの確認（月 1 回）

```bash
createdb solarsystem_restore_check
pg_restore --no-owner -d solarsystem_restore_check /Volumes/<ディスク名>/SolarSightBackup/db/<いちばん新しいファイル>.dump
psql -d solarsystem_restore_check -c "select count(*) from inspections"   # 点検の数が今と同じか
dropdb solarsystem_restore_check
```

## 6. 顧客の画像・位置情報を Mac に置くときの注意

- 画像の置き場所はリポジトリの外（`~/SolarSightData`）にする。iCloud Drive や、iCloud で同期している「デスクトップ」「書類」には置かない（`bin/local setup` はこれらの場所を断ります）
- FileVault を有効にしたままにする。外付けのバックアップも暗号化する。画面ロックを設定する
- 原本の画像には撮影位置（GPS）が入っており、これも顧客の情報。報告書の PDF には座標を載せていない
- SharePoint の元データは読み取りのみのまま、元本として扱う（アプリには写しを入れる）
- 保管期間が過ぎた案件の扱いは、顧客との取り決めに従って決める（報告書を発行した点検は、今はアプリから削除できない）
- Claude の所見・総括文は、点検ごとに「使う／使わない」を切り替える（**既定は使わない**）。使わない点検では外部のサービスに何も送らず、所見と総括文を点検の画面の「所見・総括（人が書く）」に書く（報告書にはその内容が載る）
- 「使う」にするのは、顧客との取り決めで外部のサービス（Anthropic）での処理が認められていることを確かめた案件だけ（点検の画面で確認の印を付けてから切り替える）。送るのは数値・種類・パネル番号で、画像・座標は送らない。API キーは `~/SolarSightData/config/work.env` の `SOLARSIGHT_ANTHROPIC_API_KEY`・`SOLARSIGHT_CLAUDE_MODEL`
- 送った内容（いつ・何を・結果）は、点検の画面の「外部のサービスへの送信の記録」に点検ごとに残る（消せない）

## 7. 開発用との違い

| | 開発用（`bin/dev`） | 実案件用（`bin/local start`） |
|---|---|---|
| データベース | `solarsystem_development` | `solarsystem_work` |
| 画像 | `~/SolarSightData/development/storage` | `~/SolarSightData/storage` |
| 解析 | アップロードと同時に順に（`:inline`） | 裏で並列に（Solid Queue。同時に 4） |
| 合成データ（.npy） | 使える | 使えない（確かめるときだけ `SOLARSIGHT_ALLOW_NPY=1`） |
| 開発用のタスク（`dev:synthetic_inspection` など）・サンプルデータ | 使える | 使えない・入らない |
| 画面 | localhost:3000 | 127.0.0.1:3000（この Mac からだけ） |

開発用と実案件用を同時に動かすときは、どちらかのポートを変えます（`SOLARSIGHT_PORT=3100 bin/local start`）。

## 8. 困ったとき

| 症状 | 確かめること |
|---|---|
| `bin/local start` で起動しない | `bin/local logs` の最後。データベース（PostgreSQL）が動いているか（`brew services list`） |
| 画像がいつまでも「解析待ち」 | `bin/local status` で解析エンジンが動いているか。止まっていれば `bin/analyzer-container up` |
| 画像が「失敗（解析エンジンを起動できませんでした）」 | 解析エンジンのコンテナ。`bin/analyzer-container status` で DJI Thermal SDK の場所も確かめられる |
| 画像が「失敗（温度データを取得できませんでした）」 | `~/SolarSightData/config/work.env` の `DJI_IRP_PATH` |
| ディスクの残りが少ない | バックアップを取ってから、古い案件の画像の扱いを決める |
