# Claude の所見（AnomalyExplainer）と点検の総括文（InspectionSummaryWriter）を保存する列（docs/IMPROVEMENT_PLAN.md Phase 6）。
# 列を足すだけで、既存の値は変えない。
# anomalies は cause_candidates / recommended_action / explanation（= reasoning）/ prompt_version を Phase 0 から持っている
class AddExplanationFields < ActiveRecord::Migration[8.1]
  def change
    change_table :anomalies, bulk: true do |t|
      t.jsonb :additional_checks
      t.text :report_text
      t.string :explanation_input_digest
      t.datetime :explained_at
      t.text :explanation_error
    end

    change_table :anomaly_groups, bulk: true do |t|
      t.jsonb :cause_candidates
      t.text :explanation
      t.jsonb :additional_checks
      t.text :recommended_action
      t.text :report_text
      t.string :prompt_version
      t.string :explanation_input_digest
      t.datetime :explained_at
      t.text :explanation_error
    end

    change_table :inspections, bulk: true do |t|
      t.text :summary_text
      t.jsonb :summary_priority_actions
      t.jsonb :summary_additional_checks
      t.string :summary_prompt_version
      t.string :summary_input_digest
      t.datetime :summary_generated_at
      t.text :summary_error
    end
  end
end
