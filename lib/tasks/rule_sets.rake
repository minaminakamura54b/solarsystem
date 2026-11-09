# 判定基準（ルールセット）の保守用タスク
namespace :rule_sets do
  # 既存のルールセットに暫定の版の印を付ける（docs/IMPROVEMENT_PLAN.md Phase 7 の決定事項 2026-11-09）。
  # 例: bin/rails "rule_sets:mark_provisional[2026-11-trend-provisional]"
  # 印を付けるだけで、外すことはしない（暫定でない版は、複製して作成の画面で「暫定」を外して作る）。閾値・判定は変えない
  desc "ルールセットに暫定の版の印を付ける"
  task :mark_provisional, [ :version ] => :environment do |_, args|
    rule_set = RuleSet.find_by(version: args[:version].to_s)
    abort "ルールセット「#{args[:version]}」がありません" unless rule_set

    rule_set.mark_provisional!
    puts "ルールセット「#{rule_set.version}」を暫定の版にしました"
  end
end
