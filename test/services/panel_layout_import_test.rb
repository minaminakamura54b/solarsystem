require "test_helper"

class PanelLayoutImportTest < ActiveSupport::TestCase
  setup do
    @site = sites(:south) # 仮配置のパネル P001〜P003
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
  end

  def import(text) = PanelLayoutImport.new(@site, text)

  def apply(text)
    importer = import(text)
    assert importer.valid?, importer.errors.inspect
    importer.apply!(expected_digest: importer.plan.digest)
  end

  def anomaly(**attrs)
    @image.anomalies.create!({ inspection: @inspection, anomaly_type: "hotspot", severity: "warning", review_status: "confirmed", locked: true }.merge(attrs))
  end

  CSV_EN = <<~CSV.freeze
    panel_number,position_x,position_y,row_number,string_number,position_in_string,pcs_number,gps_lat,gps_lng
    A-01-01,0,0,A,S01,1,PCS1,35.6,138.5
    A-01-02,1,0,A,S01,2,PCS1,,
  CSV

  test "英語の列名で読み、すべての列を取り込む" do
    rows = import(CSV_EN).rows

    assert_equal 2, rows.size
    assert_equal({ "panel_number" => "A-01-01", "position_x" => 0, "position_y" => 0, "row_number" => "A", "string_number" => "S01",
                   "position_in_string" => 1, "pcs_number" => "PCS1", "gps_lat" => 35.6, "gps_lng" => 138.5 }, rows.first)
    assert_nil rows.last["gps_lat"]
  end

  test "日本語の列名（全角の英数字も可）・必須の列だけ・列の順番が違っても読む" do
    text = "Ｙ位置,パネル番号,X位置,パワコン番号,ストリング内位置,列番号,ストリング番号,緯度,経度\n0,B-1,3,ＰＣＳ２,1,B,S2,,\n"

    importer = import(text)

    assert importer.valid?, importer.errors.inspect
    assert_equal [ "B-1", 3, 0, "PCS2" ], importer.rows.first.values_at("panel_number", "position_x", "position_y", "pcs_number")
    assert import("panel_number,position_x,position_y\nC-1,0,0\n").valid?
  end

  test "Shift_JIS と BOM 付きの UTF-8 を読む" do
    text = "パネル番号,X位置,Y位置\nA-1,0,0\n"

    assert_equal text, PanelLayoutImport.decode(text.encode("Windows-31J").b)
    assert_equal text, PanelLayoutImport.decode("﻿#{text}".b)
    assert import(text.encode("Windows-31J").b).valid?
    assert_raises(PanelLayoutImport::Error) { PanelLayoutImport.decode("\xFF\xFE\xFA".b) }
  end

  test "列名の誤り・必須の列の不足・同じ項目の重複はエラーにする" do
    assert_includes import("panel_number,position_x,position_y,memo\nA,0,0,x\n").errors, "知らない列名です: 「memo」"
    assert_includes import("panel_number,position_x\nA,0\n").errors, "必須の列がありません: position_y / Y位置"
    assert_includes import("panel_number,パネル番号,position_x,position_y\nA,A,0,0\n").errors, "同じ項目の列が複数あります: 「パネル番号」"
  end

  test "行のエラーは行番号付きで出し、1 行でもエラーがあれば何も取り込まない" do
    text = <<~CSV
      panel_number,position_x,position_y,position_in_string,gps_lat
      A,0,0,1,35
      ,1,0,,
      B,-1,x,0,95
      A,2,0,,
      C,0,0,,
    CSV

    importer = import(text)

    assert_not importer.valid?
    assert_empty importer.rows
    assert_includes importer.errors, "3 行目: パネル番号が空です"
    assert_includes importer.errors, "4 行目: position_x / X位置 は 0 以上の整数にしてください"
    assert_includes importer.errors, "4 行目: position_y / Y位置 は 0 以上の整数にしてください"
    assert_includes importer.errors, "4 行目: ストリング内位置は 1 以上の整数にしてください"
    assert_includes importer.errors, "4 行目: gps_lat / 緯度 が正しくありません"
    assert_includes importer.errors, "パネル番号「A」が重複しています（2 行目、5 行目）"
    assert_includes importer.errors, "位置（0, 0）が重複しています（2 行目、6 行目）"
    assert_raises(PanelLayoutImport::Error) { importer.apply!(expected_digest: "x") }
    assert_equal 3, @site.panels.count
  end

  test "空の CSV・行の無い CSV はエラー" do
    assert_includes import("").errors, "必須の列がありません: panel_number / パネル番号、position_x / X位置、position_y / Y位置"
    assert_includes import("panel_number,position_x,position_y\n\n").errors, "パネルの行がありません"
  end

  test "仮配置を実配置に置き換え、パネル枚数を CSV の件数にする（状態は normal・最終点検日時なし）" do
    apply(CSV_EN)

    panels = @site.panels.reload.order(:number)
    assert_equal %w[A-01-01 A-01-02], panels.map(&:number)
    assert panels.all? { |p| p.layout_source == "manual" && p.status == "normal" && p.last_inspected_at.nil? }
    assert_equal [ "PCS1", "A", "S01", 1 ], panels.first.attributes.values_at("pcs_number", "row_number", "string_number", "position_in_string")
    assert_equal 2, @site.reload.panel_count
  end

  test "仮配置に紐付いた異常は紐付けを外し、元の番号を履歴に残し、割り当て直しの対象にする。判定・点検の状態は変えない" do
    p001 = panels(:p001)
    confirmed = anomaly(panel: p001)
    rejected = anomaly(panel: p001, review_status: "rejected", rejection_reason: "glare")
    alert = Alert.create!(site: @site, panel: p001, title: "テスト", severity: "critical")
    @image.update_columns(analysis_status: "completed")
    @inspection.refresh_status!
    InspectionReview.new(@inspection).complete!(all_images_checked: true)
    before = @inspection.reload.attributes.slice("analysis_status", "severity", "reviewed_at")

    plan = apply(CSV_EN)

    assert_equal 2, plan.anomalies.size
    assert_equal [ confirmed ], plan.reassignment_anomalies
    confirmed.reload
    assert_nil confirmed.panel_id
    assert confirmed.panel_reassignment_required
    assert_equal({ "panel_number" => "P001", "layout_source" => "auto", "reason" => "layout_replaced" },
                 confirmed.panel_assignment_history.last.except("unassigned_at"))
    assert_equal [ "confirmed", "warning", true ], [ confirmed.review_status, confirmed.severity, confirmed.locked ]
    rejected.reload
    assert_nil rejected.panel_id
    assert_not rejected.panel_reassignment_required, "却下した異常は割り当て直しの一覧に出さない"
    assert_equal "P001", rejected.panel_assignment_history.last["panel_number"]
    assert_nil alert.reload.panel_id
    assert_equal "テスト", alert.title
    assert_equal before, @inspection.reload.attributes.slice("analysis_status", "severity", "reviewed_at")
  end

  test "仮配置のパネルは、番号が同じでも引き継がない" do
    p001 = panels(:p001)
    target = anomaly(panel: p001)

    apply("panel_number,position_x,position_y\nP001,5,5\n")

    panel = @site.panels.reload.sole
    assert_equal [ "P001", "manual" ], [ panel.number, panel.layout_source ]
    assert_not_equal p001.id, panel.id
    assert_nil target.reload.panel_id
    assert target.panel_reassignment_required
  end

  test "2 回目は、番号が同じ実配置のパネルを更新し（紐付け・状態を残す）、CSV から消えたパネルの異常は外して一覧に出す" do
    apply(CSV_EN)
    kept = @site.panels.find_by!(number: "A-01-01")
    removed = @site.panels.find_by!(number: "A-01-02")
    kept.update_columns(status: "warning", last_inspected_at: Time.zone.parse("2026-10-01"))
    on_kept = anomaly(panel: kept)
    on_removed = anomaly(panel: removed)

    importer = import("panel_number,position_x,position_y\nA-01-01,9,9\nA-02-01,1,0\n")
    plan = importer.plan
    assert_equal [ 1, 1, 0, 1 ], [ plan.creates.size, plan.updates.size, plan.placeholder_deletes, plan.manual_deletes ]
    assert_equal [ on_removed ], plan.anomalies_from("manual")
    importer.apply!(expected_digest: plan.digest)

    kept.reload
    assert_equal [ 9, 9, "warning", nil ], [ kept.position_x, kept.position_y, kept.status, kept.pcs_number ]
    assert kept.last_inspected_at.present?
    assert_equal kept.id, on_kept.reload.panel_id
    assert_not on_kept.panel_reassignment_required
    assert_nil on_removed.reload.panel_id
    assert on_removed.panel_reassignment_required
    assert_equal({ "panel_number" => "A-01-02", "layout_source" => "manual" }, on_removed.panel_assignment_history.last.slice("panel_number", "layout_source"))
    assert_equal %w[A-01-01 A-02-01], @site.panels.reload.order(:number).map(&:number)
  end

  test "確認画面の後にデータが変わっていたら置き換えない" do
    importer = import(CSV_EN)
    digest = importer.plan.digest
    anomaly(panel: panels(:p002)) # 確認画面の後に、消えるパネルへ異常が紐付いた

    assert_raises(PanelLayoutImport::StalePlan) { importer.apply!(expected_digest: digest) }
    assert_equal %w[P001 P002 P003], @site.panels.reload.order(:number).map(&:number)
    assert_equal 3, @site.reload.panel_count
  end

  test "人がパネルを割り当て直すと、割り当て直しの対象から外れる（履歴は残す）" do
    target = anomaly(panel: panels(:p001))
    apply(CSV_EN)

    AnomalyReview.new(target.reload).assign_panel!(@site.panels.find_by!(number: "A-01-01"))

    target.reload
    assert_not target.panel_reassignment_required
    assert_equal "A-01-01", target.panel.number
    assert_equal "P001", target.panel_assignment_history.last["panel_number"]
  end

  test "異常が紐付いたパネルは、紐付けを外さずには削除できない" do
    anomaly(panel: panels(:p001))

    assert_raises(ActiveRecord::DeleteRestrictionError) { panels(:p001).destroy }
  end

  test "雛形の CSV は英語の列名で、そのまま読み込める" do
    template = PanelLayoutImport.template_csv

    assert template.start_with?("panel_number,position_x,position_y,row_number,string_number,position_in_string,pcs_number,gps_lat,gps_lng\n")
    assert import(template).valid?
  end
end
