import { useEffect, useMemo, useRef, useState } from "react";
import { cadences, countdown, nextSettlement, usd, type RatePoint } from "../funding";

const H = 3_600_000;
const NOTIONAL = 10_000;

/** The demo's hero: one rate history, three settlement cadences. Ours accrues every second (smooth); venues
 * that settle hourly or every 8 hours pay the same money later, in steps. */
export function CadenceChart({ points, now }: { points: RatePoint[]; now: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const [w, setW] = useState(760);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => setW(Math.max(320, e.contentRect.width)));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const data = useMemo(() => cadences(points, NOTIONAL, now), [points, now]);
  const h = 340, padL = 54, padR = 220, padT = 18, padB = 34;
  if (data.length < 2) return <div ref={ref} className="chart-wrap empty">Loading the last 24 hours of rates…</div>;

  const t0 = data[0].t, t1 = data[data.length - 1].t;
  const ys = data.flatMap((d) => [d.smooth, d.hourly, d.eightHour]);
  let lo = Math.min(0, ...ys), hi = Math.max(0, ...ys);
  const pad = (hi - lo || 1) * 0.12;
  lo -= lo < 0 ? pad : 0;
  hi += pad;
  const x = (t: number) => padL + ((t - t0) / (t1 - t0)) * (w - padL - padR);
  const y = (v: number) => padT + (1 - (v - lo) / (hi - lo)) * (h - padT - padB);

  const smooth = data.map((d, i) => `${i ? "L" : "M"}${x(d.t).toFixed(1)},${y(d.smooth).toFixed(1)}`).join("");
  const area = `${smooth}L${x(t1).toFixed(1)},${y(0).toFixed(1)}L${x(t0).toFixed(1)},${y(0).toFixed(1)}Z`;
  const step = (key: "hourly" | "eightHour") =>
    data.map((d, i) => (i === 0 ? `M${x(d.t)},${y(d[key])}` : `H${x(d.t).toFixed(1)}V${y(d[key]).toFixed(1)}`)).join("");

  const ticks = 4;
  const yTicks = Array.from({ length: ticks + 1 }, (_, i) => lo + ((hi - lo) * i) / ticks);
  const xTicks: number[] = [];
  for (let t = Math.ceil(t0 / (4 * H)) * 4 * H; t <= t1; t += 4 * H) xTicks.push(t);
  const eightMarks: number[] = [];
  for (let t = Math.ceil(t0 / (8 * H)) * 8 * H; t <= t1; t += 8 * H) eightMarks.push(t);

  const last = data[data.length - 1];
  // direct labels at the right end, nudged apart so they never overlap
  const labels = [
    { key: "smooth", text: "accrued every second", v: last.smooth, cls: "signal" },
    { key: "hourly", text: "settled hourly", v: last.hourly, cls: "" },
    { key: "eight", text: "settled every 8 hours", v: last.eightHour, cls: "" },
  ]
    .map((l) => ({ ...l, ly: y(l.v) }))
    .sort((a, b) => a.ly - b.ly);
  for (let i = 1; i < labels.length; i++) labels[i].ly = Math.max(labels[i].ly, labels[i - 1].ly + 34);
  const gap = last.smooth - last.eightHour;
  const fmtH = (t: number) => new Date(t).toISOString().slice(11, 16);

  return (
    <div ref={ref} className="chart-wrap">
      <div className="clocks">
        <span className="chip signal">ours: <b>every second</b></span>
        <span className="chip">hourly venues settle in <b>{countdown(nextSettlement(now, 1) - now)}</b></span>
        <span className="chip">8-hour venues settle in <b>{countdown(nextSettlement(now, 8) - now)}</b></span>
      </div>
      <svg className="chart" width={w} height={h} role="img"
           aria-label="Cumulative funding paid by a $10,000 long over 24 hours under three settlement cadences">
        <g className="axis">
          {yTicks.map((v) => (
            <g key={v}>
              <line className="gridline" x1={padL} x2={w - padR} y1={y(v)} y2={y(v)} />
              <text x={padL - 8} y={y(v) + 4} textAnchor="end">{usd(v, hi - lo < 0.1 ? 4 : 2)}</text>
            </g>
          ))}
          {xTicks.map((t) => (
            <text key={t} x={x(t)} y={h - 10} textAnchor="middle">{fmtH(t)} UTC</text>
          ))}
        </g>
        {eightMarks.map((t) => (
          <line key={t} className="settle-mark" x1={x(t)} x2={x(t)} y1={padT} y2={h - padB} />
        ))}
        <path className="area" d={area} />
        <path className="step1" d={step("hourly")} />
        <path className="step8" d={step("eightHour")} />
        <path className="smooth" d={smooth} />
        <line className="now" x1={x(t1)} x2={x(t1)} y1={padT} y2={h - padB} />
        {Math.abs(gap) > 1e-9 && (
          <line className="gap" x1={x(t1) + 6} x2={x(t1) + 6} y1={y(last.smooth)} y2={y(last.eightHour)} />
        )}
        <circle className="pulse" cx={x(t1)} cy={y(last.smooth)} r={4} />
        <circle fill="var(--signal)" cx={x(t1)} cy={y(last.smooth)} r={4} />
        {labels.map((l) => (
          <text key={l.key} className={`label ${l.cls}`} x={x(t1) + 16} y={l.ly + 4}>
            <tspan>{l.text}</tspan>
            <tspan className="v" x={x(t1) + 16} dy={15}>{usd(l.v, 4)}</tspan>
          </text>
        ))}
      </svg>
      <p className="chart-note">
        Paid by a $10,000 long over the last 24 hours, on one rate history: the median of Binance, OKX, Bybit,
        Hyperliquid and Bitget predicted funding, recorded every minute. Same money, different timing: right now a
        long on an 8-hour venue has run up <span className="mono">{usd(gap, 4)}</span> it has not paid yet, and can
        leave before the next settlement without paying it.
      </p>
    </div>
  );
}
