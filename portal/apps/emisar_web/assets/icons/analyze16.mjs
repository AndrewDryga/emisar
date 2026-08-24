// Optical audit of the native 16-grid cuts: true geometry bounds (stroke
// included), shape class, and the deviation from that class's target size —
// the pass a professional set does that a generated one hasn't had.
import fs from "node:fs";
import path from "node:path";
import {bodyPoints, bounds} from "./geometry.mjs";

const root = path.join(path.dirname(new URL(import.meta.url).pathname), "..", "..", "priv", "icons");

// Optical size classes on the 16 grid, stroke ink included (1px → ±0.5).
// Round forms overshoot squares slightly so everything FEELS equal; wide
// forms cap width and give height back.
export const TARGETS = {round: 14.0, square: 13.5, wide: 14.5};

export function classify(b, arcRatio) {
  const aspect = b.w / b.h;
  if (aspect >= 1.45 || aspect <= 0.62) return "wide";
  if (arcRatio > 0.55 && Math.abs(aspect - 1) < 0.2) return "round";
  return "square";
}

export function audit() {
  const rows = [];
  for (const ns of fs.readdirSync(root).sort()) {
    for (const f of fs.readdirSync(path.join(root, ns)).sort()) {
      if (!f.endsWith(".16.svg")) continue;
      const src = fs.readFileSync(path.join(root, ns, f), "utf8");
      if (!src.includes('viewBox="0 0 16 16"')) continue;
      const body = src.match(/<svg[^>]*>([\s\S]*)<\/svg>/)[1];
      const {points, arcRatio} = bodyPoints(body);
      if (!points.length) continue;
      const b = bounds(points);
      const ink = {w: b.w + 1, h: b.h + 1};
      const cls = classify(b, arcRatio);
      const major = Math.max(ink.w, ink.h);
      rows.push({
        token: `${ns}.${f.replace(/\.16\.svg$/, "")}`,
        file: path.join(root, ns, f),
        cls, major: +major.toFixed(2),
        w: +ink.w.toFixed(2), h: +ink.h.toFixed(2),
        dx: +(b.cx - 8).toFixed(2), dy: +(b.cy - 8).toFixed(2),
        scale: +(TARGETS[cls] / major).toFixed(3),
        handCut: src.includes("data-hand-cut"),
      });
    }
  }
  return rows;
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const rows = audit();
  const off = rows.filter(r => Math.abs(1 - r.scale) > 0.04 || Math.abs(r.dx) > 0.35 || Math.abs(r.dy) > 0.35);
  console.log(`cuts: ${rows.length}   outliers: ${off.length}`);
  console.log("token".padEnd(36), "cls".padEnd(7), "w×h".padEnd(14), "off-center".padEnd(12), "scale→");
  for (const r of off.sort((a, b) => a.scale - b.scale)) {
    console.log(r.token.padEnd(36), r.cls.padEnd(7), `${r.w}×${r.h}`.padEnd(14), `${r.dx},${r.dy}`.padEnd(12), r.scale);
  }
}
