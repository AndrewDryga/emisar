# Content: a command with OS-specific spellings switches, it does not stack

**Rule.** When a surface publishes the same command in more than one operating-system
spelling, render ONE panel with the shared `<.os_switch>` in its header and default the
selection to the visitor's platform. Never stack a panel per platform, and never lead a
variant with an "On macOS or Linux:" / "On 64-bit Windows:" paragraph — the switch says
which platform, so the sentence beside it says the same thing twice and contradicts the
command once the reader switches.

**Every supported OS gets its own named tab — Linux / Windows / macOS, in that order —
even when two share a spelling.** Linux and macOS run the identical shell one-liner, and
they still get separate tabs: the reader finds THEIR OS by name; a merged "macOS / Linux"
label makes them parse a compound label instead (founder call). The order leads with
Linux — the operator audience — which is also the fallback for an unreadable UA.

Every spelling stays in the DOM; the tabs that are not selected only carry `hidden`.

**Why.** Stacked panels make every reader scroll past a command they cannot run, and the
reader who needs the second one has to recognize their own platform from a label. It also
doubles the vertical cost of every install page. The switch is a CONVENIENCE, never a
gate: the hidden variants are still in the HTML, so a crawler indexes all of them, a
reader with no JS sees all of them, and a reader on another platform is one click away.

**Where the default comes from.** The SERVER picks it — `EmisarWeb.UserAgent.platform/1`
maps the request User-Agent to `:windows`, `:macos`, or `:linux` (Linux itself, plus every
UA we cannot read — a crawler, curl, a phone). Marketing HTML is never shared-cached, so
branching on the request UA cannot serve one visitor's platform to another.
`assets/js/os_tabs.js` owns only the click, and applies the choice page-wide so a page
with an install and a rollback snippet cannot strand the reader mid-page on the other
platform.

## ✅ Good

```heex
<%!-- docs: the switch takes the label's place in the header --%>
<.os_docs_code phx-no-format detected={@detected_os}>
  <:tab os={:linux} label="Linux" copy_text="curl -fsSL … | sudo bash"
  >…</:tab>
  <:tab os={:windows} label="Windows" copy_text="irm … | iex"
  >…</:tab>
  <:tab os={:macos} label="macOS" copy_text="curl -fsSL … | sudo bash"
  >…</:tab>
</.os_docs_code>
```

```heex
<%!-- console: same switch, the code_panel frame --%>
<.os_code_panel id="install-mcp-cmd" detected={@detected_os}>
  <:tab os={:linux} label="Linux" code={command} />
  <:tab os={:windows} label="Windows" code={windows_command} />
  <:tab os={:macos} label="macOS" code={command} />
</.os_code_panel>
```

## ❌ Bad

```heex
<p>On macOS or Linux:</p>
<.docs_code label="shell" copy_text="curl …">…</.docs_code>
<p>On 64-bit Windows, open PowerShell and run:</p>
<.docs_code label="PowerShell" copy_text="irm …">…</.docs_code>
```

Two panels, two lead-ins, and the reader picks by reading labels. A Windows reader meets a
`curl | sudo bash` first every time.

Equally bad:

- a merged `label="macOS / Linux"` tab — the shared spelling is an implementation fact,
  not a reason to make the reader parse a compound label;
- putting the switch ABOVE a panel whose header still prints a platform name, which
  states the platform twice in adjacent chrome.

## How it's enforced

- `EmisarWeb.MarketingStructuralTest` — "install commands open on the visitor's platform"
  drives every page in `@os_switch_routes` with a Linux, a Windows, a macOS, and an
  unreadable UA, and asserts the visible variant plus that the hidden ones stay in the
  page. **A new page publishing a per-OS command joins that list.**
- `EmisarWeb.Components.OsSwitchTest` pins the markup `os_tabs.js` drives.
- `EmisarWeb.UserAgentTest` covers `platform/1`, including the phone/crawler/no-header
  fallback to `:linux`.

Not mechanically checkable: nothing greps for "you published a second panel instead of a
tab". Sweep by hand when adding an install/upgrade command — grep `PowerShell` and
`install-mcp.ps1` under `apps/emisar_web/lib`.

## Not in scope

`mcp/README.md` publishes the same commands as GitHub-rendered Markdown, which has no
switch to render. It keeps its labelled sections.
