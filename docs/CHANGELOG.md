# CHANGELOG

## 2026-09-27 — Phase 2: データモデルと品質チェック（ブランチ `phase-2`）

### 追加
- **複数画像の点検（セッション）**: `inspection_images`。サーモ画像（R-JPEG 原本）と同時撮影の RGB を、ファイル名の `_T` / `_V` で自動ペアリング（RGB は画像ごとに手動で添付・差し替え・削除できる）。Active Storage の直接アップロード
- **メタデータの読み取り**: exiftool（gem は使わずコマンドを呼ぶ）。撮影時刻・カメラ・解像度・GPS・高度・ジンバル角。温度データの有無はタグによる**仮判定**（最終判定は Phase 3）
- **品質チェック** `ImageQualityChecker`（閾値は `config/image_quality.yml`）。温度データなし・判定不能・低解像度・撮影時刻なし・POA 日射量 600 W/m² 未満は `needs_review`（理由付き）。GPS なし・日射量未入力・GHI は warning
- **気象データ**: 点検ごとに時刻付きで複数登録。画像の撮影時刻で補間して割り当て、変更したら品質チェックをやり直す
- **画像の除外**: 要確認・失敗の画像を理由付きで `excluded` にでき、取り消せる。点検全体のステータスは除外した画像を除いて集計
- **判定基準（ルールセット）**: `rule_sets` / `severity_rules`、初期値のシード（`db/seeds/rule_sets.rb`、`2026-09-initial`）、管理画面（一覧・詳細・複製して作成・有効化）。作成後は編集・削除できない
- **テーブルのみ**（書き込みは Phase 4 以降）: `anomalies`、`anomaly_groups`、`grid_templates`
- **発電所のモジュール仕様**: 型番・定格W・セル構成・サブストリング数・バイパス作動時の発熱パターン（JSON）
- Dockerfile と CI に exiftool（`libimage-exiftool-perl`）を追加

### 変更
- `inspections.anomalies` を `legacy_anomalies` にリネーム（データ移行はしない。旧方式の点検の表示だけで使う）
- 新しい点検では旧方式の Claude 判定を行わない（ユーザー承認）。旧方式の点検は従来どおり表示できる
- **パネルの自動生成は「仮配置」として残す**（既知の問題 F。ユーザー承認）。`panels.layout_source` を追加し、ダッシュボードとフォームに仮配置と表示
- **既存パネルの status を normal に戻すマイグレーション**（ユーザー承認）。warning / error はシードのランダム値と削除済みの並び順割り当ての名残で根拠がないため。ロールバックしても戻らない。シードもランダムな status を作らないように変更
- 発電所の更新後のリダイレクト先を一覧に変更（詳細画面のビューが無くエラーになっていたため。既知の問題 L）
- 発電所フォームで新規登録画面が開けなかった不具合を修正（`defined?(method)` が組み込みメソッドを指していた。既知の問題 N。Phase 2 以前から）
- 自動更新の JSON に `in_progress` を追加し、JS はそれを優先して使う
- CLAUDE.md と指示書の「止まって確認する場面」に「指示と違う方法・広い範囲で実装するとき」を追加

### 記録した既知の問題
- I（追記）: 品質チェックのジョブのプロセスが落ちると、画像が品質チェック待ちのまま残る → Phase 4-9 のタイムアウト処理に含める
- K: アプリのタイムゾーンが UTC のまま（撮影時刻・気象データだけ Asia/Tokyo で扱う）
- L: 発電所の詳細画面が無い（更新後は一覧に戻す最小限の修正のみ）
- M: 温度データのタグは実画像で未確認（Phase S で見直す）

### 確認したこと
- テスト 177 件（受け入れ確認「温度データの無い JPEG が needs_review になり理由が画面に出る」は実際の exiftool で確認）、rubocop、brakeman、bundler-audit、importmap audit、シードの再投入
- マイグレーション7本は実行・ロールバック・再実行できる（パネル status のリセットはロールバックしても戻らない）
- 開発 DB: パネル 78 枚の status を normal に戻した（うち 18 枚が warning / error だった）。ルールセットの初期値を投入

## 2026-09-27 — Phase 1: 安全修正（ブランチ `phase-1`）

### 変更
- **解析失敗を normal（正常）として保存しない**
  - マイグレーション: `inspections.severity` の NOT NULL とデフォルト `normal` を外し、`error_message` を追加。既存の `failed` の点検は severity を NULL にする（開発 DB では9件が対象）
  - `Inspection`: severity は completed のときだけ必須。nil は「判定なし」（グレーのバッジ）
  - `ClaudePanelAnalyzer`: 失敗の経路（壊れた JSON・途中で切れた応答・JSON なし・severity の欠落や想定外の値・API エラー・例外・画像なし）はすべて `error` 付き・`severity: nil`
- **失敗時にパネル・アラートを変更しない**。`failed` への更新はトランザクションの外で `update_columns`（`updated_at` も更新）
- **ジョブの保存処理をトランザクション化**（結果保存・`last_inspected_at` 更新・アラート作成）。途中で失敗したら何も残さない
- **並び順によるパネル status の割り当てを削除**
- **アラートは1つの点検につき1件**。再解析で更新し、重大度が上がったら未読に戻す。再解析の失敗・異常0件では既存のアラートを変更しない
- **点検詳細を読み取り専用に**（GET で DB に書き戻し、normal で上書きしていた処理を削除）
- **pending でも自動更新**（画面と JS の両方。JS は pending / analyzing の間は再読み込みしない）
- **画像なしの点検は作成不可**（422、解析ジョブも登録しない）
- 失敗時の詳細画面に `error_message` と「正常とは限りません」を表示。ダッシュボードの直近の点検で、完了していない点検の重要度を表示しない
- **件数・重大度・異常一覧が食い違う応答を失敗扱いに**（既知の問題 J）。`anomaly_count` と異常一覧の件数の不一致、重大度 normal なのに異常あり／warning・critical なのに異常なし、異常一覧の形式不正は `failed`。`anomaly_count` が無いときは異常一覧の件数を使う
- 指示書の末尾に「作業の進め方（自律して進めてよい範囲）」を追加（ユーザー記入）。CLAUDE.md から参照
- テスト: 「現状: …」の18件を反転し、79件に（トランザクション・アラート方針・読み取り専用・応答の食い違いなどを追加）

### 見送り
- 送信前の画像縮小（Phase 1 の項目 11）。現行の Claude 方式は実案件に使わないため

### 記録した既知の問題
- I: ワーカーが落ちると `analyzing` のまま残る → Phase 4 にタイムアウト処理として追記
- J: `anomaly_count` が無い・食い違う応答でアラートが出ないことがある → 指示を受けて Phase 1 で対応

### 確認したこと
- 開発 DB のアラートに、同じ点検への重複はない（アラート8件・重複0件）。本番 DB は未確認

## 2026-09-27 — Phase 0: 土台づくり（ブランチ `phase-0`）

### 追加
- `docs/ARCHITECTURE.md`: 現状の構成・画面・データモデル・解析フロー・既知の問題（指示書に無かった A〜H を含む）
- テストの土台（それまでテストは0件）
  - fixtures（site / panel / inspection / alert）と合成の 8x8 PNG
  - 偽クライアント `FakeAnthropicClient` と `with_fake_claude` ヘルパー
  - 現状の挙動テスト 50件（services / jobs / controllers / models / 主要画面のスモーク）
  - Phase 1 で直す挙動は「現状: …（Phase 1 で…に変更）」の名前で記録
- `docs/CHANGELOG.md`（このファイル）

### 変更
- `ClaudePanelAnalyzer`: `client:` 引数とクラスレベルの `default_client` を追加（テストで偽クライアントを差し込むため）。本番は両方 nil で挙動は変わらない
- `.gitignore`: `.env.example` をコミット対象にし、`analyzer/bin/`（DJI SDK）と `tmp/spike/`（検証用の実画像）を除外対象に追加
- `.env.example`: `CLAUDE_MODEL` と `DJI_IRP_PATH` を追加
- `README.md`: 環境変数の手順を `.env.example` のコピーに変更、テストとブランチ運用の説明を追加
- `docs/IMPROVEMENT_PLAN.md`: Phase 1 に「show の読み取り専用化」「severity の validation を completed のときだけ必須に」「自動更新の JS 側の修正」を追記。既知の問題 D（画像なしの点検作成）と E（ジョブのトランザクション）を Phase 1 に前倒し
- `Gemfile.lock`: brakeman を 8.0.4 → 8.0.6 に更新（`bin/brakeman` の `--ensure-latest` で終了コード 5 になり CI が失敗していたため）

### 確認したこと
- git の全履歴に `.env`・`config/master.key`・API キーらしき文字列のコミットはない（`config/credentials.yml.enc` は暗号化済みのファイルで問題なし）
- テスト環境の Active Storage は `:test` サービス（`tmp/storage/`）を使う設定になっている
