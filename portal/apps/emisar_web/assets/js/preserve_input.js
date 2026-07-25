// Keeps what an operator typed when the page goes away and comes back — a
// refresh, a back/forward, an accidental Cmd-R halfway through describing why a
// production action needs to run.
//
// A LiveView form's values live on the server, so a full reload re-mounts from
// the database and everything unsaved is gone. This hook mirrors the form's
// fields into `sessionStorage` as they're typed and puts them back on mount.
//
// `sessionStorage`, deliberately, not `localStorage`: the draft dies with the
// tab instead of sitting in the browser profile until something clears it.
// emisar is a security product and this data is run arguments, deny
// justifications, and directory configuration — it gets the shortest lifetime
// that still satisfies "survives a refresh".
//
// WHAT IS NEVER STORED (`skip/1`): passwords, credit-card autocomplete fields,
// one-time codes, hidden inputs (CSRF tokens, signed handoffs, ids), file
// inputs, disabled/readonly fields, anything inside a `phx-update="ignore"`
// island, and any field opting out with `data-preserve="off"`. Those either
// belong to the browser's own credential manager or must not outlive the
// request. Extend the skip list, never invert it into an allow list — a new
// sensitive field has to be excluded by default.
//
// Opt a form in with `phx-hook="PreserveInput"` + a stable `id`. Suitable for a
// form whose fields are FIXED: the snapshot is keyed by field name, so it
// cannot faithfully rebuild a form whose operator-editable STRUCTURE changed
// (the runbook editor's step list, a policy's override rows) — restoring values
// onto a different structure is worse than restoring nothing. Those need a
// server-side draft instead.
//
// Re-renders are hostile too, not just reloads: a LiveView patch resets every
// non-focused input to the server's rendered value, so until the server has
// been told what was typed (the first `phx-change` round-trip), a broadcast
// re-render can wipe restored values from the DOM. `heal/0` therefore re-applies
// the draft after every patch to any field the server still renders pristine —
// which also lands a held-back value (the reuse scope that appears once a grant
// duration is picked) the moment its conditional field first exists.

const isCreditCardField = (el) => (el.autocomplete || "").startsWith("cc-")

const isOneTimeCode = (el) => (el.autocomplete || "").split(/\s+/).includes("one-time-code")

// Never persisted. See the note above: this list is the security boundary.
function skip(el) {
  if (!el.name) return true
  if (el.disabled || el.readOnly) return true
  if (["hidden", "password", "file", "submit", "button", "reset", "image"].includes(el.type)) {
    return true
  }
  if (isOneTimeCode(el) || isCreditCardField(el)) return true
  if (el.dataset.preserve === "off") return true
  if (el.closest('[phx-update="ignore"]')) return true
  return false
}

// Checkboxes and radios share a name across several elements, so their key
// carries the value; everything else is one field per name.
const fieldKey = (el) =>
  el.type === "checkbox" || el.type === "radio" ? `${el.name}=${el.value}` : el.name

const isMultiSelect = (el) => el.tagName === "SELECT" && el.multiple

function readField(el) {
  if (el.type === "checkbox" || el.type === "radio") return el.checked
  if (isMultiSelect(el)) return Array.from(el.selectedOptions).map((option) => option.value)
  return el.value
}

function writeField(el, value) {
  if (el.type === "checkbox" || el.type === "radio") {
    el.checked = value === true
  } else if (isMultiSelect(el)) {
    const wanted = Array.isArray(value) ? value : []
    Array.from(el.options).forEach((option) => {
      option.selected = wanted.includes(option.value)
    })
  } else {
    el.value = value
  }
}

export const PreserveInput = {
  mounted() {
    // Pinned at mount, never recomputed: hook teardown is ASYNC (it fires on the
    // channel-leave reply), while a push_navigate pushes the new URL
    // synchronously before that reply lands. Reading `location` in destroyed()
    // therefore discarded the NEW path's key and left the spent draft behind, so
    // the next visit to a create form restored the entity just created.
    this.key = `form:${window.location.pathname}:${this.el.id}`
    // What the server rendered. Only fields that differ from it are the
    // operator's own work, so a pristine form stores nothing at all.
    this.initial = this.snapshot()
    this.draft = this.load()
    this.heal()

    this.onChange = () => this.save()
    this.onSubmit = () => {
      this.submitted = true
    }
    this.el.addEventListener("input", this.onChange)
    this.el.addEventListener("change", this.onChange)
    this.el.addEventListener("submit", this.onSubmit)
  },

  updated() {
    // After a submit that answered without navigating away, the DOM is the
    // truth: a failed submit re-renders the operator's values (they're
    // server-tracked), and an in-place success re-renders the reset form —
    // healing over THAT would resurrect the spent draft. Any other patch may
    // have wiped restored values the server hasn't been told about yet, so
    // heal before snapshotting or save() would overwrite the good draft with
    // the wiped DOM.
    const submitted = this.submitted
    this.submitted = false
    if (!submitted) this.heal()
    this.save()
  },

  destroyed() {
    // Destroyed while a submit was in flight = it succeeded and navigated away,
    // so the draft is spent. A refresh never reaches here with the flag set, so
    // the draft it needs survives.
    if (this.submitted) this.discard()
    this.el.removeEventListener("input", this.onChange)
    this.el.removeEventListener("change", this.onChange)
    this.el.removeEventListener("submit", this.onSubmit)
  },

  fields() {
    const all = this.el.querySelectorAll("input, select, textarea")
    return Array.from(all).filter((el) => !skip(el))
  },

  snapshot() {
    return this.fields().reduce((acc, el) => {
      acc[fieldKey(el)] = readField(el)
      return acc
    }, {})
  },

  // Apply the draft to every field the server still renders pristine — its
  // value matches the mount snapshot, or it just appeared (a conditional
  // reveal, absent from the snapshot). A field that differs from pristine is
  // either focused-and-typed-in or already server-tracked; the draft never
  // overwrites those.
  heal() {
    if (!this.draft) return

    this.fields().forEach((el) => {
      const key = fieldKey(el)
      if (!(key in this.draft)) return

      const initial = this.initial[key]
      const pristine =
        initial === undefined || JSON.stringify(readField(el)) === JSON.stringify(initial)

      if (pristine) writeField(el, this.draft[key])
    })
  },

  save() {
    const current = this.snapshot()

    const draft = Object.entries(current).reduce((acc, [key, value]) => {
      if (JSON.stringify(value) !== JSON.stringify(this.initial[key])) acc[key] = value
      return acc
    }, {})

    if (Object.keys(draft).length === 0) {
      this.discard()
      return
    }

    this.draft = draft

    try {
      window.sessionStorage.setItem(this.key, JSON.stringify(draft))
    } catch (_error) {
      // Quota exhausted or storage blocked (private mode). Losing a draft is
      // recoverable; throwing out of an input handler is not.
    }
  },

  load() {
    try {
      const stored = window.sessionStorage.getItem(this.key)
      const parsed = stored && JSON.parse(stored)
      return parsed && typeof parsed === "object" ? parsed : null
    } catch (_error) {
      return null
    }
  },

  discard() {
    this.draft = null

    try {
      window.sessionStorage.removeItem(this.key)
    } catch (_error) {
      // See save/0.
    }
  }
}
