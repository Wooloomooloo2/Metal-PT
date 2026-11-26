// Pieces shared by several pages: the range bar, run cards, the games-at-settings table (Mac and setup pages).
import { niceMax } from "./chart.ts";
import type { GameAtSettings, RunRow, SortKey } from "./data.ts";
import { notCountedReason, systemFPW } from "./data.ts";
import { DASH, fps, fpw, macName, settingsLine, setupShort } from "./format.ts";

const pct = (v: number, max: number) => `${Math.max(0, Math.min(100, (v / max) * 100)).toFixed(1)}%`;

/** The middle half of runs (25th–75th percentile) with the typical value marked, on a 0…`max` scale. */
export function RangeBar(props: { p25: number; p75: number; typical: number; max: number }) {
  const { p25, p75, typical, max } = props;
  return (
    <div class="range">
      <div class="bar" aria-hidden="true">
        <div class="mid" style={`left:${pct(p25, max)};width:${pct(p75 - p25, max)}`}></div>
        <div class="typ" style={`left:${pct(typical, max)}`}></div>
      </div>
      <span class="num tiny muted nw">
        {fps(p25)}–{fps(p75)}
      </span>
    </div>
  );
}

/** A round axis top for a set of range rows. */
export function rangeMax(values: (number | null | undefined)[]): number {
  let m = 0;
  for (const v of values) if (v != null && Number.isFinite(v) && v > m) m = v;
  return niceMax(m);
}

/** "M4 Max · CrossOver 25" / settings / "49 fps · 0.39 FPS/W". */
export function RunCard(props: { run: RunRow; showGame?: boolean; uncapped?: boolean }) {
  const r = props.run;
  const w = systemFPW(r);
  const why = notCountedReason(r, props.uncapped ?? false);
  return (
    <a class="run-card" href={`/run/${r.id}`}>
      {props.showGame ? <span class="t">{r.game_title}</span> : null}
      <span class={props.showGame ? "small" : "t"}>
        {macName(r.mac_key).chip} · {setupShort(r.setup_label)}
      </span>
      <span class="small muted">{settingsLine(r)}</span>
      <span class="num">
        {fps(r.median_fps)} fps{w !== null ? <> · <span class="fpw">{fpw(w)} FPS/W</span></> : null}
      </span>
      {why !== null ? <span class="tiny muted">Not counted: {why}</span> : null}
    </a>
  );
}

/** One game per row at its most-run settings (spec §4.F Mac and setup pages). `by` is the column that varies. */
export function GamesTable(props: { rows: GameAtSettings[]; by: "setup" | "mac"; sort: SortKey; base: string }) {
  const sortLink = (key: SortKey, text: string) => (
    <a href={`${props.base}?sort=${key}`} aria-current={props.sort === key ? "true" : undefined}>
      {text}
      {props.sort === key ? " ↓" : ""}
    </a>
  );
  return (
    <div class="table-box">
      <table class="data wide">
        <thead>
          <tr>
            <th>{sortLink("name", "Game")}</th>
            <th>{props.by === "setup" ? "Setup" : "Mac"}</th>
            <th>Settings</th>
            <th>{sortLink("fps", "Typical fps")}</th>
            <th>Range</th>
            <th>{sortLink("fpw", "FPS / W")}</th>
            <th>{sortLink("runs", "Runs")}</th>
          </tr>
        </thead>
        <tbody>
          {props.rows.map((r) => (
            <tr>
              <td class="strong">
                <a href={`/game/${r.game_slug}`} style="color:#14161A">
                  {r.game_title}
                </a>
              </td>
              <td class="nw">
                {props.by === "setup" ? (
                  <a href={`/setup/${r.setup_key}`}>{r.setup_label}</a>
                ) : (
                  <a href={`/mac/${r.mac_key}`}>{macName(r.mac_key).chip}</a>
                )}
                {props.by === "mac" ? <div class="sub">{macName(r.mac_key).gpu}</div> : null}
              </td>
              <td class="muted nw">{settingsLine(r)}</td>
              {r.typical_fps !== null && r.p25_fps !== null && r.p75_fps !== null ? (
                <>
                  <td class="num big">{fps(r.typical_fps)}</td>
                  <td class="num muted nw">
                    {fps(r.p25_fps)}–{fps(r.p75_fps)}
                    {r.capped_at !== null ? <> <span class="tag cap">Capped at {r.capped_at}</span></> : null}
                  </td>
                  <td class="num fpw strong">{r.typical_fpw !== null ? fpw(r.typical_fpw) : DASH}</td>
                </>
              ) : (
                <td class="note" colspan={3}>
                  {r.counted !== null ? `Not enough runs yet (${r.counted})` : "Not counted (on battery, Low Power or unknown setup)"}
                  {r.capped_at !== null ? <> <span class="tag cap">Capped at {r.capped_at}</span></> : null}
                </td>
              )}
              <td class="num">{r.n}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
