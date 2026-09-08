// Restore focus after either a client-side hide or a server-rendered dialog's removal.
// Phoenix's focus_wrap owns focus containment inside the open dialog.
export const DialogFocus = {
  mounted() {
    this.opener = null
    this.onShow = () => {
      const active = document.activeElement
      if (active && active !== document.body && !this.el.contains(active)) this.opener = active
    }
    this.onHide = () => {
      if (this.opener && this.opener.isConnected) this.opener.focus()
      this.opener = null
    }
    this.el.addEventListener("phx:show-start", this.onShow)
    this.el.addEventListener("phx:hide-end", this.onHide)
    // Server-rendered dialogs mount visibly and close by removal, without the
    // show/hide events used by persistent confirmation dialogs.
    if (this.el.dataset.serverDialog === "true") this.onShow()
  },
  destroyed() {
    this.el.removeEventListener("phx:show-start", this.onShow)
    this.el.removeEventListener("phx:hide-end", this.onHide)
    if (this.el.dataset.serverDialog === "true") this.onHide()
  }
}
