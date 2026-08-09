// Package idpcapture holds the browser-driving helpers the identity-provider
// capture drivers share.
//
// Only helpers that are BYTE-IDENTICAL across the drivers live here. The others
// — clickText, clickContaining, focusField, highlight, tickInSection,
// deidentifyHost, readEnv — read as duplicates but are not: each provider's
// console has its own DOM, and the copies differ in selector, in how they treat
// a miss (warn versus error), and in which environment variables they name.
//
// Reconciling those needs each driver re-run against its live tenant, which is
// the one thing CI cannot do. Moving one here on the assumption that the
// differences are cosmetic would break a capture silently, and the breakage
// would only surface the next time someone regenerated that provider's guide.
// So a helper joins this package when its copies are identical, or when someone
// has re-captured every affected flow and can say so.
package idpcapture

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/chromedp/chromedp"
)

// Screenshot writes a full-page PNG named name into outDir.
func Screenshot(ctx context.Context, outDir, name string) error {
	var buffer []byte
	if err := chromedp.Run(ctx, chromedp.FullScreenshot(&buffer, 90)); err != nil {
		return err
	}
	path := filepath.Join(outDir, name+".png")
	if err := os.WriteFile(path, buffer, 0o644); err != nil {
		return err
	}
	fmt.Println("  shot", name)
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
