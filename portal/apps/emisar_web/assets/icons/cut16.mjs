// Cuts the native 16-grid compact masters from the 24-grid regulars:
//   scale 2/3 → optical normalization → half-grid snap.
//
// The half grid (.0/.5) is load-bearing: a 1px stroke centered there puts
// both edges on device-pixel boundaries at every integer display scale.
// Optical normalization is the pass a professional set has that a generated
// one doesn't: objects and badges fill the box to their archetype's target
// so everything FEELS equal, while operators (× − chevrons, arrows, the
// decision pair) keep their deliberately smaller glyph sizes.
//
// A file whose existing cut carries `data-hand-cut` is never overwritten —
// that is the escape hatch for cuts tuned by hand. Run from this directory:
//   node cut16.mjs
import fs from "node:fs";
import path from "node:path";
import {bodyPoints, bounds} from "./geometry.mjs";

const root = path.join(path.dirname(new URL(import.meta.url).pathname), "..", "..", "priv", "icons");
const S = 2 / 3;

const halfG = v => Math.round(v * 2) / 2;
const quarterG = v => Math.round(v * 4) / 4;
const fmt = v => String(Math.round(v * 100) / 100);

// Ink targets (stroke included) per optical archetype, and the growth cap
// that keeps small-drawn objects from violent rescaling.
const TARGETS = {round: 14, square: 13.5, wide: 14};
const MAX_GROW = 1.16, MAX_SHRINK = 0.9;

// Operators, arrows, carets, and the balanced decision pair keep their
// deliberate glyph sizes — every professional set draws these smaller than
// containers (the Heroicons × is 47% of its box).
const KEEP_GLYPH_SIZE = new Set([
  "action/add", "action/approve", "action/back", "action/close",
  "action/disclose", "action/download", "action/execute", "action/menu",
  "action/move_down", "action/move_up", "action/next", "action/publish",
  "action/refresh", "action/remove", "action/search", "action/select",
  "action/sign_out", "action/sync", "action/undo", "action/upload",
  "breadcrumb/separator", "diagram/flow_down", "diagram/flow_right",
  "state/cancelled", "state/denied", "state/included",
]);

// Masked, pixel-tuned, transformed, or official artwork: no native cut —
// these render through the zoomed 24-grid projection.
const NO_CUT = new Set([
  "action/retry", "communication/prompt_suppressed", "security/redacted",
  "state/magic_link_sent", "state/offline", "state/revoked", "state/selected",
  "trust/untrusted", "action/replay", "action/restore",
  "infrastructure/kubernetes", "infrastructure/nomad",
]);

// Walks a path's tokens, absolutizing and applying `tx`/`ty` point transforms
// plus `tr` for radii. Snapping happens through the transforms themselves.
function rebuildPath(d, tx, ty, tr) {
  const tokens = d.match(/[MmLlHhVvCcSsQqTtAaZz]|-?\d*\.?\d+(?:e-?\d+)?/g);
  let i = 0, x = 0, y = 0, sx = 0, sy = 0;
  const out = [];
  const read = () => parseFloat(tokens[i++]);
  const more = () => i < tokens.length && !/[A-Za-z]/.test(tokens[i]);
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
          out.push(`${first ? "M" : "L"}${fmt(tx(x))} ${fmt(ty(y))}`);
          if (first) { sx = x; sy = y; first = false; }
        }
        break;
      }
      case "L": while (more()) {
        const px = read(), py = read();
        x = rel ? x + px : px; y = rel ? y + py : py;
        out.push(`L${fmt(tx(x))} ${fmt(ty(y))}`);
      } break;
      case "H": while (more()) {
        const px = read();
        x = rel ? x + px : px;
        out.push(`H${fmt(tx(x))}`);
      } break;
      case "V": while (more()) {
        const py = read();
        y = rel ? y + py : py;
        out.push(`V${fmt(ty(y))}`);
      } break;
      case "C": while (more()) {
        const c = [read(), read(), read(), read(), read(), read()];
        const a = rel ? [x + c[0], y + c[1], x + c[2], y + c[3], x + c[4], y + c[5]] : c;
        x = a[4]; y = a[5];
        out.push(`C${fmt(tx(a[0]))} ${fmt(ty(a[1]))} ${fmt(tx(a[2]))} ${fmt(ty(a[3]))} ${fmt(tx(a[4]))} ${fmt(ty(a[5]))}`);
      } break;
      case "S": while (more()) {
        const c = [read(), read(), read(), read()];
        const a = rel ? [x + c[0], y + c[1], x + c[2], y + c[3]] : c;
        x = a[2]; y = a[3];
        out.push(`S${fmt(tx(a[0]))} ${fmt(ty(a[1]))} ${fmt(tx(a[2]))} ${fmt(ty(a[3]))}`);
      } break;
      case "Q": while (more()) {
        const c = [read(), read(), read(), read()];
        const a = rel ? [x + c[0], y + c[1], x + c[2], y + c[3]] : c;
        x = a[2]; y = a[3];
        out.push(`Q${fmt(tx(a[0]))} ${fmt(ty(a[1]))} ${fmt(tx(a[2]))} ${fmt(ty(a[3]))}`);
      } break;
      case "T": while (more()) {
        const px = read(), py = read();
        x = rel ? x + px : px; y = rel ? y + py : py;
        out.push(`T${fmt(tx(x))} ${fmt(ty(y))}`);
      } break;
      case "A": while (more()) {
        const rx = read(), ry = read(), rot = read(), large = read(), sweep = read();
        const px = read(), py = read();
        x = rel ? x + px : px; y = rel ? y + py : py;
        out.push(`A${fmt(tr(rx))} ${fmt(tr(ry))} ${fmt(rot)} ${large} ${sweep} ${fmt(tx(x))} ${fmt(ty(y))}`);
      } break;
      case "Z": x = sx; y = sy; out.push("Z"); break;
    }
  }
  return out.join("");
}

function transformBody(body, tx, ty, tr, trDot) {
  return body.replace(/<(path|circle|rect|ellipse|line)\b[^>]*\/?>(<\/\1>)?/g, tag => {
    const dot = /fill="currentColor"|accent-fill|warn-fill|danger-fill/.test(tag);
    return tag
      .replace(/\bd="([^"]+)"/g, (_m, d) => `d="${rebuildPath(d, tx, ty, tr)}"`)
      .replace(/\b(cx|x|x1|x2)="(-?\d*\.?\d+)"/g, (_m, a, v) => `${a}="${fmt(tx(parseFloat(v)))}"`)
      .replace(/\b(cy|y|y1|y2)="(-?\d*\.?\d+)"/g, (_m, a, v) => `${a}="${fmt(ty(parseFloat(v)))}"`)
      .replace(/\br="(-?\d*\.?\d+)"/g, (_m, v) => `r="${fmt((dot ? trDot : tr)(parseFloat(v)))}"`)
      .replace(/\b(rx|ry|width|height)="(-?\d*\.?\d+)"/g, (_m, a, v) => `${a}="${fmt(tr(parseFloat(v)))}"`)
      .replace(/\bstroke-width="(-?\d*\.?\d+)"/g, (_m, v) => `stroke-width="${fmt(parseFloat(v) * S * (1.5 / 1.55))}"`);
  });
}

function classify(b, arcRatio) {
  const aspect = b.w / Math.max(b.h, 0.001);
  if (aspect >= 1.45 || aspect <= 0.62) return "wide";
  if (arcRatio > 0.55 && Math.abs(aspect - 1) < 0.2) return "round";
  return "square";
}

let written = 0, kept = 0;
const skipped = [];
for (const ns of fs.readdirSync(root).sort()) {
  const dir = path.join(root, ns);
  for (const f of fs.readdirSync(dir).sort()) {
    if (!f.endsWith(".svg") || f.endsWith(".16.svg")) continue;
    const name = f.replace(/\.svg$/, "");
    const key = `${ns}/${name}`;
    if (NO_CUT.has(key)) { skipped.push(key); continue; }
    const cutPath = path.join(dir, `${name}.16.svg`);
    if (fs.existsSync(cutPath) && fs.readFileSync(cutPath, "utf8").includes("data-hand-cut")) {
      kept++;
      continue;
    }
    const src = fs.readFileSync(path.join(dir, f), "utf8");
    if (/<defs>|transform=|shape-rendering="crispEdges"/.test(src)) { skipped.push(key + " (defs/transform)"); continue; }
    const body = src.match(/<svg[^>]*>([\s\S]*)<\/svg>/)[1].trim();

    // Pass 1: scale 24 → 16 with no snap, so the optical pass measures truth.
    const raw = transformBody(body, v => v * S, v => v * S, v => v * S, v => v * S);

    // Pass 2: optical normalization — archetype target with capped growth,
    // recentered on the box.
    let scale = 1, cx = 8, cy = 8;
    const {points, arcRatio} = bodyPoints(raw);
    if (points.length && !KEEP_GLYPH_SIZE.has(key)) {
      const b = bounds(points);
      const major = Math.max(b.w, b.h) + 1;
      const target = TARGETS[classify(b, arcRatio)];
      scale = Math.min(MAX_GROW, Math.max(MAX_SHRINK, target / major));
      cx = b.cx; cy = b.cy;
    } else if (points.length) {
      const b = bounds(points);
      cx = b.cx; cy = b.cy;
    }

    // Pass 3: apply about the drawing's own centre, land it on the box
    // centre, snap to the crisp grid.
    const px = v => halfG((v - cx) * scale + 8);
    const py = v => halfG((v - cy) * scale + 8);
    const pr = v => halfG(v * scale);
    const prDot = v => Math.max(0.75, quarterG(v * scale));
    const out = transformBody(raw, px, py, pr, prDot);

    fs.writeFileSync(cutPath,
`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
  ${out}
</svg>
`);
    written++;
  }
}
console.log(`written: ${written}  hand-kept: ${kept}  skipped: ${skipped.length}`);
