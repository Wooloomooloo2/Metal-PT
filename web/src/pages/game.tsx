// /game/:slug (spec §4.F): settings pickers (default: the most-run combination; GET query, shareable), "How it runs"
// (one row per Mac × setup at those settings, from the cached group statistics), the outlier / not-counted note with
// "Show them", recent runs, and every settings combination.
import type { Env } from "../index.ts";
import {
  comboKey, comboOf, comboQuery, gameBySlug, notCountedReason, RUN_COLS, uncappedGroups,
  type Combo, type GameRow, type GroupRow, type RunRow,
} from "./data.ts";
import { DASH, date, fps, fpw, frameGen, macName, plural, preset, resolution, settingsLine, upscaler } from "./format.ts";
import { Layout } from "./layout.tsx";
import { RangeBar, rangeMax, RunCard } from "./parts.tsx";

const PRESET_ORDER = ["low", "medium", "high", "veryHigh", "ultra", "custom"];

interface Row {
  groupKey: string;
  macKey: string;
  setupKey: string;
  setupLabel: string;
  runs: RunRow[];
  group: GroupRow | undefined;
}

export interface GamePageData {
  game: GameRow;
  url: string;
  total: number;
  macs: number;
  last: string | null;
  combos: { combo: Combo; n: number }[];
  selected: Combo;
  rows: Row[];
  /** Not counted at the selected settings (outliers first), with why. */
  setAside: { run: RunRow; why: string }[];
  outliers: number;
  recent: RunRow[];
  uncapped: Set<string>;
}

export async function loadGame(env: Env, slug: string, query: Record<string, string>, url: string): Promise<GamePageData | null> {
  const game = await gameBySlug(env, slug);
  if (game === null) return null;
  const [runsRes, groupsRes, macsRow] = await Promise.all([
    env.DB.prepare(
      `SELECT ${RUN_COLS} FROM runs r JOIN games g ON g.id = r.game_id WHERE r.game_id = ? AND r.hidden = 0
        ORDER BY r.published DESC, r.id LIMIT 5000`,
    )
      .bind(game.id)
      .all<RunRow>(),
    env.DB.prepare(
      `SELECT group_key, game_id, mac_key, setup_key, runs, macs, typical_fps, p25_fps, p75_fps, typical_fpw, outliers,
              capped_at FROM "groups" WHERE game_id = ?`,
    )
      .bind(game.id)
      .all<GroupRow>(),
    env.DB.prepare("SELECT count(DISTINCT key_id) AS n FROM runs WHERE game_id = ? AND hidden = 0").bind(game.id).first<{ n: number }>(),
  ]);
  const runs = runsRes.results;
  const groups = new Map(groupsRes.results.map((g) => [g.group_key, g]));

  // Combinations by run count (ties: the most recent first, as runs are newest first).
  const combos = new Map<string, { combo: Combo; n: number }>();
  for (const r of runs) {
    const c = comboOf(r);
    const k = comboKey(c);
    const e = combos.get(k);
    if (e) e.n += 1;
    else combos.set(k, { combo: c, n: 1 });
  }
  const ordered = [...combos.values()].sort((a, b) => b.n - a.n);
  const def = ordered[0]?.combo ?? { preset: "-", res: "-", up: "-", fg: "-" };
  const pick = (k: keyof Combo) => (typeof query[k] === "string" && query[k] !== "" ? query[k].slice(0, 60) : def[k]);
  const selected: Combo = { preset: pick("preset"), res: pick("res"), up: pick("up"), fg: pick("fg") };
  const selKey = comboKey(selected);

  const uncapped = uncappedGroups(runs);
  const byGroup = new Map<string, Row>();
  const setAside: { run: RunRow; why: string }[] = [];
  for (const r of runs) {
    if (comboKey(comboOf(r)) !== selKey) continue;
    let row = byGroup.get(r.group_key);
    if (!row) {
      row = { groupKey: r.group_key, macKey: r.mac_key, setupKey: r.setup_key, setupLabel: r.setup_label, runs: [], group: groups.get(r.group_key) };
      byGroup.set(r.group_key, row);
    }
    row.runs.push(r);
    const why = notCountedReason(r, uncapped.has(r.group_key));
    if (why !== null) setAside.push({ run: r, why });
  }
  const rank = (row: Row) => (row.group?.typical_fps != null ? 0 : row.group ? 1 : 2);
  const rows = [...byGroup.values()].sort(
    (a, b) =>
      rank(a) - rank(b) ||
      (b.group?.typical_fps ?? 0) - (a.group?.typical_fps ?? 0) ||
      b.runs.length - a.runs.length ||
      a.groupKey.localeCompare(b.groupKey),
  );
  setAside.sort((a, b) => Number(b.why === "outlier") - Number(a.why === "outlier"));

  return {
    game,
    url,
    total: runs.length,
    macs: macsRow?.n ?? 0,
    last: runs[0]?.published ?? null,
    combos: ordered,
    selected,
    rows,
    setAside,
    outliers: setAside.filter((s) => s.why === "outlier").length,
    recent: runs.slice(0, 6),
    uncapped,
  };
}

/** Distinct values of one picker, in a sensible order, with labels. */
function options(d: GamePageData, k: keyof Combo): { value: string; label: string }[] {
  const seen = new Map<string, number>();
  for (const { combo, n } of d.combos) seen.set(combo[k], (seen.get(combo[k]) ?? 0) + n);
  if (!seen.has(d.selected[k])) seen.set(d.selected[k], 0);
  let values = [...seen.keys()];
  if (k === "preset") values.sort((a, b) => PRESET_ORDER.indexOf(a) - PRESET_ORDER.indexOf(b));
  else if (k === "res") {
    const px = (v: string) => v.split("x").map(Number).reduce((a, b) => a * b, 1) || 0;
    values.sort((a, b) => px(b) - px(a));
  } else values.sort((a, b) => (seen.get(b) ?? 0) - (seen.get(a) ?? 0));
  const label = (v: string) => {
    if (v === "-") return DASH;
    if (k === "preset") return preset(v);
    if (k === "res") {
      const [w, h] = v.split("x").map(Number);
      return resolution(w, h);
    }
    if (k === "up") {
      if (v === "off") return "Off";
      const i = v.indexOf("-");
      return upscaler(i < 0 ? v : v.slice(0, i), i < 0 ? null : v.slice(i + 1));
    }
    return v === "on" ? "On" : v === "off" ? "Off" : v;
  };
  return values.map((value) => ({ value, label: label(value) }));
}

/** "High · 1440p · MetalFX Quality" from a combo. */
function comboLine(c: Combo): string {
  const [w, h] = c.res.split("x").map(Number);
  const i = c.up.indexOf("-");
  const up = c.up === "-" ? null : c.up === "off" ? "off" : i < 0 ? c.up : c.up.slice(0, i);
  const mode = c.up !== "off" && i >= 0 ? c.up.slice(i + 1) : null;
  return settingsLine({
    preset: c.preset === "-" ? null : c.preset,
    width: Number.isFinite(w) ? w : null,
    height: Number.isFinite(h) ? h : null,
    upscaler: up,
    upscaler_mode: mode,
    frame_gen: null, // the caller adds "Frame gen on/off"
  });
}

/** The Open Graph line: "Cyberpunk 2077 · M4 Max · 62 fps · 0.52 FPS/W" from the top row, else run counts. */
export function gameOGTitle(d: GamePageData): string {
  const top = d.rows[0]?.group;
  if (top && top.typical_fps !== null) {
    const parts = [d.game.title, macName(top.mac_key).chip, `${fps(top.typical_fps)} fps`];
    if (top.typical_fpw !== null) parts.push(`${fpw(top.typical_fpw)} FPS/W`);
    return parts.join(" · ");
  }
  return `${d.game.title} · ${plural(d.total, "run")} on Mac`;
}

function FPWCell(props: { row: Row }) {
  const g = props.row.group!;
  if (g.typical_fpw !== null) return <td class="num fpw strong">{fpw(g.typical_fpw)}</td>;
  const gpuOnly = props.row.runs.some((r) => r.power_source === "gpuOnly");
  return (
    <td class="num muted nw">
      {DASH}
      {gpuOnly ? <span class="tiny" style="font-family:Inter,sans-serif"> GPU-only power</span> : null}
    </td>
  );
}

export function GamePage(props: { d: GamePageData }) {
  const d = props.d;
  const max = rangeMax(d.rows.map((r) => r.group?.p75_fps ?? r.group?.typical_fps ?? null));
  const notOutliers = d.setAside.length - d.outliers;
  const fgOptions = options(d, "fg");
  return (
    <Layout
      title={d.game.title}
      section="games"
      description={`How ${d.game.title} runs on Apple Silicon Macs: ${plural(d.total, "run")} published from Metal-PT.`}
      og={{ title: gameOGTitle(d), description: `${plural(d.total, "run")} on ${plural(d.macs, "Mac")}, published from Metal-PT.`, url: d.url }}
    >
      <section class="page-head">
        <div class="stack">
          <h1>{d.game.title}</h1>
          <p class="muted">
            {plural(d.total, "run")} on {plural(d.macs, "Mac")}
            {d.game.steam_id ? ` · Steam app ${d.game.steam_id}` : ""}
            {d.last ? ` · last run ${date(d.last)}` : ""}
          </p>
        </div>
        <a href="#combinations">All settings combinations ({d.combos.length})</a>
      </section>

      <form class="card pickers" method="get" action={`/game/${d.game.slug}`} data-autosubmit aria-label="Settings">
        <div class="field">
          <label class="label" for="preset">Preset</label>
          <select id="preset" name="preset">
            {options(d, "preset").map((o) => (
              <option value={o.value} selected={o.value === d.selected.preset}>{o.label}</option>
            ))}
          </select>
        </div>
        <div class="field">
          <label class="label" for="res">Resolution</label>
          <select id="res" name="res">
            {options(d, "res").map((o) => (
              <option value={o.value} selected={o.value === d.selected.res}>{o.label}</option>
            ))}
          </select>
        </div>
        <div class="field">
          <label class="label" for="up">Upscaler</label>
          <select id="up" name="up">
            {options(d, "up").map((o) => (
              <option value={o.value} selected={o.value === d.selected.up}>{o.label}</option>
            ))}
          </select>
        </div>
        <fieldset class="field">
          <legend class="label">Frame generation</legend>
          <div class="seg">
            {fgOptions.map((o) => (
              <label>
                <input type="radio" name="fg" value={o.value} checked={o.value === d.selected.fg} />
                <span>{o.label}</span>
              </label>
            ))}
          </div>
        </fieldset>
        <button class="btn small" type="submit">Show</button>
      </form>

      <section class="card clip" aria-label="Results by Mac">
        <div class="card-head">
          <h2>How it runs</h2>
          <span class="small muted">Typical = median · bar = middle half of runs (25th–75th percentile)</span>
        </div>
        {d.rows.length === 0 ? (
          <p class="empty">
            No runs at these settings yet. <a href="#combinations">See the settings people have run.</a>
          </p>
        ) : (
          <div class="table-box">
            <table class="data wide">
              <thead>
                <tr>
                  <th>Mac</th>
                  <th>Setup</th>
                  <th>Typical fps</th>
                  <th style="width:34%">
                    Range <span class="unit">0 — {max} fps</span>
                  </th>
                  <th>FPS / W</th>
                  <th>Runs</th>
                </tr>
              </thead>
              <tbody>
                {d.rows.map((row) => {
                  const g = row.group;
                  const name = macName(row.macKey);
                  // The row's runs side by side, counted ones first (the first is the baseline).
                  const counted = (r: RunRow) => notCountedReason(r, d.uncapped.has(r.group_key)) === null;
                  const compareIds = [...row.runs.filter(counted), ...row.runs.filter((r) => !counted(r))]
                    .slice(0, 6)
                    .map((r) => r.id)
                    .join(",");
                  return (
                    <tr>
                      <td class="nw">
                        <a href={`/mac/${row.macKey}`} class="strong" style="color:#14161A;text-decoration:none">{name.chip}</a>
                        {name.gpu ? <div class="sub">{name.gpu}</div> : null}
                      </td>
                      <td class="nw">
                        <a href={`/setup/${row.setupKey}`} style="color:#14161A;text-decoration:none">{row.setupLabel}</a>
                      </td>
                      {g && g.typical_fps !== null && g.p25_fps !== null && g.p75_fps !== null ? (
                        <>
                          <td class="num big">
                            {fps(g.typical_fps)}
                            {g.capped_at !== null ? <div><span class="tag cap">Capped at {g.capped_at}</span></div> : null}
                          </td>
                          <td>
                            <RangeBar p25={g.p25_fps} p75={g.p75_fps} typical={g.typical_fps} max={max} />
                          </td>
                          <FPWCell row={row} />
                        </>
                      ) : g ? (
                        <td class="note" colspan={3}>
                          Not enough runs yet ({g.runs})
                          <span class="tiny"> — a typical and range need 3 runs from 2 Macs</span>
                          {g.capped_at !== null ? <> <span class="tag cap">Capped at {g.capped_at}</span></> : null}
                        </td>
                      ) : (
                        <td class="note" colspan={3}>
                          Not counted: {[...new Set(row.runs.map((r) => notCountedReason(r, d.uncapped.has(r.group_key)) ?? "not counted"))].join(", ")}
                        </td>
                      )}
                      <td class="num">
                        <a href={row.runs.length === 1 ? `/run/${row.runs[0].id}` : `/compare?runs=${compareIds}`}>{row.runs.length}</a>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
        <div class="card-foot">
          {d.setAside.length > 0 ? (
            <details>
              <summary>
                <span class="muted">
                  {d.outliers > 0
                    ? `${plural(d.outliers, "run")} set aside as ${d.outliers === 1 ? "an outlier" : "outliers"} and not counted. `
                    : ""}
                  {notOutliers > 0
                    ? `${plural(notOutliers, "run")} not counted (on battery, Low Power, frame-capped or unknown setup). `
                    : ""}
                </span>
                Show them
              </summary>
              <ul class="list" style="margin-top:10px">
                {d.setAside.map(({ run, why }) => (
                  <li>
                    <a class="t" href={`/run/${run.id}`}>
                      {macName(run.mac_key).chip} · {run.setup_label}
                    </a>
                    <span class="num">{fps(run.median_fps)} fps</span>
                    <span class="muted">{why}</span>
                  </li>
                ))}
              </ul>
            </details>
          ) : null}
          <span>FPS / W uses whole-Mac power, display included — compare on the same Mac.</span>
        </div>
      </section>

      <section class="stack" style="gap:12px" aria-label="Recent runs">
        <h2>Recent runs</h2>
        <div class="cards">
          {d.recent.map((r) => (
            <RunCard run={r} uncapped={d.uncapped.has(r.group_key)} />
          ))}
        </div>
      </section>

      <section class="card clip" id="combinations" aria-label="All settings combinations">
        <div class="card-head">
          <h2>All settings combinations</h2>
          <span class="small muted">{plural(d.combos.length, "combination")}</span>
        </div>
        <ul class="list">
          {d.combos.map(({ combo, n }) => (
            <li>
              <a href={`/game/${d.game.slug}?${comboQuery(combo)}`}>
                {comboLine(combo)} · {frameGen(combo.fg === "-" ? null : combo.fg)}
              </a>
              <span class="muted">{plural(n, "run")}</span>
            </li>
          ))}
        </ul>
      </section>
    </Layout>
  );
}
