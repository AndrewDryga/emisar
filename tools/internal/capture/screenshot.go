package capture

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/chromedp/chromedp"
)

// Two shelves used to exist for these helpers. idpcapture's rule was that a
// helper joins only when its copies are byte-identical across the drivers, and
// the reason still holds for the deliberately per-vendor ones: each console
// has its own DOM, and the copies differ in selector, in how they treat a
// miss, and in which environment variables they name. Reconciling those needs
// each driver re-run against its live tenant, which CI cannot do — so a helper
// moves here when its copies are identical, or when someone has re-captured
// every affected flow and can say so.

// Screenshot writes a full-page PNG named name into outDir.
func Screenshot(ctx context.Context, outDir, name string) error {
	var buffer []byte
	if err := chromedp.Run(ctx, chromedp.FullScreenshot(&buffer, 90)); err != nil {
		return err
	}
	path := filepath.Join(outDir, name+".png")
	// 0600: these are full-page captures of live IdP consoles (client-credential
	// cards, SCIM token forms), so they stay owner-only like the credential
	// files the same run writes.
	if err := os.WriteFile(path, buffer, 0o600); err != nil {
		return err
	}
	fmt.Println("  shot", name)
	return nil
}

// ScreenshotElement writes the rendered box for the first visible node matching
// selector. Provider guides use it for the instruction panel so account chrome,
// plan badges, and other tenant-specific controls never enter a public asset.
func ScreenshotElement(ctx context.Context, outDir, name, selector string) error {
	var buffer []byte
	if err := chromedp.Run(ctx, chromedp.Screenshot(selector, &buffer, chromedp.ByQuery)); err != nil {
		return err
	}
	path := filepath.Join(outDir, name+".png")
	// 0600 to match Screenshot: a captured control from a live IdP console
	// stays owner-only like the credential files the same run writes.
	if err := os.WriteFile(path, buffer, 0o600); err != nil {
		return err
	}
	fmt.Println("  element shot", name)
	return nil
}

// ClickRadio clicks the first visible radio input whose label starts with
// label, reporting whether one was found.
func ClickRadio(ctx context.Context, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const radio = [...document.querySelectorAll('input[type=radio]')].filter(visible).find(el =>
    (el.labels && [...el.labels].some(l => l.textContent.trim().startsWith(%q))));
  if (!radio) return false;
  radio.scrollIntoView({block: 'center'});
  radio.click();
  return true;
})()`, label)
	var clicked bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked))
	return clicked, err
}
