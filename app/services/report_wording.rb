# 顧客向けの報告書の言葉（見直し R2。2026-11-09 ユーザー承認）。アプリの専門用語を、顧客に伝わる平易な言葉にする。
# 社内向けの作業記録は、今までどおりアプリの言葉（版名・技術的な理由）で書く
module ReportWording
  module_function

  ANOMALY_TYPES = {
    "hotspot" => "ホットスポット（局所的な発熱）",
    "multi_hotspot" => "複数のホットスポット",
    "substring_bypass" => "パネルの一部が帯状に温かい（バイパスダイオードの作動の可能性）",
    "module_wide" => "パネル全体の発熱",
    "partial_module" => "パネルの一部の発熱",
    "panel_row_group" => "隣り合う複数のパネルの発熱",
    "block_row" => "架台の段全体の温度の高さ",
    "other" => "その他の発熱"
  }.freeze

  MEASURES = {
    "region_max" => "発熱部分の最高温度と周りとの差",
    "region_mean" => "発熱部分の平均温度と周りとの差",
    "panel_mean" => "パネルの平均温度と周りとの差",
    "row_effect" => "段全体の温度と周りとの差（撮影の角度による見かけの違いを除いた値）"
  }.freeze

  EVIDENCE = { "A" => "電気測定でも確認", "B" => "サーモ画像と可視画像で確認", "C" => "サーモ画像で確認" }.freeze

  # 使わなかった画像の理由（社内のキー → 顧客向け）。キーは「要確認の理由」または「alignment_failed:位置合わせの理由」
  UNUSED_REASONS = {
    "alignment_failed" => "画像からパネルの位置を特定できなかった",
    "insufficient_baseline" => "周りに比べられる正常なパネルが少なく、温度を比べられなかった",
    "no_radiometric" => "温度のデータを読めなかった",
    "low_resolution" => "画像の解像度が足りなかった",
    "low_irradiance" => "日射が弱く、温度の差が出にくい条件だった",
    "missing_captured_at" => "撮影時刻が分からなかった",
    "metadata_unreadable" => "画像の撮影情報を読めなかった"
  }.freeze

  # 品質チェックの注意・不合格の理由（キー → 顧客向け）
  QUALITY = {
    "missing_irradiance" => "日射量の記録がない",
    "irradiance_not_poa" => "日射量がパネル面ではなく水平面の値",
    "missing_gps" => "撮影位置の記録がない",
    "low_irradiance" => "日射が弱い",
    "low_resolution" => "解像度が低い",
    "no_radiometric" => "温度のデータがない",
    "missing_captured_at" => "撮影時刻がない",
    "metadata_unreadable" => "撮影情報を読めない"
  }.freeze

  def anomaly_type(type) = ANOMALY_TYPES.fetch(type.to_s, type.to_s)
  def measure(measure) = MEASURES.fetch(measure.to_s, "")
  def evidence(level) = EVIDENCE.fetch(level.to_s, "—")

  def unused_reason(key)
    base = key.to_s.split(":").first
    UNUSED_REASONS.fetch(base, "技術的な理由で解析できなかった")
  end

  def quality(key) = QUALITY.fetch(key.to_s, key.to_s)

  # 段全体を比べられなかった理由（社内の文 → 顧客向け）
  def insufficient_row_reason(text)
    case text.to_s
    when /上側にしか|下側にしか|位置が偏/ then "撮影の角度が偏っていて、段全体の温度を比べられなかった"
    when /少な/ then "写った画像が少なく、段全体の温度を比べられなかった"
    else "段全体の温度を比べられなかった"
    end
  end

  # 用語の説明（巻末。文面はユーザーが確認する）
  GLOSSARY = [
    [ "サーモ画像", "赤外線カメラで撮影した、温度の分布が分かる画像です。" ],
    [ "周りとの温度差", "異常の候補の温度と、同じ画像に写った正常なパネルの温度との差です（℃）。" ],
    [ "ホットスポット", "パネルの一部分だけが局所的に温かくなっている状態です。セルの割れや汚れなどで起きることがあります。" ],
    [ "架台・段", "パネルを載せる台を「架台」、架台の上でパネルが並ぶ横一列を「段」と呼んでいます。" ],
    [ "暫定の判定基準", "異常かどうか・重大度を決める温度差の目安です。依頼元との合意前の仮の値で、今後見直す予定です。" ],
    [ "解析できなかった範囲", "撮影した画像からパネルの位置や温度を確かめられなかった範囲です。異常がないことを示すものではありません。" ],
    [ "日射量での補正", "温度差は日射の強さで変わるため、日射量の記録があれば補正します。記録がない場合は補正していません。" ]
  ].freeze
end
