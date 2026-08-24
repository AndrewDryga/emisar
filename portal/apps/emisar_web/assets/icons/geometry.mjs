// Shared geometry for the icon tooling: absolute-path sampling and bounds.
// The cutter emits absolute-only commands, so this parses exactly that set.

export function parsePath(d) {
  const tokens = d.match(/[MLHVCSQTAZ]|-?\d*\.?\d+(?:e-?\d+)?/gi) || [];
  const segments = [];
  let i = 0, x = 0, y = 0, sx = 0, sy = 0;
  const read = () => parseFloat(tokens[i++]);
  while (i < tokens.length) {
    const cmd = tokens[i++];
    switch (cmd) {
      case "M": {
        let first = true;
        while (i < tokens.length && !/[A-Za-z]/.test(tokens[i])) {
          x = read(); y = read();
          if (first) { sx = x; sy = y; first = false; }
          else segments.push({kind: "L", x0: sx, y0: sy, x, y});
          segments.push({kind: "M", x, y});
        }
        break;
      }
      case "L": while (i < tokens.length && !/[A-Za-z]/.test(tokens[i])) {
        const nx = read(), ny = read();
        segments.push({kind: "L", x0: x, y0: y, x: nx, y: ny}); x = nx; y = ny;
      } break;
      case "H": while (i < tokens.length && !/[A-Za-z]/.test(tokens[i])) {
        const nx = read();
        segments.push({kind: "L", x0: x, y0: y, x: nx, y}); x = nx;
      } break;
      case "V": while (i < tokens.length && !/[A-Za-z]/.test(tokens[i])) {
        const ny = read();
        segments.push({kind: "L", x0: x, y0: y, x, y: ny}); y = ny;
      } break;
      case "C": while (i < tokens.length && !/[A-Za-z]/.test(tokens[i])) {
        const seg = {kind: "C", x0: x, y0: y, c1x: read(), c1y: read(), c2x: read(), c2y: read(), x: read(), y: read()};
        segments.push(seg); x = seg.x; y = seg.y;
      } break;
      case "S": while (i < tokens.length && !/[A-Za-z]/.test(tokens[i])) {
        const seg = {kind: "C", x0: x, y0: y, c1x: x, c1y: y, c2x: read(), c2y: read(), x: read(), y: read()};
        segments.push(seg); x = seg.x; y = seg.y;
      } break;
      case "Q": while (i < tokens.length && !/[A-Za-z]/.test(tokens[i])) {
        const seg = {kind: "Q", x0: x, y0: y, cx: read(), cy: read(), x: read(), y: read()};
        segments.push(seg); x = seg.x; y = seg.y;
      } break;
      case "T": while (i < tokens.length && !/[A-Za-z]/.test(tokens[i])) {
        const nx = read(), ny = read();
        segments.push({kind: "L", x0: x, y0: y, x: nx, y: ny}); x = nx; y = ny;
      } break;
      case "A": while (i < tokens.length && !/[A-Za-z]/.test(tokens[i])) {
        const seg = {kind: "A", x0: x, y0: y, rx: read(), ry: read(), rot: read(), large: read(), sweep: read(), x: read(), y: read()};
        segments.push(seg); x = seg.x; y = seg.y;
      } break;
      case "Z": case "z":
        segments.push({kind: "L", x0: x, y0: y, x: sx, y: sy}); x = sx; y = sy;
        break;
    }
  }
  return segments;
}

// Endpoint-parameterization arc sampling (SVG spec appendix B.2.4, no rotation
// in this icon set).
function sampleArc(seg, points) {
  const {x0, y0, x, y, large, sweep} = seg;
  let {rx, ry} = seg;
  if (rx === 0 || ry === 0) { points.push([x, y]); return; }
  rx = Math.abs(rx); ry = Math.abs(ry);
  const dx = (x0 - x) / 2, dy = (y0 - y) / 2;
  const l = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry);
  if (l > 1) { rx *= Math.sqrt(l); ry *= Math.sqrt(l); }
  const sign = large !== sweep ? 1 : -1;
  const num = rx * rx * ry * ry - rx * rx * dy * dy - ry * ry * dx * dx;
  const den = rx * rx * dy * dy + ry * ry * dx * dx;
  const co = sign * Math.sqrt(Math.max(0, num / den));
  const cx = co * (rx * dy) / ry + (x0 + x) / 2;
  const cy = co * (-ry * dx) / rx + (y0 + y) / 2;
  const angle = (ux, uy) => Math.atan2(uy, ux);
  const a1 = angle((x0 - cx) / rx, (y0 - cy) / ry);
  let da = angle((x - cx) / rx, (y - cy) / ry) - a1;
  if (!sweep && da > 0) da -= 2 * Math.PI;
  if (sweep && da < 0) da += 2 * Math.PI;
  for (let t = 0; t <= 1.0001; t += 0.04) {
    const a = a1 + da * t;
    points.push([cx + rx * Math.cos(a), cy + ry * Math.sin(a)]);
  }
}

export function sample(segments) {
  const points = [];
  for (const seg of segments) {
    if (seg.kind === "M") points.push([seg.x, seg.y]);
    else if (seg.kind === "L") { points.push([seg.x0, seg.y0], [seg.x, seg.y]); }
    else if (seg.kind === "C") {
      for (let t = 0; t <= 1.0001; t += 0.05) {
        const u = 1 - t;
        points.push([
          u * u * u * seg.x0 + 3 * u * u * t * seg.c1x + 3 * u * t * t * seg.c2x + t * t * t * seg.x,
          u * u * u * seg.y0 + 3 * u * u * t * seg.c1y + 3 * u * t * t * seg.c2y + t * t * t * seg.y,
        ]);
      }
    } else if (seg.kind === "Q") {
      for (let t = 0; t <= 1.0001; t += 0.05) {
        const u = 1 - t;
        points.push([
          u * u * seg.x0 + 2 * u * t * seg.cx + t * t * seg.x,
          u * u * seg.y0 + 2 * u * t * seg.cy + t * t * seg.y,
        ]);
      }
    } else if (seg.kind === "A") sampleArc(seg, points);
  }
  return points;
}

// Geometry points of every drawable element in an svg body.
export function bodyPoints(body) {
  const points = [];
  let arcish = 0, total = 0;
  for (const m of body.matchAll(/<path\b[^>]*\bd="([^"]+)"[^>]*>/g)) {
    const segments = parsePath(m[1]);
    for (const s of segments) { total++; if (s.kind === "A" || s.kind === "C") arcish++; }
    points.push(...sample(segments));
  }
  for (const m of body.matchAll(/<circle\b[^>]*>/g)) {
    const cx = parseFloat((m[0].match(/\bcx="([^"]+)"/) || [])[1] || 0);
    const cy = parseFloat((m[0].match(/\bcy="([^"]+)"/) || [])[1] || 0);
    const r = parseFloat((m[0].match(/\br="([^"]+)"/) || [])[1] || 0);
    total++; arcish++;
    if (r >= 4) arcish += 3;
    for (let a = 0; a < 6.3; a += 0.2) points.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
  }
  for (const m of body.matchAll(/<rect\b[^>]*>/g)) {
    const g = k => parseFloat((m[0].match(new RegExp(`\\b${k}="([^"]+)"`)) || [])[1] || 0);
    const x = g("x"), y = g("y"), w = g("width"), h = g("height");
    total++;
    points.push([x, y], [x + w, y], [x, y + h], [x + w, y + h]);
  }
  return {points, arcRatio: total ? arcish / total : 0};
}

export function bounds(points) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const [x, y] of points) {
    if (x < minX) minX = x; if (x > maxX) maxX = x;
    if (y < minY) minY = y; if (y > maxY) maxY = y;
  }
  return {minX, minY, maxX, maxY, w: maxX - minX, h: maxY - minY,
          cx: (minX + maxX) / 2, cy: (minY + maxY) / 2};
}
