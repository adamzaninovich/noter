export const DropJson = {
  mounted() {
    this.el.addEventListener("dragover", (e) => {
      e.preventDefault()
      this.el.classList.add("border-primary")
    })
    this.el.addEventListener("dragleave", () => {
      this.el.classList.remove("border-primary")
    })
    this.el.addEventListener("drop", (e) => {
      e.preventDefault()
      this.el.classList.remove("border-primary")
      const file = e.dataTransfer.files[0]
      if (file) {
        file.text().then((text) => {
          this.el.value = text
          this.el.dispatchEvent(new Event("input", { bubbles: true }))
        })
      }
    })
  },
}

export const DropVocab = {
  mounted() {
    this.el.addEventListener("dragover", (e) => {
      e.preventDefault()
      this.el.classList.add("border-primary")
    })
    this.el.addEventListener("dragleave", () => {
      this.el.classList.remove("border-primary")
    })
    this.el.addEventListener("drop", (e) => {
      e.preventDefault()
      this.el.classList.remove("border-primary")
      const file = e.dataTransfer.files[0]
      if (!file) return
      const isText = file.type.startsWith("text/") || file.name.toLowerCase().endsWith(".txt")
      if (!isText) {
        this.pushEvent("vocab_file_rejected", { name: file.name })
        return
      }
      file.text().then((text) => this.setValue(text))
    })
    this.handleEvent("vocab_reset", ({ vocab }) => this.setValue(vocab))
  },
  setValue(text) {
    this.el.value = text
    this.el.dispatchEvent(new Event("input", { bubbles: true }))
  },
}
