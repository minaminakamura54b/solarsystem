import { Controller } from "@hotwired/stimulus"

// レビュー画面（docs/IMPROVEMENT_PLAN.md Phase 5）。
// - サーモ画像に候補の bbox を重ねて描き、選んだ候補を強調する
// - 候補ごとに、サーモ画像・RGB 画像の同じ位置（bbox の周りを広めに）を切り出して描く
// - キーボード: j / k で候補を移動、c で確定、x で却下（理由を選んでいなければ理由の選択にフォーカス）
// - 「位置を描き直す」「範囲を指定」のあと、画像の上をドラッグすると bbox（0〜1 正規化）を指定したフォームの欄に入れる
const COLORS = { pending: "#f59e0b", confirmed: "#22c55e", corrected: "#22c55e", rejected: "#6b7280" }

export default class extends Controller {
  static targets = ["image", "rgb", "overlay", "card", "crop", "message"]
  static values = { boxes: Array }

  connect() {
    this.selectedIndex = this.cardTargets.length ? 0 : -1
    this.drawing = null
    this.drawRect = null
    this.onKeydown = this.keydown.bind(this)
    document.addEventListener("keydown", this.onKeydown)
    this.imageLoaded()
    this.highlight()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  imageLoaded() {
    const rect = this.imageTarget.getBoundingClientRect()
    if (rect.width === 0 || rect.height === 0) return
    this.overlayTarget.width = rect.width
    this.overlayTarget.height = rect.height
    this.drawOverlay()
    this.drawCrops()
  }

  // ── 描画 ─────────────────────────────

  drawOverlay() {
    const canvas = this.overlayTarget
    const ctx = canvas.getContext("2d")
    ctx.clearRect(0, 0, canvas.width, canvas.height)
    const selectedId = this.selectedCard()?.dataset.cardId
    this.boxesValue.forEach((box) => {
      if (!box.bbox) return
      const selected = box.id === selectedId
      ctx.strokeStyle = selected ? "#ffffff" : (COLORS[box.status] || "#3b82f6")
      ctx.lineWidth = selected ? 3 : 1.5
      const [x, y, w, h] = this.toCanvas(box.bbox)
      ctx.strokeRect(x - 2, y - 2, w + 4, h + 4)
    })
    if (this.drawRect) {
      ctx.setLineDash([4, 3])
      ctx.strokeStyle = "#ffffff"
      ctx.lineWidth = 2
      const [x, y, w, h] = this.toCanvas(this.drawRect)
      ctx.strokeRect(x, y, w, h)
      ctx.setLineDash([])
    }
  }

  toCanvas(b) {
    const W = this.overlayTarget.width
    const H = this.overlayTarget.height
    return [b.x1 * W, b.y1 * H, (b.x2 - b.x1) * W, (b.y2 - b.y1) * H]
  }

  drawCrops() {
    this.cropTargets.forEach((canvas) => {
      const source = canvas.dataset.source === "rgb" ? (this.hasRgbTarget ? this.rgbTarget : null) : this.imageTarget
      const bbox = JSON.parse(canvas.dataset.bbox || "null")
      if (!source || !bbox || !source.naturalWidth) return
      const iw = source.naturalWidth
      const ih = source.naturalHeight
      // bbox の中心から、bbox の3倍（最低 48px）の正方形を切り出す
      const cx = ((bbox.x1 + bbox.x2) / 2) * iw
      const cy = ((bbox.y1 + bbox.y2) / 2) * ih
      const size = Math.max(48, Math.max((bbox.x2 - bbox.x1) * iw, (bbox.y2 - bbox.y1) * ih) * 3)
      const sx = Math.max(0, Math.min(iw - size, cx - size / 2))
      const sy = Math.max(0, Math.min(ih - size, cy - size / 2))
      const ctx = canvas.getContext("2d")
      ctx.imageSmoothingEnabled = false
      ctx.clearRect(0, 0, canvas.width, canvas.height)
      ctx.drawImage(source, sx, sy, size, size, 0, 0, canvas.width, canvas.height)
      const scale = canvas.width / size
      ctx.strokeStyle = "#ffffff"
      ctx.lineWidth = 1.5
      ctx.strokeRect((bbox.x1 * iw - sx) * scale, (bbox.y1 * ih - sy) * scale, (bbox.x2 - bbox.x1) * iw * scale, (bbox.y2 - bbox.y1) * ih * scale)
    })
  }

  // ── 候補の選択とキーボード ─────────────────────────────

  selectedCard() {
    return this.selectedIndex >= 0 ? this.cardTargets[this.selectedIndex] : null
  }

  selectCard(event) {
    const index = this.cardTargets.indexOf(event.currentTarget)
    if (index >= 0 && index !== this.selectedIndex) {
      this.selectedIndex = index
      this.highlight()
    }
  }

  highlight() {
    this.cardTargets.forEach((card, i) => {
      card.style.outline = i === this.selectedIndex ? "2px solid #ffffff" : ""
    })
    this.drawOverlay()
  }

  keydown(event) {
    if (["INPUT", "SELECT", "TEXTAREA"].includes(event.target.tagName) || event.metaKey || event.ctrlKey) return
    const card = this.selectedCard()
    switch (event.key) {
      case "j":
      case "k":
        if (!this.cardTargets.length) return
        this.selectedIndex = (this.selectedIndex + (event.key === "j" ? 1 : -1) + this.cardTargets.length) % this.cardTargets.length
        this.highlight()
        this.selectedCard().scrollIntoView({ block: "nearest" })
        break
      case "c":
        card?.querySelector("form[data-review-role='confirm']")?.requestSubmit()
        break
      case "x": {
        const form = card?.querySelector("form[data-review-role='reject']")
        if (!form) return
        const reason = form.querySelector("[data-review-role='reject-reason']")
        if (reason && !reason.value) {
          reason.focus()
          this.messageTarget.textContent = "却下の理由を選んでから、却下ボタンを押してください"
        } else {
          form.requestSubmit()
        }
        break
      }
      case "ArrowLeft":
      case "ArrowRight":
        document.getElementById(event.key === "ArrowLeft" ? "review-prev-link" : "review-next-link")?.click()
        break
    }
  }

  // ── 範囲の指定（ドラッグ）─────────────────────────────

  startDrawing(event) {
    this.drawingInput = document.getElementById(event.currentTarget.dataset.inputId)
    this.messageTarget.textContent = "サーモ画像の上をドラッグして範囲を指定してください"
    this.overlayTarget.style.cursor = "crosshair"
  }

  position(event) {
    const rect = this.overlayTarget.getBoundingClientRect()
    return [
      Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width)),
      Math.min(1, Math.max(0, (event.clientY - rect.top) / rect.height))
    ]
  }

  drawStart(event) {
    if (!this.drawingInput) return
    this.drawing = this.position(event)
  }

  drawMove(event) {
    if (!this.drawing) return
    const [x, y] = this.position(event)
    const [x0, y0] = this.drawing
    this.drawRect = { x1: Math.min(x0, x), y1: Math.min(y0, y), x2: Math.max(x0, x), y2: Math.max(y0, y) }
    this.drawOverlay()
  }

  drawEnd(event) {
    if (!this.drawing) return
    this.drawMove(event)
    this.drawing = null
    if (this.drawRect && this.drawRect.x2 - this.drawRect.x1 > 0.002 && this.drawRect.y2 - this.drawRect.y1 > 0.002) {
      const round = (v) => Math.round(v * 1e6) / 1e6
      this.drawingInput.value = JSON.stringify({ x1: round(this.drawRect.x1), y1: round(this.drawRect.y1), x2: round(this.drawRect.x2), y2: round(this.drawRect.y2) })
      this.messageTarget.textContent = "範囲を指定しました。フォームのボタンを押すと保存します"
    } else {
      this.messageTarget.textContent = "範囲が小さすぎます。もう一度ドラッグしてください"
    }
    this.drawingInput = null
    this.overlayTarget.style.cursor = ""
  }
}
