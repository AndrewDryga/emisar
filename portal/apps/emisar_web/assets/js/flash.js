function createAutoClose(el, dismiss) {
  const duration = parseInt(el.dataset.closeMs, 10)
  if (!duration) return null

  const bar = el.querySelector("[data-flash-bar]")
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches
  if (reduce && bar) bar.style.display = "none"

  let animationFrame = null
  let elapsed = 0
  let last = 0
  let paused = false

  const stop = () => {
    if (animationFrame) cancelAnimationFrame(animationFrame)
    animationFrame = null
  }

  const tick = (now) => {
    if (!paused) {
      elapsed += now - last
      if (bar && !reduce) {
        bar.style.transform = `scaleX(${Math.max(0, 1 - elapsed / duration)})`
      }
      if (elapsed >= duration) {
        stop()
        dismiss()
        return
      }
    }
    last = now
    animationFrame = requestAnimationFrame(tick)
  }

  const pause = () => { paused = true }
  const resume = () => { paused = false; last = performance.now() }

  el.addEventListener("mouseenter", pause)
  el.addEventListener("mouseleave", resume)

  return {
    start() {
      stop()
      paused = false
      elapsed = 0
      last = performance.now()
      animationFrame = requestAnimationFrame(tick)
    },
    destroy() {
      stop()
      el.removeEventListener("mouseenter", pause)
      el.removeEventListener("mouseleave", resume)
    },
  }
}

// LiveView owns server-side flash state, so its timer fires the component's
// existing phx-click chain: clear on the server, then animate out locally.
export const FlashAutoClose = {
  mounted() {
    this.autoClose = createAutoClose(this.el, () => this.el.click())
    this.autoClose?.start()
  },
  updated() { this.autoClose?.start() },
  destroyed() { this.autoClose?.destroy() },
}

// Controller-rendered pages load marketing.js without LiveView. Give their
// shared flashes the same click, pause, countdown, and reduced-motion behavior.
export function initStaticFlashes() {
  document.querySelectorAll("[data-flash]").forEach((el) => {
    const autoClose = createAutoClose(el, () => { el.hidden = true })
    autoClose?.start()

    el.addEventListener("click", () => {
      autoClose?.destroy()
      el.hidden = true
    })
  })
}
