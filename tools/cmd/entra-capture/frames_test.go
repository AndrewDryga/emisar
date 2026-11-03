package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/browser"
	"github.com/chromedp/chromedp"
)

func TestFramesSurviveNavigationAndRecreation(t *testing.T) {
	if _, err := browser.ResolveChrome(); err != nil {
		t.Skip(err)
	}
	var origin string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		if r.URL.Path == "/frame" {
			fmt.Fprintf(w, `<!doctype html><body data-label=%q><button onclick="document.body.dataset.clicked='yes'">Click</button></body>`, r.URL.Query().Get("label"))
			return
		}
		fmt.Fprintf(w, `<!doctype html><iframe id="same" src="/frame?label=initial"></iframe><iframe id="cross" src="%s/frame?label=cross"></iframe>`, strings.Replace(origin, "127.0.0.1", "localhost", 1))
	}))
	origin = server.URL
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	session, err := browser.New(browser.Config{InBox: os.Getenv("COOP_BOX") == "1" || os.Getenv("CI") != ""}).Session(ctx, origin, true)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err := chromedp.Do(session.Context, chromedp.Navigate(origin)); err != nil {
		t.Fatal(err)
	}
	frames := trackFrames(session.Context)
	check := func(label string, wantChild bool) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			current, err := frames.frames(session.Context)
			if err != nil {
				t.Fatal(err)
			}
			for _, f := range current {
				var actual string
				if err := f.evaluate(session.Context, `document.body?.dataset.label || ''`, &actual); err != nil || actual != label {
					continue
				}
				if wantChild && f.child == nil {
					t.Fatalf("cross-site frame was not adopted as an out-of-process target")
				}
				if !wantChild && f.child != nil {
					t.Fatalf("same-site frame unexpectedly used a child target")
				}
				var clicked bool
				if err := f.evaluate(session.Context, `(()=>{document.querySelector('button').click();return document.body.dataset.clicked==='yes'})()`, &clicked); err != nil || !clicked {
					t.Fatalf("DOM interaction in %s: clicked=%v error=%v", label, clicked, err)
				}
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("frame %s not found", label)
	}
	check("initial", false)
	check("cross", true)
	if err := chromedp.Do(session.Context, chromedp.Evaluate[chromedp.Void](`document.querySelector('#same').src='/frame?label=navigated'`)); err != nil {
		t.Fatal(err)
	}
	check("navigated", false)
	if err := chromedp.Do(session.Context, chromedp.Evaluate[chromedp.Void](`document.querySelector('#same').remove();const f=document.createElement('iframe');f.id='same';f.src='/frame?label=recreated';document.body.append(f)`)); err != nil {
		t.Fatal(err)
	}
	check("recreated", false)
	if err := chromedp.Do(session.Context, chromedp.Evaluate[chromedp.Void](`document.querySelector('#cross').src += '-navigated'`)); err != nil {
		t.Fatal(err)
	}
	check("cross-navigated", true)
	if err := chromedp.Do(session.Context, chromedp.Evaluate[chromedp.Void](`const old=document.querySelector('#cross');const fresh=old.cloneNode();fresh.src += '-recreated';old.replaceWith(fresh)`)); err != nil {
		t.Fatal(err)
	}
	check("cross-navigated-recreated", true)

}
