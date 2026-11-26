// /mac/:mackey (spec §4.F): chips of every Mac with runs, then each game on this Mac at its most-run settings,
// sortable (runs, fps, FPS/W, name). /macs lists the Macs.
import type { Env } from "../index.ts";
import { gamesWhere, keysWithRuns, sortGames, type GameAtSettings, type SortKey } from "./data.ts";
import { macName, macTitle, plural } from "./format.ts";
import { Layout } from "./layout.tsx";
import { GamesTable } from "./parts.tsx";

export interface MacPageData {
  macKey: string;
  macs: { key: string; runs: number; games: number }[];
  rows: GameAtSettings[];
  total: number;
  sort: SortKey;
}

export async function loadMac(env: Env, macKey: string, sort: SortKey): Promise<MacPageData | null> {
  const [rows, macs] = await Promise.all([gamesWhere(env, "mac_key", macKey), keysWithRuns(env, "mac_key")]);
  if (rows.length === 0) return null;
  return { macKey, macs, rows: sortGames(rows, sort), total: rows.reduce((n, r) => n + r.total, 0), sort };
}

export function MacChips(props: { macs: { key: string }[]; current?: string }) {
  return (
    <nav class="chips" aria-label="Macs">
      {props.macs.map((m) => (
        <a class="chip-link" href={`/mac/${m.key}`} aria-current={m.key === props.current ? "page" : undefined}>
          {macTitle(m.key)}
        </a>
      ))}
    </nav>
  );
}

export function MacPage(props: { d: MacPageData }) {
  const d = props.d;
  const title = macTitle(d.macKey);
  return (
    <Layout title={title} section="macs" description={`Games on ${title}, published from Metal-PT.`}>
      <MacChips macs={d.macs} current={d.macKey} />
      <section class="stack">
        <h1>{title}</h1>
        <p class="muted" style="font-size:15px">
          {plural(d.total, "run")} of {plural(d.rows.length, "game")} · each game shown at its most-tested settings
        </p>
      </section>
      <section class="card clip" aria-label="Games on this Mac">
        <div class="card-head">
          <h2>Games</h2>
          <span class="small muted">Sort by a column heading</span>
        </div>
        <GamesTable rows={d.rows} by="setup" sort={d.sort} base={`/mac/${d.macKey}`} />
        <div class="card-foot">
          <span>FPS / W uses whole-Mac power, display included — compare on the same Mac.</span>
        </div>
      </section>
    </Layout>
  );
}

export async function loadMacs(env: Env) {
  return keysWithRuns(env, "mac_key");
}

export function MacsPage(props: { macs: { key: string; runs: number; games: number }[] }) {
  return (
    <Layout title="Macs" section="macs" description="Every Mac with runs published from Metal-PT.">
      <section class="stack">
        <h1>Macs</h1>
        <p class="muted">Grouped by chip and GPU cores. Memory is shown on each run.</p>
      </section>
      <section class="card clip">
        {props.macs.length === 0 ? (
          <p class="empty">No runs yet.</p>
        ) : (
          <ul class="list">
            {props.macs.map((m) => (
              <li>
                <a class="t" href={`/mac/${m.key}`}>
                  {macName(m.key).chip}
                  {macName(m.key).gpu ? <span class="muted" style="font-weight:400"> · {macName(m.key).gpu}</span> : null}
                </a>
                <span class="muted">
                  {plural(m.runs, "run")} of {plural(m.games, "game")}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>
    </Layout>
  );
}
