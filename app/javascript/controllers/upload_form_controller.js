import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dropzone", "fileInput", "submitBtn"]

  connect() {
    this.dropzoneTarget.addEventListener("click", () => this.fileInputTarget.click())
  }

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
    const file = event.dataTransfer.files[0]
    if (file && file.type.startsWith("image/")) {
      this.showPreview(file)
      const dt = new DataTransfer()
      dt.items.add(file)
      this.fileInputTarget.files = dt.files
    }
  }

  fileSelected(event) {
    const file = event.target.files[0]
    if (file) this.showPreview(file)
  }

  showPreview(file) {
    const reader = new FileReader()
    reader.onload = (e) => {
      document.getElementById("dropzone-content").classList.add("hidden")
      const previewArea = document.getElementById("preview-area")
      previewArea.classList.remove("hidden")
      document.getElementById("preview-image").src = e.target.result
      document.getElementById("preview-name").textContent = file.name
    }
    reader.readAsDataURL(file)
  }
}