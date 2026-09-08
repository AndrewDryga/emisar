// Remember only Source, per signed-in user and account. Filtered URLs win;
// storage is a convenience, never a condition for filtering or authorization.
const sources = new Set(["", "manual", "console"])

export const EnrollmentKeyFilters = {
  mounted() {
    this.preferenceKey = this.el.dataset.preferenceKey
    this.source = this.el.dataset.source
    this.explicit = this.el.dataset.sourceExplicit
    try {
      const saved = localStorage.getItem(this.preferenceKey)
      if (this.explicit !== "true" && sources.has(saved) && saved !== "") {
        this.pushEvent("restore_source_filter", {source: saved})
      } else {
        this.saveSource()
      }
    } catch (_) {
      // Private browsing or storage restrictions must not break the page.
    }
  },

  updated() {
    const source = this.el.dataset.source
    const explicit = this.el.dataset.sourceExplicit
    if (source !== this.source || explicit !== this.explicit) {
      this.source = source
      this.explicit = explicit
      this.saveSource()
    }
  },

  saveSource() {
    const source = this.el.dataset.source
    if (!sources.has(source)) return
    try { localStorage.setItem(this.preferenceKey, source) } catch (_) {}
  }
}
