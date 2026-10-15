require "application_system_test_case"

# レビュー画面の JS（キーボード操作・ドラッグでの範囲指定）をブラウザで確かめる
class ReviewTest < ApplicationSystemTestCase
  setup do
    load_initial_rule_set
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
    @image.update_columns(width: 640, height: 512)
    two = [ analyzer_anomaly, analyzer_anomaly("panel_index" => 9, "bbox" => { "x1" => 0.6, "y1" => 0.4, "x2" => 0.62, "y2" => 0.43 }) ]
    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output(anomalies: two))) { AnalyzeInspectionImageJob.perform_now(@image.id) }
    @first, @second = @image.anomalies.order(:panel_index_in_image).to_a
    @previous_offset = Capybara.w3c_click_offset
    Capybara.w3c_click_offset = false
  end

  teardown do
    Capybara.w3c_click_offset = @previous_offset
  end

  def visit_review
    visit review_inspection_path(@inspection, image: 1, site_id: @inspection.site_id)
    assert_selector "canvas[data-review-target='overlay'][width='640']", wait: 5
  end

  test "j で次の候補に移り、c で確定する" do
    visit_review

    find("body").send_keys("j")
    find("body").send_keys("c")

    assert_text "異常（画像 1・パネル 9）を更新しました"
    assert_equal "confirmed", @second.reload.review_status
    assert_equal "pending", @first.reload.review_status
  end

  test "x は却下の理由を選んでいなければ理由の選択に案内する" do
    visit_review

    find("body").send_keys("x")

    assert_text "却下の理由を選んでから、却下ボタンを押してください"
    assert_equal "pending", @first.reload.review_status
  end

  test "画像の上をドラッグして範囲を指定し、見逃しを追加する" do
    visit_review
    find("#manual summary").click
    click_on "画像の上で範囲を指定"
    canvas = find("canvas[data-review-target='overlay']")
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", canvas.native)
    width, height = page.evaluate_script("[arguments[0].width, arguments[0].height]", canvas.native)
    # Selenium の move_to は要素の中心からの距離。画像の (10%, 12.5%) から (20%, 25%) までドラッグする
    page.driver.browser.action
        .move_to(canvas.native, (width * 0.1 - width / 2.0).round, (height * 0.125 - height / 2.0).round).click_and_hold
        .move_to(canvas.native, (width * 0.2 - width / 2.0).round, (height * 0.25 - height / 2.0).round).release.perform
    assert_text "範囲を指定しました"
    select "注意", from: "severity"
    click_on "見逃しを追加"

    assert_text "見逃しを追加しました"
    manual = @image.anomalies.find_by!(detection: "manual")
    assert_in_delta 0.1, manual.bbox["x1"], 0.02
    assert_in_delta 0.25, manual.bbox["y2"], 0.02
  end
end
