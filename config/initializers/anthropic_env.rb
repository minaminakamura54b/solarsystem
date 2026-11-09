# Claude の API キー・モデル名は、アプリ専用の SOLARSIGHT_ANTHROPIC_API_KEY・SOLARSIGHT_CLAUDE_MODEL だけを使う
# （2026-11-09 ユーザー承認の修正案 12・案 A）。開発サーバーを起動したシェルに Claude Code などが置いた ANTHROPIC_* が
# あると、公式 SDK が暗黙に読み、意図しないキー・送り先・ヘッダーで送ってしまうため、このプロセスでは取り除く
%w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_PROFILE].each do |name|
  next unless ENV.key?(name)

  ENV.delete(name)
  Rails.logger&.info("環境変数 #{name} はこのアプリでは使わないため取り除きました（SOLARSIGHT_ANTHROPIC_API_KEY・SOLARSIGHT_CLAUDE_MODEL を使います）")
end
