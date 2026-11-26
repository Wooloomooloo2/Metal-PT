// / (spec §4.F): search, counts (runs, games, Macs), most-tested games, recently published runs.
import type { Env } from "../index.ts";
import { recentRuns, type RunRow } from "./data.ts";
import { plural } from "./format.ts";
import { Layout } from "./layout.tsx";
import { RunCard } from "./parts.tsx";

export interface GameCount {
  slug: string;
  title: string;
  runs: number;
  macs: number;
}

export interface HomeData {
  counts: { runs: number; games: number; macs: number };
  top: GameCount[];
  recent: RunRow[];
}

export async function loadHome(env: Env): Promise<HomeData> {
  const [counts, top, recent] = await Promise.all([
    env.DB.prepare(
      "SELECT count(*) AS runs, count(DISTINCT game_id) AS games, count(DISTINCT key_id) AS macs FROM runs WHERE hidden = 0",
    ).first<{ runs: number; games: number; macs: number }>(),
    env.DB.prepare(
      `SELECT g.slug, g.title, count(*) AS runs, count(DISTINCT r.mac_key) AS macs
         FROM runs r JOIN games g ON g.id = r.game_id WHERE r.hidden = 0
        GROUP BY g.id ORDER BY runs DESC, g.title LIMIT 12`,
    ).all<GameCount>(),
    recentRuns(env, 9),
  ]);
  return { counts: counts ?? { runs: 0, games: 0, macs: 0 }, top: top.results, recent };
}

export function HomePage(props: { d: HomeData }) {
  const d = props.d;
  return (
    <Layout title="" section="games" description="How games run on Apple Silicon Macs: frame rates and frames per watt, published from Metal-PT.">
      <section class="stack" style="gap:12px">
        <h1>How games run on Apple Silicon</h1>
        <p class="muted" style="font-size:17px;max-width:720px">
          Frame rates and frames per watt measured with Metal-PT on real Macs, one Mac counted once per settings.
        </p>
        <form action="/search" method="get" role="search" class="actions" style="max-width:520px">
          <label class="sr" for="home-q">Search games</label>
          <input id="home-q" type="search" name="q" placeholder="Search games…" style="max-width:none;flex:1 1 220px;background:#FFFFFF" />
          <button class="btn small primary" type="submit">Search</button>
        </form>
      </section>

      <section class="counts" aria-label="Counts">
        <div class="tile count"><span class="k">Runs</span><span class="v num">{d.counts.runs}</span></div>
        <div class="tile count"><span class="k">Games</span><span class="v num">{d.counts.games}</span></div>
        <div class="tile count"><span class="k">Macs</span><span class="v num">{d.counts.macs}</span></div>
      </section>

      <section class="card clip" aria-label="Most-tested games">
        <div class="card-head"><h2>Most-tested games</h2></div>
        {d.top.length === 0 ? (
          <p class="empty">No runs yet. Publish one from the Metal-PT app.</p>
        ) : (
          <ul class="list">
            {d.top.map((g) => (
              <li>
                <a class="t" href={`/game/${g.slug}`}>{g.title}</a>
                <span class="muted">{plural(g.runs, "run")} · {plural(g.macs, "Mac model")}</span>
              </li>
            ))}
          </ul>
        )}
      </section>

      {d.recent.length > 0 ? (
        <section class="stack" style="gap:12px" aria-label="Recently published">
          <h2>Recently published</h2>
          <div class="cards">
            {d.recent.map((r) => (
              <RunCard run={r} showGame />
            ))}
          </div>
        </section>
      ) : null}
    </Layout>
  );
}
