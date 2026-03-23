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
