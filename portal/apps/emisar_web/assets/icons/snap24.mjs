// Snaps the 24-grid REGULAR masters to the half grid, so 24px 1:1 rendering
// (docs index, empty states, marketing) gets the same device-pixel crispness
// as the native 16 cuts: a 1.5px stroke centered on the half grid lands both
// edges on pixel boundaries at every integer display scale, and a half-grid
// coordinate doubled (the 48px render) stays integer.
//
// Masked, pixel-tuned, transformed, and official-artwork masters are exempt —
// their sub-quarter optical nudges are deliberate. Displacement is bounded at
// 0.25u (= 0.25px at 24px), verified by the sheet after every run.
import fs from "node:fs";
import path from "node:path";

const root = path.join(path.dirname(new URL(import.meta.url).pathname), "..", "..", "priv", "icons");
const halfG = v => Math.round(v * 2) / 2;
const quarterG = v => Math.round(v * 4) / 4;
const fmt = v => String(Math.round(v * 100) / 100);

const EXEMPT = new Set([
  "action/retry", "communication/prompt_suppressed", "security/redacted",
  "state/magic_link_sent", "state/offline", "state/revoked", "state/selected",
  "trust/untrusted", "action/replay", "action/restore",
  "infrastructure/kubernetes", "infrastructure/nomad", "action/clear_filters",
]);

function rebuildPath(d) {
  const tokens = d.match(/[MmLlHhVvCcSsQqTtAaZz]|-?\d*\.?\d+(?:e-?\d+)?/g);
  let i = 0, x = 0, y = 0, sx = 0, sy = 0;
  const out = [];
  const read = () => parseFloat(tokens[i++]);
  const more = () => i < tokens.length && !/[A-Za-z]/.test(tokens[i]);
  const P = v => fmt(halfG(v));
  while (i < tokens.length) {
    const cmd = tokens[i++];
    const rel = cmd === cmd.toLowerCase() && !"zZ".includes(cmd);
    switch (cmd.toUpperCase()) {
      case "M": {
        let first = true;
        while (more()) {
          const px = read(), py = read();
          x = rel && !(first && out.length === 0) ? x + px : px;
          y = rel && !(first && out.length === 0) ? y + py : py;
          out.push(`${first ? "M" : "L"}${P(x)} ${P(y)}`);
          if (first) { sx = x; sy = y; first = false; }
        }
        break;
      }
      case "L": while (more()) { const px = read(), py = read(); x = rel ? x + px : px; y = rel ? y + py : py; out.push(`L${P(x)} ${P(y)}`); } break;
      case "H": while (more()) { const px = read(); x = rel ? x + px : px; out.push(`H${P(x)}`); } break;
      case "V": while (more()) { const py = read(); y = rel ? y + py : py; out.push(`V${P(y)}`); } break;
      case "C": while (more()) {
        const c = [read(), read(), read(), read(), read(), read()];
        const a = rel ? [x + c[0], y + c[1], x + c[2], y + c[3], x + c[4], y + c[5]] : c;
        x = a[4]; y = a[5];
        out.push(`C${fmt(quarterG(a[0]))} ${fmt(quarterG(a[1]))} ${fmt(quarterG(a[2]))} ${fmt(quarterG(a[3]))} ${P(a[4])} ${P(a[5])}`);
      } break;
      case "S": while (more()) {
        const c = [read(), read(), read(), read()];
        const a = rel ? [x + c[0], y + c[1], x + c[2], y + c[3]] : c;
        x = a[2]; y = a[3];
        out.push(`S${fmt(quarterG(a[0]))} ${fmt(quarterG(a[1]))} ${P(a[2])} ${P(a[3])}`);
      } break;
      case "Q": while (more()) {
        const c = [read(), read(), read(), read()];
        const a = rel ? [x + c[0], y + c[1], x + c[2], y + c[3]] : c;
        x = a[2]; y = a[3];
        out.push(`Q${fmt(quarterG(a[0]))} ${fmt(quarterG(a[1]))} ${P(a[2])} ${P(a[3])}`);
      } break;
      case "T": while (more()) { const px = read(), py = read(); x = rel ? x + px : px; y = rel ? y + py : py; out.push(`T${P(x)} ${P(y)}`); } break;
      case "A": while (more()) {
        const rx = read(), ry = read(), rot = read(), large = read(), sweep = read();
        const px = read(), py = read();
        x = rel ? x + px : px; y = rel ? y + py : py;
        out.push(`A${fmt(halfG(rx))} ${fmt(halfG(ry))} ${fmt(rot)} ${large} ${sweep} ${P(x)} ${P(y)}`);
      } break;
      case "Z": x = sx; y = sy; out.push("Z"); break;
    }
  }
  return out.join("");
}

let written = 0;
for (const ns of fs.readdirSync(root).sort()) {
  const dir = path.join(root, ns);
  for (const f of fs.readdirSync(dir).sort()) {
    if (!f.endsWith(".svg") || f.endsWith(".16.svg")) continue;
    const key = `${ns}/${f.replace(/\.svg$/, "")}`;
    if (EXEMPT.has(key)) continue;
    const src = fs.readFileSync(path.join(dir, f), "utf8");
    if (/<defs>|transform=/.test(src)) continue;
    const out = src.replace(/<(path|circle|rect|ellipse|line)\b[^>]*\/?>(<\/\1>)?/g, tag => {
      const dot = /fill="currentColor"|accent-fill|warn-fill|danger-fill/.test(tag);
      return tag
        .replace(/\bd="([^"]+)"/g, (_m, d) => `d="${rebuildPath(d)}"`)
        .replace(/\b(cx|cy|x|y|x1|y1|x2|y2)="(-?\d*\.?\d+)"/g, (_m, a, v) => `${a}="${fmt(halfG(parseFloat(v)))}"`)
        .replace(/\br="(-?\d*\.?\d+)"/g, (_m, v) => `r="${fmt(dot ? Math.max(1, quarterG(parseFloat(v))) : halfG(parseFloat(v)))}"`)
        .replace(/\b(rx|ry|width|height)="(-?\d*\.?\d+)"/g, (_m, a, v) => `${a}="${fmt(halfG(parseFloat(v)))}"`);
    });
    if (out !== src) { fs.writeFileSync(path.join(dir, f), out); written++; }
  }
}
console.log("snapped:", written);
