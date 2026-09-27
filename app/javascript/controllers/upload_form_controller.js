import { Controller } from "@hotwired/stimulus"

// 複数画像のアップロードフォーム。選んだファイルを、サーバーと同じ規則（ファイル名の _T / _V）でペアにして一覧表示する
export default class extends Controller {
  static targets = ["dropzone", "fileInput", "submitBtn", "summary", "summaryText", "list"]

  dragover(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.add("dragover")
  }

  dragleave() {
    this.dropzoneTarget.classList.remove("dragover")
  }

  drop(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("dragover")
    const images = Array.from(event.dataTransfer.files).filter((f) => f.type.startsWith("image/"))
    if (images.length === 0) return

    const dt = new DataTransfer()
    images.forEach((f) => dt.items.add(f))
    this.fileInputTarget.files = dt.files
    this.showSummary(images)
  }

  fileSelected(event) {
    this.showSummary(Array.from(event.target.files))
  }

  showSummary(files) {
    const thermals = new Map()
    const rgbs = new Map()
    files.forEach((file) => {
      const base = file.name.replace(/\.[^.]+$/, "")
      const match = base.match(/^(.+)_([TV])$/i)
      if (match) {
        (match[2].toUpperCase() === "T" ? thermals : rgbs).set(match[1].toLowerCase(), file)
      } else {
        thermals.set(base.toLowerCase(), file)
      }
    })

    const unpaired = [...rgbs.keys()].filter((key) => !thermals.has(key))
    const pairedCount = [...thermals.keys()].filter((key) => rgbs.has(key)).length
    this.summaryTextTarget.textContent =
      `サーモ画像 ${thermals.size}枚（RGB とのペア ${pairedCount}組）` +
      (unpaired.length ? ` / 対になるサーモ画像が無い RGB ${unpaired.length}枚（登録されません）` : "")

    this.listTarget.innerHTML = ""
    const keys = [...thermals.keys()].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))
    keys.forEach((key) => {
      const li = document.createElement("li")
      const rgb = rgbs.get(key)
      li.textContent = `${thermals.get(key).name}${rgb ? `  +  ${rgb.name}` : "（RGB なし）"}`
      this.listTarget.appendChild(li)
    })
    unpaired.forEach((key) => {
      const li = document.createElement("li")
      li.textContent = `${rgbs.get(key).name}（対になるサーモ画像がありません）`
      li.style.color = "#ef9f27"
      this.listTarget.appendChild(li)
    })
    this.summaryTarget.classList.remove("hidden")
  }
}
