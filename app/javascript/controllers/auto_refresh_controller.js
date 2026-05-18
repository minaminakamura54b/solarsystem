import { Controller } from "@hotwired/stimulus"

// 解析中の点検ページを自動リロードするコントローラー
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
      if (data.analysis_status !== "analyzing") {
        clearInterval(this.timer)
        window.location.reload()
      }
    } catch (e) {
      // ネットワークエラーは無視
    }
  }
}