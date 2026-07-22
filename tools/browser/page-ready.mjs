const twoFrames = () =>
  new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));

export async function waitForPageReady(page, { target = null, timeout = 10000 } = {}) {
  await page.waitForFunction(
    () => {
      const root = document.querySelector("[data-phx-main]");
      return !root || root.classList.contains("phx-connected");
    },
    { timeout },
  );

  await page.evaluate(async () => {
    await document.fonts?.ready;
    const visible = [...document.images].filter((img) => {
      const box = img.getBoundingClientRect();
      return box.width > 0 && box.height > 0;
    });
    await Promise.all(
      visible.map((img) => (img.complete ? img.decode?.().catch(() => {}) : new Promise((done) => {
        img.addEventListener("load", done, { once: true });
        img.addEventListener("error", done, { once: true });
      }))),
    );
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });

  if (target) {
    await page.waitForFunction(
      (selector) => {
        const el = document.querySelector(selector);
        if (!el) return false;
        const box = el.getBoundingClientRect();
        const key = `${box.x}:${box.y}:${box.width}:${box.height}`;
        if (el.dataset.shotGeometry === key) return true;
        el.dataset.shotGeometry = key;
        return false;
      },
      { timeout },
      target,
    );
    await page.evaluate(twoFrames);
  }
}
