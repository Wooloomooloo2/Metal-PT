// /search?q= (spec §4.F): games by title or alias (normalised as the API matches them).
import type { Env } from "../index.ts";
import { normalizeTitle } from "../lib/games.ts";
import { plural } from "./format.ts";
import { Layout } from "./layout.tsx";
import type { GameCount } from "./home.tsx";

export interface SearchData {
  q: string;
  games: GameCount[];
}

export async function loadSearch(env: Env, rawQ: string): Promise<SearchData> {
  const q = rawQ.trim().slice(0, 100);
  const norm = normalizeTitle(q);
  if (norm === "") return { q, games: [] };
  const like = `%${norm.replace(/[\\%_]/g, "\\$&")}%`;
  const { results } = await env.DB.prepare(
    `SELECT g.slug, g.title,
            (SELECT count(*) FROM runs r WHERE r.game_id = g.id AND r.hidden = 0) AS runs,
            (SELECT count(DISTINCT r.mac_key) FROM runs r WHERE r.game_id = g.id AND r.hidden = 0) AS macs
       FROM games g
      WHERE g.id IN (SELECT game_id FROM game_aliases WHERE alias_norm LIKE ?1 ESCAPE '\\')
         OR lower(g.title) LIKE ?1 ESCAPE '\\'
      ORDER BY runs DESC, g.title LIMIT 50`,
  )
    .bind(like)
    .all<GameCount>();
  return { q, games: results.filter((g) => g.runs > 0) };
}

export function SearchPage(props: { d: SearchData }) {
  const d = props.d;
  return (
    <Layout title={d.q ? `Search: ${d.q}` : "Search"} section="games" query={d.q}>
      <section class="stack">
        <h1>{d.q ? `Games matching “${d.q}”` : "Search games"}</h1>
        <p class="muted">{d.q ? plural(d.games.length, "game") : "Type a game's name in the search box."}</p>
      </section>
      {d.q ? (
        <section class="card clip">
          {d.games.length === 0 ? (
            <p class="empty">No games with runs match. Titles are matched without punctuation or ® ™.</p>
          ) : (
            <ul class="list">
              {d.games.map((g) => (
                <li>
                  <a class="t" href={`/game/${g.slug}`}>{g.title}</a>
                  <span class="muted">{plural(g.runs, "run")} · {plural(g.macs, "Mac model")}</span>
                </li>
              ))}
            </ul>
          )}
        </section>
      ) : null}
    </Layout>
  );
}
