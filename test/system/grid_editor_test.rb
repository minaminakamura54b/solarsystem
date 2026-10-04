require "application_system_test_case"

# グリッド入力画面の JS（4隅のクリック・保存・キーボード操作）をブラウザで確かめる
class GridEditorTest < ApplicationSystemTestCase
  setup do
    load_initial_rule_set
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg lowres_T.jpg])
    @first, @second = @inspection.inspection_images.to_a
    @first.update_columns(width: 640, height: 512)
    @previous_offset = Capybara.w3c_click_offset
    Capybara.w3c_click_offset = false # クリック位置を要素の左上からの距離で指定する
  end

  teardown do
    Capybara.w3c_click_offset = @previous_offset
  end

  def visit_editor
    visit grid_inspection_inspection_image_path(@inspection, @first, site_id: @inspection.site_id)
    assert_selector "canvas[data-grid-editor-target='canvas']"
    # canvas の大きさが画像に合うまで待つ
    assert_selector "canvas[width='640']", wait: 5
  end

  test "4隅をクリックしてグリッドを作り、保存すると解析を始める" do
    visit_editor
    find("[data-grid-editor-target='newRows']").fill_in(with: "3")
    find("[data-grid-editor-target='newCols']").fill_in(with: "5")
    click_on "グリッドを追加（4隅をクリック）"
    canvas = find("canvas[data-grid-editor-target='canvas']")
    [ [ 64, 102 ], [ 448, 102 ], [ 448, 307 ], [ 64, 307 ] ].each { |x, y| canvas.click(x: x, y: y) }

    assert_text "グリッド 1"
    assert_text "未保存の変更があります"
    click_on "保存して解析"

    assert_text "グリッド 1 個を保存し、解析を始めました"
    grid = @first.reload.panel_grids.sole
    assert_equal [ 3, 5 ], [ grid["rows"], grid["cols"] ]
    assert_in_delta 0.1, grid["corners"][0][0], 0.01
    assert_in_delta 0.2, grid["corners"][0][1], 0.01
    assert_in_delta 0.7, grid["corners"][2][0], 0.01
  end

  test "未保存の変更があるときは、キーボードで次の画像へ移動しない" do
    visit_editor
    click_on "グリッドを追加（4隅をクリック）"
    canvas = find("canvas[data-grid-editor-target='canvas']")
    [ [ 64, 102 ], [ 448, 102 ], [ 448, 307 ], [ 64, 307 ] ].each { |x, y| canvas.click(x: x, y: y) }

    find("body").send_keys(:arrow_right)

    assert_text "「保存して解析」を押してから移動してください"
    assert_current_path grid_inspection_inspection_image_path(@inspection, @first), ignore_query: true
  end

  test "変更が無ければ、キーボードで次の画像へ移動する" do
    visit_editor

    find("body").send_keys(:arrow_right)

    assert_current_path grid_inspection_inspection_image_path(@inspection, @second), ignore_query: true
  end
end
