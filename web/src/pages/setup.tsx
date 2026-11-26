// /setup/:setupkey (spec §4.F): the Mac page's table by setup (e.g. everything on CrossOver 25). /setups lists them.
import type { Env } from "../index.ts";
import { gamesWhere, keysWithRuns, sortGames, type GameAtSettings, type SortKey } from "./data.ts";
import { plural } from "./format.ts";
import { Layout } from "./layout.tsx";
import { GamesTable } from "./parts.tsx";

export interface SetupPageData {
  setupKey: string;
  label: string;
  rows: GameAtSettings[];
  total: number;
  sort: SortKey;
}

export async function loadSetup(env: Env, setupKey: string, sort: SortKey): Promise<SetupPageData | null> {
  const rows = await gamesWhere(env, "setup_key", setupKey);
  if (rows.length === 0) return null;
  return {
    setupKey,
    label: rows[0].setup_label,
    rows: sortGames(rows, sort),
    total: rows.reduce((n, r) => n + r.total, 0),
    sort,
  };
}

export function SetupPage(props: { d: SetupPageData }) {
  const d = props.d;
  return (
    <Layout title={d.label} section="setups" description={`Games run with ${d.label}, published from Metal-PT.`}>
      <section class="stack">
        <a class="small" href="/setups" style="font-weight:500">All setups</a>
        <h1>{d.label}</h1>
        <p class="muted" style="font-size:15px">
          {plural(d.total, "run")} of {plural(d.rows.length, "game")} · each game shown at its most-tested settings
        </p>
      </section>
      <section class="card clip" aria-label="Games with this setup">
        <div class="card-head">
          <h2>Games</h2>
          <span class="small muted">Sort by a column heading</span>
        </div>
        <GamesTable rows={d.rows} by="mac" sort={d.sort} base={`/setup/${d.setupKey}`} />
        <div class="card-foot">
          <span>FPS / W uses whole-Mac power, display included — compare on the same Mac.</span>
        </div>
      </section>
    </Layout>
  );
}

export async function loadSetups(env: Env) {
  return keysWithRuns(env, "setup_key");
}

export function SetupsPage(props: { setups: { key: string; label: string; runs: number; games: number }[] }) {
  return (
    <Layout title="Setups" section="setups" description="Every setup with runs published from Metal-PT.">
      <section class="stack">
        <h1>Setups</h1>
        <p class="muted">Native, or a Wine runtime by major version and graphics layer. Full versions show on each run.</p>
      </section>
      <section class="card clip">
        {props.setups.length === 0 ? (
          <p class="empty">No runs yet.</p>
        ) : (
          <ul class="list">
            {props.setups.map((s) => (
              <li>
                <a class="t" href={`/setup/${s.key}`}>{s.label}</a>
                <span class="muted">
                  {plural(s.runs, "run")} of {plural(s.games, "game")}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>
    </Layout>
  );
}
