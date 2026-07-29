# Third-party provider marks

The identity-provider logos shown beside the Integrations rows on `/docs`. Each
is the vendor's own mark, used to identify their product in our documentation.
**The trademarks belong to their respective owners; nothing here is emisar's.**
Our own brand assets live in `../brand/`.

| File | Mark | Source |
|---|---|---|
| `okta.svg` | Okta | Simple Icons / SVG Logos, CC0 |
| `microsoft-entra.svg` | Microsoft Entra ID | selfh.st icon set |
| `jumpcloud.svg` | JumpCloud | jumpcloud.com's own `jumpcloud-logo-tm-oceanblue.svg` |
| `keycloak.svg` | Keycloak | selfh.st icon set (Keycloak is Apache-2.0) |
| `google-workspace.svg` | Google | SVG Logos, CC0 |

Two notes on what was done to them, so a later edit does not undo it by accident:

- **JumpCloud ships only a wide lockup** (mark + wordmark, 600x96, as a single
  merged path). Its `viewBox` is windowed to `0 0 168 84` so only the cloud mark
  shows. The path data is untouched — this selects the icon portion of the
  official asset rather than redrawing it. Do not try to "fix" the odd viewBox.
- **Google Workspace has no icon-only mark** — its lockup is pure typography —
  so the row uses the Google "G", which is the recognisable square mark.

`okta.svg` carries no `fill`, so it renders black. That is how the CC0 asset
ships and is a real monochrome presentation of the mark; it sits on the white
chip in `docs.html.heex`, so it reads correctly. Set a fill only against an
actual Okta brand reference, never a guess.

The chip matters: several of these marks are dark (JumpCloud is `#002B49`, Okta
is black) and are illegible directly on the near-black docs page. Rendering them
on a white tile keeps every vendor's true colours instead of recolouring
someone's trademark to suit our theme.
