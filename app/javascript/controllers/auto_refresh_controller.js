import { Controller } from "@hotwired/stimulus"

// 解析待ち・解析中の点検ページを、解析が終わったら自動リロードするコントローラー
const IN_PROGRESS_STATUSES = ["pending", "analyzing"]

export default class extends Controller {
  static values = { url: String, interval: { type: Number, default: 3000 } }

  connect() {
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async refresh() {
    try {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "application/json" }
      })
      const data = await response.json()
      if (!IN_PROGRESS_STATUSES.includes(data.analysis_status)) {
        clearInterval(this.timer)
        window.location.reload()
      }
    } catch (e) {
      // ネットワークエラーは無視
    }
  }
}