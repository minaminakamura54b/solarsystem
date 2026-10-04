import { Controller } from "@hotwired/stimulus"

// グリッド入力画面（docs/IMPROVEMENT_PLAN.md Phase 4-1）。
// グリッド = { rows, cols, corners: [[x, y] × 4（左上・右上・右下・左下、0〜1 正規化）], panel_orientation }。
// 4隅から射影変換でパネルの区切り線を描く（解析エンジンの analyzer/vision/grid.py と同じ分け方）
const HANDLE_RADIUS = 7
const COLORS = ["#22c55e", "#3b82f6", "#f59e0b", "#e879f9", "#06b6d4"]

export default class extends Controller {
  static targets = ["image", "canvas", "list", "output", "templateGrid", "message", "hint",
                    "newRows", "newCols", "newOrientation", "addButton", "templateSelect"]
  static values = { grids: Array, proposal: Object, width: Number, height: Number }

  connect() {
    this.grids = this.gridsValue.map((g) => ({ ...g, corners: g.corners.map((c) => [...c]) }))
    this.selected = this.grids.length ? 0 : -1
    this.adding = null
    this.dragging = null
    this.dirty = false
    this.onKeydown = this.keydown.bind(this)
    this.onResize = this.resize.bind(this)
    document.addEventListener("keydown", this.onKeydown)
    window.addEventListener("resize", this.onResize)
    this.resize()
    this.renderList()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    window.removeEventListener("resize", this.onResize)
  }

  // ── 表示 ─────────────────────────────

  resize() {
    const rect = this.imageTarget.getBoundingClientRect()
    if (rect.width === 0 || rect.height === 0) return // 画像の読み込み前（load で呼び直す）
    this.canvasTarget.width = rect.width
    this.canvasTarget.height = rect.height
    this.draw()
  }

  toCanvas([x, y]) {
    return [x * this.canvasTarget.width, y * this.canvasTarget.height]
  }

  draw() {
    const ctx = this.canvasTarget.getContext("2d")
    ctx.clearRect(0, 0, this.canvasTarget.width, this.canvasTarget.height)
    this.grids.forEach((grid, i) => this.drawGrid(ctx, grid, i))
    if (this.adding) {
      ctx.fillStyle = "#ffffff"
      this.adding.forEach((pt) => this.drawHandle(ctx, this.toCanvas(pt), "#ffffff"))
    }
  }

  drawGrid(ctx, grid, index) {
    const color = COLORS[index % COLORS.length]
    const selected = index === this.selected
    const H = homography(
      [[0, 0], [grid.cols, 0], [grid.cols, grid.rows], [0, grid.rows]],
      grid.corners.map((c) => this.toCanvas(c))
    )
    ctx.strokeStyle = color
    ctx.lineWidth = selected ? 2 : 1
    ctx.globalAlpha = selected ? 1 : 0.7
    for (let r = 0; r <= grid.rows; r++) this.line(ctx, apply(H, 0, r), apply(H, grid.cols, r))
    for (let c = 0; c <= grid.cols; c++) this.line(ctx, apply(H, c, 0), apply(H, c, grid.rows))
    ctx.globalAlpha = 1
    if (selected) grid.corners.forEach((c) => this.drawHandle(ctx, this.toCanvas(c), color))
    const [lx, ly] = this.toCanvas(grid.corners[0])
    ctx.fillStyle = color
    ctx.font = "12px sans-serif"
    ctx.fillText(`グリッド ${index + 1}`, lx + 4, ly - 4)
  }

  line(ctx, [x1, y1], [x2, y2]) {
    ctx.beginPath()
    ctx.moveTo(x1, y1)
    ctx.lineTo(x2, y2)
    ctx.stroke()
  }

  drawHandle(ctx, [x, y], color) {
    ctx.beginPath()
    ctx.arc(x, y, HANDLE_RADIUS - 2, 0, Math.PI * 2)
    ctx.fillStyle = color
    ctx.fill()
    ctx.strokeStyle = "#000000"
    ctx.lineWidth = 1
    ctx.stroke()
  }

  renderList() {
    this.listTarget.innerHTML = ""
    if (this.grids.length === 0) {
      this.listTarget.textContent = "グリッドはまだありません"
    }
    this.grids.forEach((grid, i) => {
      const row = document.createElement("div")
      row.className = "flex items-center gap-2"
      row.dataset.gridIndex = i
      row.style.borderLeft = `4px solid ${COLORS[i % COLORS.length]}`
      row.style.paddingLeft = "0.5rem"
      row.innerHTML = `
        <button type="button" class="btn btn-sm ${i === this.selected ? "btn-primary" : "btn-secondary"}" data-action="grid-editor#select" data-index="${i}">グリッド ${i + 1}</button>
        <input type="number" min="1" class="form-input" style="width:4rem" value="${grid.rows}" data-action="change->grid-editor#changeSize" data-index="${i}" data-field="rows" aria-label="行数">
        <span>×</span>
        <input type="number" min="1" class="form-input" style="width:4rem" value="${grid.cols}" data-action="change->grid-editor#changeSize" data-index="${i}" data-field="cols" aria-label="列数">
        <select class="form-select" style="width:auto" data-action="change->grid-editor#changeOrientation" data-index="${i}" aria-label="向き">
          <option value="landscape" ${grid.panel_orientation !== "portrait" ? "selected" : ""}>横長</option>
          <option value="portrait" ${grid.panel_orientation === "portrait" ? "selected" : ""}>縦長</option>
        </select>
        <button type="button" class="btn btn-sm btn-danger" data-action="grid-editor#remove" data-index="${i}">削除</button>`
      this.listTarget.appendChild(row)
    })
    this.outputTarget.value = JSON.stringify(this.grids)
    if (this.hasTemplateGridTarget) {
      this.templateGridTarget.value = this.selected >= 0 ? JSON.stringify(this.grids[this.selected]) : ""
    }
  }

  changed() {
    this.dirty = true
    this.messageTarget.textContent = "未保存の変更があります"
    this.renderList()
    this.draw()
  }

  // ── グリッドの追加・編集 ─────────────────────────────

  startAdding() {
    this.adding = []
    this.addButtonTarget.textContent = "左上の角をクリックしてください（Esc でやめる）"
    this.draw()
  }

  stopAdding() {
    this.adding = null
    this.addButtonTarget.textContent = "グリッドを追加（4隅をクリック）"
    this.draw()
  }

  addGrid(grid) {
    this.grids.push(grid)
    this.selected = this.grids.length - 1
    this.changed()
  }

  loadProposal() {
    const p = this.proposalValue
    if (!p || !p.corners) return
    this.addGrid({ rows: p.rows, cols: p.cols, corners: p.corners.map((c) => [...c]), panel_orientation: p.panel_orientation })
  }

  addTemplate() {
    const grid = JSON.parse(this.templateSelectTarget.value)
    this.addGrid({ ...grid, corners: grid.corners.map((c) => [...c]) })
  }

  select(event) {
    this.selected = Number(event.currentTarget.dataset.index)
    this.renderList()
    this.draw()
  }

  remove(event) {
    this.grids.splice(Number(event.currentTarget.dataset.index), 1)
    this.selected = Math.min(this.selected, this.grids.length - 1)
    this.changed()
  }

  changeSize(event) {
    const value = parseInt(event.currentTarget.value, 10)
    if (!(value >= 1)) return
    this.grids[Number(event.currentTarget.dataset.index)][event.currentTarget.dataset.field] = value
    this.changed()
  }

  changeOrientation(event) {
    this.grids[Number(event.currentTarget.dataset.index)].panel_orientation = event.currentTarget.value
    this.changed()
  }

  // ── マウス操作 ─────────────────────────────

  pointerPosition(event) {
    const rect = this.canvasTarget.getBoundingClientRect()
    return [(event.clientX - rect.left) / rect.width, (event.clientY - rect.top) / rect.height]
  }

  pointerDown(event) {
    const pt = this.pointerPosition(event)
    if (this.adding) {
      this.adding.push(pt)
      const labels = ["右上", "右下", "左下"]
      if (this.adding.length < 4) {
        this.addButtonTarget.textContent = `${labels[this.adding.length - 1]}の角をクリックしてください（Esc でやめる）`
        this.draw()
      } else {
        const grid = {
          rows: Math.max(1, parseInt(this.newRowsTarget.value, 10) || 1),
          cols: Math.max(1, parseInt(this.newColsTarget.value, 10) || 1),
          corners: this.adding.map(([x, y]) => [round(x), round(y)]),
          panel_orientation: this.newOrientationTarget.value
        }
        this.stopAdding()
        this.addGrid(grid)
      }
      return
    }
    // 選択中のグリッドの角の近くなら、その角をドラッグする
    if (this.selected < 0) return
    const corners = this.grids[this.selected].corners
    const [px, py] = this.toCanvas(pt)
    const hit = corners.findIndex((c) => {
      const [cx, cy] = this.toCanvas(c)
      return Math.hypot(cx - px, cy - py) <= HANDLE_RADIUS + 3
    })
    if (hit >= 0) this.dragging = hit
  }

  pointerMove(event) {
    if (this.dragging === null) return
    const [x, y] = this.pointerPosition(event)
    this.grids[this.selected].corners[this.dragging] = [round(x), round(y)]
    this.draw()
  }

  pointerUp() {
    if (this.dragging === null) return
    this.dragging = null
    this.changed()
  }

  // ── キーボード・保存 ─────────────────────────────

  keydown(event) {
    if (["INPUT", "SELECT", "TEXTAREA"].includes(event.target.tagName)) return
    if (event.key === "Escape" && this.adding) return this.stopAdding()
    const link = event.key === "ArrowLeft" ? "grid-prev-link" : event.key === "ArrowRight" ? "grid-next-link" : null
    if (!link) return
    if (this.dirty) {
      this.messageTarget.textContent = "未保存の変更があります。「保存して解析」を押してから移動してください"
      return
    }
    const anchor = document.getElementById(link)
    if (anchor) anchor.click()
  }

  beforeSave() {
    this.outputTarget.value = JSON.stringify(this.grids)
    this.dirty = false
  }

  beforeTemplateSave(event) {
    if (this.selected < 0) {
      event.preventDefault()
      this.messageTarget.textContent = "テンプレートにするグリッドを選んでください"
      return
    }
    this.templateGridTarget.value = JSON.stringify(this.grids[this.selected])
  }
}

function round(v) {
  return Math.round(v * 1e6) / 1e6
}

// 4点の対応から射影変換行列（3×3）を求める
function homography(src, dst) {
  const A = []
  const b = []
  for (let i = 0; i < 4; i++) {
    const [x, y] = src[i]
    const [u, v] = dst[i]
    A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.push(u)
    A.push([0, 0, 0, x, y, 1, -v * x, -v * y]); b.push(v)
  }
  const h = solve(A, b)
  return [[h[0], h[1], h[2]], [h[3], h[4], h[5]], [h[6], h[7], 1]]
}

function apply(H, x, y) {
  const w = H[2][0] * x + H[2][1] * y + H[2][2]
  return [(H[0][0] * x + H[0][1] * y + H[0][2]) / w, (H[1][0] * x + H[1][1] * y + H[1][2]) / w]
}

// ガウスの消去法（部分ピボット）
function solve(A, b) {
  const n = b.length
  const M = A.map((row, i) => [...row, b[i]])
  for (let col = 0; col < n; col++) {
    let pivot = col
    for (let r = col + 1; r < n; r++) if (Math.abs(M[r][col]) > Math.abs(M[pivot][col])) pivot = r
    ;[M[col], M[pivot]] = [M[pivot], M[col]]
    for (let r = 0; r < n; r++) {
      if (r === col || M[col][col] === 0) continue
      const f = M[r][col] / M[col][col]
      for (let c = col; c <= n; c++) M[r][c] -= f * M[col][c]
    }
  }
  return M.map((row, i) => row[n] / row[i])
}
