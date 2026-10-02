# AGENTS.md

このリポジトリで作業するコーディングエージェント向けの案内です。

## 規律

このリポジトリの規律は **[CLAUDE.md](CLAUDE.md)** と **[docs/IMPROVEMENT_PLAN.md](docs/IMPROVEMENT_PLAN.md)** に従ってください。

- 作業の進め方、必ず止まって確認する場面、禁止事項、点検アプリとして絶対に守ること、コマンドは CLAUDE.md にあります
- 仕様・フェーズ・データモデルの正本は docs/IMPROVEMENT_PLAN.md です。自律して進めてよい範囲は、その末尾の「作業の進め方（自律して進めてよい範囲）」にあります
- このファイルと CLAUDE.md・指示書が食い違う場合は、CLAUDE.md と指示書を優先してください

## 用語の注意

アプリのコード・ドキュメントに出てくる「**Claude**」は、アプリが呼び出す **Claude API**（Anthropic の大規模言語モデル）のことです。**コーディングエージェントのことではありません。**

例:
- 「Claude に画像を見せて判定させる方式」「Claude には判定させない」「Claude の役割は所見を書くこと」→ いずれもアプリ内で使う Claude API の話
- `ClaudePanelAnalyzer`、`CLAUDE_MODEL`、`ANTHROPIC_API_KEY` → Claude API の呼び出しと設定

CLAUDE.md というファイル名は、Claude Code（コーディングエージェント）が読む設定ファイルの名前です。中身の規律はどのエージェントにも当てはまります。
