# Chromium 用の seccomp プロファイル

報告書の PDF（ferrum_pdf）は Chromium で作る。Docker の中でも Chromium のサンドボックスを外さない（`--no-sandbox` を使わない）ために、
コンテナを次のプロファイルで動かす（2026-11-09 ユーザー指示）。

```bash
docker run --security-opt seccomp=config/seccomp/chromium.json ...
```

## 出どころとライセンス

- `chromium.json` は Docker（moby）の既定の seccomp プロファイルに、1 つの規則を足したもの
  - 元: https://github.com/moby/profiles/blob/main/seccomp/default.json（コミット 6fe7deb1b9fb7c0397a4593480d7d22b9ee8caef、2026-09-17）
  - ライセンス: Apache License 2.0（moby/profiles）
- 足した規則: `clone`・`unshare` を条件なしで許可する（`syscalls` の最後の要素。`comment` に理由）
  - Chromium のサンドボックスは、ユーザー・PID・ネットワークの名前空間を作るために `clone`（名前空間のフラグ付き）と `unshare` を使う
  - Docker の既定では、これらは CAP_SYS_ADMIN を持つコンテナにしか許可されない。CAP_SYS_ADMIN を与えると `mount`・`bpf` などもまとめて許可されるため、
    必要な 2 つだけを足した。`setns`・`mount` などは既定のまま許可しない
- 元のプロファイルを更新するときは、同じ手順（元の JSON に上の 1 規則を足す）で作り直し、この README のコミットと日付を書き換える

## 確かめたこと（2026-11-09、Mac の Docker Desktop・linux/amd64 のエミュレーション）

- Docker の既定の seccomp では、Chromium が「No usable sandbox!」で起動しない（`--no-sandbox` を付けない限り動かない）
- このプロファイルでは、サンドボックスを使ったまま起動し、報告書の HTML から A4 の PDF を作れた（`rails` ユーザー、`--no-sandbox` なし）。
  PDF には Noto Sans CJK JP が埋め込まれ、日本語は化けなかった
- Debian の `/usr/bin/chromium`（起動スクリプト）は CPU の sse3 を確かめて止まり、エミュレーションでは起動できないため、
  Dockerfile で `BROWSER_PATH=/usr/lib/chromium/chromium`（本体）を指定している

```bash
docker run --rm --security-opt seccomp=config/seccomp/chromium.json --entrypoint sh <イメージ> \
  -c '/usr/lib/chromium/chromium --headless --disable-gpu --dump-dom about:blank'
```

## 注意

- コンテナは root ではなく `rails` ユーザー（Dockerfile）で動かす。Chromium は root ではサンドボックスを使えない
- ホストのカーネルで、特権の無いユーザー名前空間が使えること（Ubuntu 24.04 以降は AppArmor の設定で制限されている場合がある。本番サーバーを決めるときに確かめる）
