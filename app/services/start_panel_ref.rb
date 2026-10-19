# グリッドの start_panel_ref の形式（docs/IMPROVEMENT_PLAN.md Phase 5b。2026-10-19 ユーザー承認）。
# グリッドの左上（行 0・列 0）のパネルが、実配置のどのパネルかを表す: { "panel_number" => "A-01-01" }
# 形式を決めて、入力されたときに実配置に存在するかを確かめるだけ。入力欄と、ここからのパネルの自動提案は作らない。
# グリッドの向きと実配置の向きの対応は、自動提案を作るときに決める（ドローンの撮影方向で変わるため）
module StartPanelRef
  module_function

  # 形式を確かめて正規化する。空なら nil。不正なら ArgumentError
  def normalize(value)
    return nil if value.blank?
    raise ArgumentError, "左上のパネル（start_panel_ref）は {\"panel_number\": \"パネル番号\"} の形で指定してください" unless value.respond_to?(:to_h)

    ref = value.to_h.stringify_keys
    number = ref["panel_number"].to_s.strip
    if number.empty? || ref.keys != [ "panel_number" ]
      raise ArgumentError, "左上のパネル（start_panel_ref）は {\"panel_number\": \"パネル番号\"} の形で指定してください"
    end

    { "panel_number" => number }
  end

  # 実配置（layout_source manual）のパネルとして存在するかを確かめる。無ければ ArgumentError
  def verify!(site, ref)
    return if ref.nil?
    return if site.panels.where(layout_source: "manual", number: ref["panel_number"]).exists?

    raise ArgumentError, "左上のパネル「#{ref['panel_number']}」は、この発電所の実配置のパネルにありません"
  end
end
