import { Controller } from "@hotwired/stimulus"

// 解析待ち・解析中の点検ページを、解析が終わったら自動リロードするコントローラー。
// 上限時間（max）を超えたらポーリングを止め、「解析が長時間終わっていません」と表示する
// （ワーカーが落ちて analyzing のまま残った場合に、自動更新が止まらなくなるのを防ぐ）
const IN_PROGRESS_STATUSES = ["pending", "analyzing"]

export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 3000 },
    max: { type: Number, default: 15 * 60 * 1000 }
  }

  connect() {
    this.startedAt = Date.now()
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async refresh() {
    if (Date.now() - this.startedAt > this.maxValue) {
      clearInterval(this.timer)
      this.showTimeoutMessage()
      return
    }
    try {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "application/json" }
      })
      const data = await response.json()
      // in_progress があればそれを使う（複数画像の点検は、品質チェック待ち・解析中の画像があるかで決まる）
      const inProgress = "in_progress" in data ? data.in_progress : IN_PROGRESS_STATUSES.includes(data.analysis_status)
      if (!inProgress) {
        clearInterval(this.timer)
        window.location.reload()
      }
    } catch (e) {
      // ネットワークエラーは無視
    }
  }

  showTimeoutMessage() {
    const message = document.createElement("p")
    message.className = "text-xs"
    message.style.color = "#ef9f27"
    message.textContent = "解析が長時間終わっていません。自動更新を止めました。しばらくしてからページを再読み込みしてください"
    this.element.prepend(message)
  }
}
