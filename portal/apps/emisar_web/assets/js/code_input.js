// iPhone-style one-box-per-char code entry — sign-in codes, TOTP, email step-up.
// The boxes are client-owned — the form submits the hidden [data-code] aggregate —
// so the container carries phx-update="ignore" and a LiveView re-render (flash, an
// expiry countdown) can't wipe what you typed. Handles: filter to the code alphabet
// (alphanumeric, or digits-only via data-numeric), auto-advance, backspace-to-
// previous, arrow nav, paste/autofill spread across boxes, and auto-submit once all
// boxes are full. No-JS falls back to the email link (sign-in) or a plain submit.
export const CodeInput = {
  mounted() {
    this.boxes = Array.from(this.el.querySelectorAll("[data-box]"))
    this.hidden = this.el.querySelector("[data-code]")
    if (!this.boxes.length || !this.hidden) return

    const numeric = this.el.dataset.numeric === "true"
    const clean = numeric
      ? (s) => s.replace(/[^0-9]/g, "")
      : (s) => s.toUpperCase().replace(/[^0-9A-Z]/g, "")
    const sync = () => { this.hidden.value = this.boxes.map(b => b.value).join("") }
    const focusBox = (i) => { const b = this.boxes[i]; if (b) { b.focus(); b.select() } }

    const maybeSubmit = () => {
      if (this.boxes.every(b => b.value.length === 1)) {
        const form = this.el.closest("form")
        if (form) { form.requestSubmit ? form.requestSubmit() : form.submit() }
      }
    }

    const spread = (chars, start) => {
      for (let k = 0; start + k < this.boxes.length && k < chars.length; k++) {
        this.boxes[start + k].value = chars[k]
      }
      sync()
      focusBox(Math.min(start + chars.length, this.boxes.length - 1))
      maybeSubmit()
    }

    this.boxes.forEach((box, i) => {
      box.addEventListener("input", () => {
        const v = clean(box.value)
        if (v.length > 1) { spread(v, i); return }   // autofill dumped the whole code in one box
        box.value = v
        sync()
        if (v && i < this.boxes.length - 1) focusBox(i + 1)
        maybeSubmit()
      })
      box.addEventListener("keydown", (e) => {
        if (e.key === "Backspace" && box.value === "" && i > 0) {
          e.preventDefault(); this.boxes[i - 1].value = ""; sync(); focusBox(i - 1)
        } else if (e.key === "ArrowLeft" && i > 0) {
          e.preventDefault(); focusBox(i - 1)
        } else if (e.key === "ArrowRight" && i < this.boxes.length - 1) {
          e.preventDefault(); focusBox(i + 1)
        }
      })
      box.addEventListener("paste", (e) => {
        e.preventDefault()
        const text = (e.clipboardData || window.clipboardData).getData("text") || ""
        spread(clean(text), 0)
      })
      box.addEventListener("focus", () => box.select())
    })

    // Don't let a manual "Sign in" click submit a half-typed code (it would burn
    // an attempt) — bounce focus to the first empty box instead.
    this.form = this.el.closest("form")
    if (this.form) {
      this.onSubmit = (e) => {
        if (this.hidden.value.length !== this.boxes.length) {
          e.preventDefault()
          const empty = this.boxes.find((b) => b.value === "")
          if (empty) empty.focus()
        }
      }
      this.form.addEventListener("submit", this.onSubmit)
    }

    // The server can't clear the boxes by re-rendering (phx-update="ignore"), so a
    // rejected attempt arrives as an event addressed to this group's id. Emptying
    // them is what keeps a correction from being an instant resubmit: with the code
    // left in place, fixing one character refills all six and auto-submits, burning
    // another of the five attempts. Pages that never push it are unaffected.
    this.handleEvent("code:reset", ({id}) => {
      if (id !== this.el.id) return
      this.boxes.forEach(b => { b.value = "" })
      sync()
      focusBox(0)
    })

    sync()
    focusBox(0)
  },
  destroyed() {
    if (this.form && this.onSubmit) this.form.removeEventListener("submit", this.onSubmit)
  }
}
