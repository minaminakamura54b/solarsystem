import { Controller } from "@hotwired/stimulus"

// 複数画像のアップロードフォーム。選んだファイルを、サーバーと同じ規則（ファイル名の _T / _V と DJI の番号・撮影時刻）でペアにして一覧表示する
export default class extends Controller {
  static targets = ["dropzone", "fileInput", "submitBtn", "summary", "summaryText", "list"]
  static values = { maxGapSeconds: Number }

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
    const { pairs, unpaired, mismatched, duplicates } = pairFiles(files, this.maxGapSecondsValue)
    const pairedCount = pairs.filter((p) => p.rgb).length
    this.summaryTextTarget.textContent =
      `サーモ画像 ${pairs.length}枚（RGB とのペア ${pairedCount}組）` +
      (unpaired.length ? ` / 組にならない RGB ${unpaired.length}枚（登録されません）` : "") +
      (duplicates.length ? ` / 複製と思われるファイル ${duplicates.length}枚（登録されません）` : "")

    this.listTarget.innerHTML = ""
    pairs.forEach((pair) => {
      this.addItem(`${pair.thermal.name}${pair.rgb ? `  +  ${pair.rgb.name}` : "（RGB なし）"}`)
    })
    unpaired.forEach((file) => {
      const reason = mismatched.includes(file)
        ? `番号が同じサーモ画像と撮影時刻が ${this.maxGapSecondsValue} 秒を超えてずれています`
        : "対になるサーモ画像がありません"
      this.addItem(`${file.name}（${reason}）`, "#ef9f27")
    })
    duplicates.forEach((file) => this.addItem(`${file.name}（複製と思われるため登録しません）`, "#ef9f27"))
    this.summaryTarget.classList.remove("hidden")
  }

  addItem(text, color) {
    const li = document.createElement("li")
    li.textContent = text
    if (color) li.style.color = color
    this.listTarget.appendChild(li)
  }
}

// サーバー（app/services/image_pairing.rb）と同じ規則でペアにする。
// _T / _V を除いた名前が同じもの、または DJI の名前（DJI_<撮影時刻 14 桁>_<番号>）で番号が同じく時刻の差が maxGap 秒以内のものを、
// 差の小さい順に 1 対 1 で組にする。名前の末尾が「 (2)」などの複製は登録しない
function pairFiles(files, maxGap) {
  const thermals = []
  const rgbs = []
  const duplicates = []
  files.forEach((file) => {
    const base = file.name.replace(/\.[^.]+$/, "")
    if (/\s\(\d+\)$/.test(base)) return duplicates.push(file)
    const match = base.match(/^(.+)_([TV])$/i)
    const entry = parseEntry(file, match ? match[1] : base)
    ;(match && match[2].toUpperCase() === "V" ? rgbs : thermals).push(entry)
  })

  const candidates = []
  thermals.forEach((t) => {
    rgbs.forEach((v) => {
      if (v.stem === t.stem) candidates.push([0, t, v])
      else if (t.djiKey && t.djiKey === v.djiKey) {
        const gap = Math.abs(v.time - t.time) / 1000
        if (gap <= maxGap) candidates.push([gap, t, v])
      }
    })
  })
  const natural = (a, b) => a.localeCompare(b, undefined, { numeric: true })
  candidates.sort((a, b) => a[0] - b[0] || natural(a[1].stem, b[1].stem) || natural(a[2].stem, b[2].stem))
  const matched = new Map()
  const used = new Set()
  candidates.forEach(([, t, v]) => {
    if (matched.has(t) || used.has(v)) return
    matched.set(t, v)
    used.add(v)
  })

  const thermalKeys = new Set(thermals.map((t) => t.djiKey).filter(Boolean))
  const unpairedEntries = rgbs.filter((v) => !used.has(v))
  return {
    pairs: [...thermals].sort((a, b) => natural(a.stem, b.stem)).map((t) => ({ thermal: t.file, rgb: matched.get(t)?.file })),
    unpaired: unpairedEntries.map((v) => v.file),
    mismatched: unpairedEntries.filter((v) => v.djiKey && thermalKeys.has(v.djiKey)).map((v) => v.file),
    duplicates
  }
}

function parseEntry(file, stem) {
  stem = stem.toLowerCase()
  const m = stem.match(/^(.+)_(\d{14})_(\d+)$/)
  if (!m) return { file, stem, djiKey: null, time: null }
  const d = m[2]
  const time = Date.UTC(+d.slice(0, 4), +d.slice(4, 6) - 1, +d.slice(6, 8), +d.slice(8, 10), +d.slice(10, 12), +d.slice(12, 14))
  return { file, stem, djiKey: `${m[1]}#${parseInt(m[3], 10)}`, time }
}
