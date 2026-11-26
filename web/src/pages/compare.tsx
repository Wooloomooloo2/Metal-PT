// /compare?runs=a,b,c (spec §4.F): the first id is the baseline. Verdict sentence in the app's CompareReport wording
// ("N % more/fewer frames per watt than the baseline"), bars, side by side with differing cells highlighted, a warning
// when Macs differ, and "Add a run" from the same game.
import type { Env } from "../index.ts";
import { RUN_ID } from "../db.ts";
import { RUN_COLS, systemFPW, type RunRow } from "./data.ts";
import {
  date, DASH, efficiencyPhrase, fps, fpw, frameGen, macTitle, percentOf, plural, powerSourceLine, preset,
  resolution, settingsLine, setupShort, upscaler, watts,
} from "./format.ts";
import { Layout } from "./layout.tsx";
import { DETAIL_COLS, type RunDetail } from "./run.tsx";

export const MAX_COMPARE = 6;

/** Valid, distinct run ids from `?runs=`, in order, at most 6. */
export function compareIds(param: string | undefined): string[] {
  const out: string[] = [];
  for (const raw of (param ?? "").split(",")) {
    const id = raw.trim();
    if (RUN_ID.test(id) && !out.includes(id)) out.push(id);
    if (out.length === MAX_COMPARE) break;
  }
  return out;
}

export interface CompareData {
  runs: RunDetail[];
  candidates: RunRow[];
  find: string;
}

export async function loadCompare(env: Env, ids: string[], find: string): Promise<CompareData | null> {
  if (ids.length === 0) return null;
  const { results } = await env.DB.prepare(
    `SELECT ${DETAIL_COLS} FROM runs r JOIN games g ON g.id = r.game_id
      WHERE r.hidden = 0 AND r.id IN (${ids.map(() => "?").join(", ")})`,
  )
    .bind(...ids)
    .all<RunDetail>();
  const byId = new Map(results.map((r) => [r.id, r]));
  const runs = ids.map((id) => byId.get(id)).filter((r): r is RunDetail => r !== undefined);
  if (runs.length === 0) return null;
  let candidates: RunRow[] = [];
  if (runs.length < MAX_COMPARE) {
    const f = find.trim().slice(0, 60);
    const like = `%${f.replace(/[\\%_]/g, "\\$&")}%`;
    const filter = f === "" ? "" : `AND (r.setup_label LIKE ?3 ESCAPE '\\' OR r.chip LIKE ?3 ESCAPE '\\' OR r.label LIKE ?3 ESCAPE '\\'
      OR r.preset LIKE ?3 ESCAPE '\\' OR r.upscaler LIKE ?3 ESCAPE '\\' OR r.os_version LIKE ?3 ESCAPE '\\')`;
    const stmt = env.DB.prepare(
      `SELECT ${RUN_COLS} FROM runs r JOIN games g ON g.id = r.game_id
        WHERE r.hidden = 0 AND r.game_id = ?1 AND r.id NOT IN (SELECT value FROM json_each(?2)) ${filter}
        ORDER BY r.published DESC, r.id LIMIT 30`,
    );
    const bound = f === "" ? stmt.bind(runs[0].game_id, JSON.stringify(ids)) : stmt.bind(runs[0].game_id, JSON.stringify(ids), like);
    candidates = (await bound.all<RunRow>()).results;
  }
  return { runs, candidates, find };
}

interface Field {
  label: string;
  value: (r: RunDetail) => string;
  /** Part of a run's short name when it differs. */
  names?: boolean;
}

const FIELDS: Field[] = [
  { label: "Game", value: (r) => r.game_title, names: true },
  { label: "Mac", value: (r) => macTitle(r.mac_key), names: true },
  { label: "Memory", value: (r) => (r.memory_gb ? `${r.memory_gb} GB` : DASH) },
  { label: "macOS", value: (r) => r.os_version ?? DASH, names: true },
  { label: "Setup", value: (r) => (r.runtime && r.runtime !== "native" ? `${r.runtime}${r.runtime_version ? ` ${r.runtime_version}` : ""}${r.graphics_layers ? ` · ${r.graphics_layers}` : ""}` : r.setup_label), names: true },
  { label: "Recorded app", value: (r) => r.recorded_app ?? DASH },
  { label: "Preset", value: (r) => preset(r.preset), names: true },
  { label: "Resolution", value: (r) => resolution(r.width, r.height), names: true },
  { label: "Upscaler", value: (r) => upscaler(r.upscaler, r.upscaler_mode), names: true },
  { label: "Frame generation", value: (r) => frameGen(r.frame_gen), names: true },
  { label: "Median FPS", value: (r) => fps(r.median_fps) },
  { label: "1% low", value: (r) => fps(r.p1_low_fps) },
  { label: "FPS per watt", value: (r) => fpw(systemFPW(r)) },
  { label: "Whole-Mac power", value: (r) => (r.power_source === "system" ? watts(r.mean_system_w) : DASH) },
  { label: "Power source", value: (r) => powerSourceLine(r.on_ac, r.power_mode), names: true },
  { label: "What held it back", value: (r) => r.limiter_verdict ?? DASH },
  { label: "Label", value: (r) => r.label ?? DASH },
  { label: "Recorded", value: (r) => date(r.recorded) || DASH },
];

const MEASURED = new Set(["Median FPS", "1% low", "FPS per watt", "Whole-Mac power", "What held it back"]);

function differs(runs: RunDetail[], f: Field): boolean {
  return new Set(runs.map(f.value)).size > 1;
}

/** Short names from what differs ("Native", "CrossOver 25 · D3DMetal"); the label or date when nothing set differs. */
export function runNames(runs: RunDetail[]): string[] {
  const naming = FIELDS.filter((f) => f.names && differs(runs, f));
  let names = runs.map((r) =>
    naming
      .map((f) => (f.label === "Setup" ? r.setup_label : f.label === "macOS" ? `macOS ${f.value(r)}` : f.value(r)))
      .join(" · "),
  );
  if (names.some((n) => n === "") || new Set(names).size < names.length) {
    names = runs.map((r, i) => r.label || `Run ${i + 1}${r.recorded ? ` (${date(r.recorded)})` : ""}`);
  }
  if (new Set(names).size < names.length) names = names.map((n, i) => `${n} #${i + 1}`);
  return names;
}

const without = (ids: string[], id: string) => ids.filter((x) => x !== id).join(",");

export function ComparePage(props: { d: CompareData }) {
  const { runs, candidates } = props.d;
  const ids = runs.map((r) => r.id);
  const base = runs[0];
  const names = runNames(runs);
  const sameMac = new Set(runs.map((r) => r.mac_key)).size === 1;
  const sameGame = new Set(runs.map((r) => r.game_id)).size === 1;
  const sameSettings = new Set(runs.map((r) => settingsLine(r) + r.frame_gen)).size === 1;
  const baseFPW = systemFPW(base);
  const maxFPS = Math.max(...runs.map((r) => r.median_fps ?? 0), 1);
  const fpws = runs.map((r) => systemFPW(r));
  const maxFPW = Math.max(...fpws.map((v) => v ?? 0), 0.0001);
  const diffFields = FIELDS.filter((f) => !MEASURED.has(f.label) && differs(runs, f));
  const others = runs.slice(1);
  const noPower = others.filter((r) => systemFPW(r) === null);

  const same: string[] = [];
  if (runs.length > 1) {
    if (sameMac) same.push("Same Mac");
    if (sameSettings) same.push(same.length ? "same settings" : "Same settings");
    if (runs.every((r) => r.on_ac === 1)) same.push(`${runs.length === 2 ? "both" : "all"} on mains power`);
  }
  const title = runs.length === 1 ? `Compare ${names[0] || base.game_title}` : names.slice(0, 3).join(" vs ") + (runs.length > 3 ? " …" : "");

  return (
    <Layout title={`${base.game_title}: ${title}`}>
      <section class="page-head">
        <div class="stack">
          {sameGame ? (
            <a class="small" style="font-weight:500" href={`/game/${base.game_slug}`}>
              {base.game_title}
              {sameSettings ? ` · ${settingsLine(base)}` : ""}
            </a>
          ) : null}
          <h1 class="run">
            {runs.length === 1 ? `${base.game_title} on ${macTitle(base.mac_key)}` : title}
            {runs.length > 1 && sameMac ? ` on ${macTitle(base.mac_key).split(" · ")[0]}` : ""}
          </h1>
        </div>
        <div class="actions">
          {runs.length < MAX_COMPARE ? <a class="btn" href="#add">Add a run</a> : null}
          <a class="btn" href={`/compare?runs=${ids.join(",")}`} data-copy>Copy link</a>
        </div>
      </section>

      <section class="verdict" aria-label="Summary">
        {runs.length === 1 ? (
          <p class="s">Add a run of {base.game_title} to compare it with this one (the baseline).</p>
        ) : (
          others.map((r, i) => {
            const speed = percentOf(r.median_fps, base.median_fps);
            const phrase = sameMac ? efficiencyPhrase(systemFPW(r), baseFPW) : null;
            return (
              <p class="s">
                {names[i + 1]} runs at <span class="num">{speed === null ? DASH : `${speed} %`}</span> of the baseline's
                speed{phrase !== null ? <>, with <span class="hi">{phrase}</span></> : null}.
              </p>
            );
          })
        )}
        {runs.length > 1 ? (
          <p class="n">
            {same.length ? `${same.join(", ")}. ` : ""}
            {diffFields.length ? `What differs: ${diffFields.map((f) => (f.label === "Mac" || f.label === "macOS" ? f.label : f.label.toLowerCase())).join(", ")}.` : "No recorded setting differs."}
          </p>
        ) : null}
        {!sameMac ? <p class="warn">FPS/W not comparable across Macs: the runs are on different Macs.</p> : null}
        {sameMac && runs.length > 1 && baseFPW === null ? (
          <p class="n">The baseline has no whole-Mac power reading, so frames per watt aren't compared.</p>
        ) : null}
        {sameMac && baseFPW !== null && noPower.length > 0 ? (
          <p class="n">Left out of FPS/W, no whole-Mac power reading: {noPower.map((r) => names[runs.indexOf(r)]).join(", ")}.</p>
        ) : null}
      </section>

      <section class="card bars" aria-label="Runs">
        {runs.map((r, i) => (
          <div class="bar-row">
            <div class="who">
              <span class="t">
                {names[i]}
                {i === 0 ? <span class="tag base">Baseline</span> : null}
              </span>
              <span class="tiny muted">
                {macTitle(r.mac_key)} · {setupShort(r.setup_label)} · {date(r.recorded) || date(r.published)} ·{" "}
                <a href={`/run/${r.id}`}>open run</a>
                {runs.length > 1 ? <> · <a href={`/compare?runs=${without(ids, r.id)}`}>remove</a></> : null}
              </span>
            </div>
            <div class="meters">
              <div class="meter">
                <div class="track"><div class="fill" style={`width:${(((r.median_fps ?? 0) / maxFPS) * 100).toFixed(1)}%`}></div></div>
                <span class="val num">{fps(r.median_fps)} fps</span>
              </div>
              <div class="meter">
                <div class="track"><div class="fill w" style={`width:${(((fpws[i] ?? 0) / maxFPW) * 100).toFixed(1)}%`}></div></div>
                <span class="val num fpw">{fpws[i] !== null ? `${fpw(fpws[i])} /W` : DASH}</span>
              </div>
            </div>
          </div>
        ))}
        <div class="legend">
          <span><i></i>Median FPS</span>
          <span><i class="w"></i>FPS per watt (whole-Mac power)</span>
        </div>
      </section>

      <section class="card clip" aria-label="Side by side">
        <div class="card-head">
          <h2>Side by side</h2>
          <span class="small muted">Highlighted: differs from the baseline</span>
        </div>
        <div class="table-box">
          <table class={`data ${runs.length > 3 ? "mid" : "narrow"}`}>
            <thead>
              <tr>
                <th></th>
                {runs.map((_, i) => (
                  <th>{names[i]}{i === 0 ? " (baseline)" : ""}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {FIELDS.map((f) => {
                const vals = runs.map(f.value);
                const any = vals.some((v) => v !== vals[0]);
                return (
                  <tr class={any ? "diff" : undefined}>
                    <td class="muted nw">{f.label}</td>
                    {vals.map((v, i) => (
                      <td class={[i > 0 && v !== vals[0] ? "diff" : "", MEASURED.has(f.label) ? "num" : ""].filter((x) => x).join(" ") || undefined}>{v}</td>
                    ))}
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>

      {runs.length < MAX_COMPARE ? (
        <section class="card clip" id="add" aria-label="Add a run">
          <div class="card-head">
            <h2>Add a run of {base.game_title}</h2>
            <form method="get" action="/compare" class="actions" role="search">
              <input type="hidden" name="runs" value={ids.join(",")} />
              <label class="sr" for="find">Find a run</label>
              <input id="find" type="search" name="find" value={props.d.find} placeholder="Mac, setup, preset…" style="max-width:240px" />
              <button class="btn small" type="submit">Find</button>
            </form>
          </div>
          {candidates.length === 0 ? (
            <p class="empty">No other runs{props.d.find ? " match" : " of this game yet"}.</p>
          ) : (
            <ul class="list">
              {candidates.map((c) => (
                <li>
                  <span class="stack" style="gap:2px">
                    <span class="t">
                      {macTitle(c.mac_key)} · {c.setup_label}
                    </span>
                    <span class="tiny muted">
                      {settingsLine(c)} · {date(c.published)}
                      {c.label ? ` · ${c.label}` : ""}
                    </span>
                  </span>
                  <span class="num">{fps(c.median_fps)} fps</span>
                  <a href={`/compare?runs=${[...ids, c.id].join(",")}`}>Add</a>
                </li>
              ))}
            </ul>
          )}
        </section>
      ) : (
        <p class="muted small">{plural(MAX_COMPARE, "run")} is the most a comparison shows.</p>
      )}
    </Layout>
  );
}
