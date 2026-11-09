import { Controller } from "@hotwired/stimulus"

// 点検の対象範囲（見直し R1）。配置図の架台をクリックすると、対象に入れる・外すを切り替える。
// チェックボックス（name="block_ids[]"）が正本で、図の色はそれに合わせる
export default class extends Controller {
  static targets = ["block", "checkbox", "count"]
  static values = { proposal: Array }

  connect() { this.refresh() }

  toggle(event) {
    const id = event.currentTarget.dataset.blockId
    const box = this.checkboxTargets.find((c) => c.value === id)
    if (box) { box.checked = !box.checked; this.refresh() }
  }

  refresh() {
    const selected = new Set(this.checkboxTargets.filter((c) => c.checked).map((c) => c.value))
    this.blockTargets.forEach((p) => {
      p.setAttribute("fill", selected.has(p.dataset.blockId) ? "#1d9e75" : "#3f3f46")
    })
    if (this.hasCountTarget) this.countTarget.textContent = `${selected.size} 基を選んでいます`
  }

  selectProposal(event) {
    event.preventDefault()
    const ids = new Set(this.proposalValue.map(String))
    this.checkboxTargets.forEach((c) => { c.checked = ids.has(c.value) })
    this.refresh()
  }

  selectAll(event) { event.preventDefault(); this.checkboxTargets.forEach((c) => { c.checked = true }); this.refresh() }
  clearAll(event) { event.preventDefault(); this.checkboxTargets.forEach((c) => { c.checked = false }); this.refresh() }
}
