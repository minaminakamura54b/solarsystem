puts "シードデータを作成中..."

# 発電所を2件作成
sites_data = [
  { name: "南部第1発電所", location: "山梨県甲府市", panel_count: 48, capacity_kw: 14.4, status: "active" },
  { name: "東部第2発電所", location: "静岡県富士市", panel_count: 30, capacity_kw: 9.0,  status: "active" }
]

sites_data.each do |attrs|
  site = Site.find_or_create_by!(name: attrs[:name]) do |s|
    s.assign_attributes(attrs)
  end

  # パネルを生成（未生成の場合のみ）
  if site.panels.empty?
    cols = Math.sqrt(site.panel_count).ceil
    panels = site.panel_count.times.map do |i|
      statuses = ([ "normal" ] * 40) + ([ "warning" ] * 5) + ([ "error" ] * 3)
      {
        site_id: site.id,
        number: format("P%03d", i + 1),
        position_x: i % cols,
        position_y: i / cols,
        status: statuses.sample,
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    Panel.insert_all(panels)
    puts "  #{site.name}: #{site.panel_count}枚のパネルを生成"
  end

  # 月別収益データ（直近12ヶ月）
  12.downto(1) do |i|
    date = Date.today - i.months
    Revenue.find_or_create_by!(site: site, year: date.year, month: date.month) do |r|
      r.amount_yen = rand(280_000..420_000)
      r.kwh        = rand(8000.0..13000.0).round(1)
    end
  end

  # サンプルアラート
  if site.alerts.empty?
    Alert.create!(
      site: site,
      title: "パネルP012でホットスポットを検出",
      message: "ドローン点検によりP012番パネルに熱異常が確認されました。早急な点検をお勧めします。",
      severity: "critical"
    )
    Alert.create!(
      site: site,
      title: "3枚のパネルで軽微な汚染を検出",
      message: "P003, P008, P021番パネルに鳥の糞による汚染が確認されました。清掃を推奨します。",
      severity: "warning"
    )
  end

  puts "  #{site.name}: 収益・アラートデータを作成"
end

puts "シードデータの作成が完了しました！"
