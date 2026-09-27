# 重大度の閾値（ルールセット）の管理。作成済みのルールセットは編集できず、
# 既存のルールセットを複製して新しいバージョンを作り、有効（active）を切り替える
class RuleSetsController < ApplicationController
  def index
    @rule_sets = RuleSet.recent.includes(:severity_rules)
  end

  def show
    @rule_set = RuleSet.find(params[:id])
  end

  def new
    source = params[:from].present? ? RuleSet.find(params[:from]) : (RuleSet.active_set || RuleSet.recent.first)
    if source.nil?
      redirect_to rule_sets_path, alert: "複製元のルールセットがありません（bin/rails db:seed で初期値を投入してください）"
      return
    end
    @source = source
    @rule_set = source.duplicate(version: "")
  end

  def create
    @rule_set = RuleSet.new(rule_set_params)
    detection_params, json_error = parse_detection_params
    @rule_set.detection_params = detection_params
    if json_error.nil? && @rule_set.save
      redirect_to rule_set_path(@rule_set), notice: "ルールセット「#{@rule_set.version}」を作成しました（まだ有効ではありません）"
    else
      # valid? はエラーを消すので、JSON のエラーは検証の後に追加する
      @rule_set.valid?
      @rule_set.errors.add(:detection_params, "の JSON を読めません: #{json_error}") if json_error
      render :new, status: :unprocessable_entity
    end
  end

  def activate
    rule_set = RuleSet.find(params[:id])
    rule_set.activate!
    redirect_to rule_sets_path, notice: "ルールセット「#{rule_set.version}」を有効にしました"
  end

  private

  def rule_set_params
    params.require(:rule_set).permit(:version, :note, severity_rules_attributes: SeverityRule::COPYABLE_ATTRIBUTES)
  end

  # [値, エラーメッセージ] を返す
  def parse_detection_params
    value = JSON.parse(params.dig(:rule_set, :detection_params_json).to_s)
    value.is_a?(Hash) ? [ value, nil ] : [ {}, "オブジェクト（{ ... }）で入力してください" ]
  rescue JSON::ParserError => e
    [ {}, e.message ]
  end
end
