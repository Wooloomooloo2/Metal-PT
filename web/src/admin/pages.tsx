// Admin pages (spec §4.H): the reports queue, a run, the games list and a game. Read-only views; every change is a
// POST form handled in routes.tsx. All text goes through JSX (escaped).
import type { Child } from "hono/jsx";
import type { Env } from "../index.ts";
import { date, fps, macTitle } from "../pages/format.ts";
import { Layout } from "../pages/layout.tsx";
import { reasonLabel } from "../pages/report.tsx";

// MARK: - Frame

export function AdminLayout(props: { title: string; who: string | null; notice?: string | null; error?: string | null; children?: Child }) {
  return (
    <Layout title={`Admin · ${props.title}`} noindex fonts={false}>
      <section class="stack" style="gap:18px">
        <nav class="admin-actions small" aria-label="Admin">
          <strong>Admin</strong>
          <a href="/admin">Reports</a>
          <a href="/admin/games">Games</a>
          <form method="get" action="/admin/run">
            <label class="sr" for="find-run">Run id or URL</label>
            <input id="find-run" type="text" name="id" placeholder="Run id or URL" />
            <button class="btn small" type="submit">Open run</button>
          </form>
          {props.who ? <span class="muted">Signed in as {props.who}</span> : null}
        </nav>
        {props.notice ? <p class="notice" role="status">{props.notice}</p> : null}
        {props.error ? <p class="notice bad" role="alert">{props.error}</p> : null}
        {props.children}
      </section>
    </Layout>
  );
}

/** A one-button POST form. `back` is where the action returns to. */
export function Action(props: { action: string; label: string; back?: string; danger?: boolean; fields?: Record<string, string> }) {
  return (
    <form method="post" action={props.action}>
      {props.back ? <input type="hidden" name="back" value={props.back} /> : null}
      {Object.entries(props.fields ?? {}).map(([k, v]) => (
        <input type="hidden" name={k} value={v} />
      ))}
      <button class="btn small" type="submit" style={props.danger ? "color:#8A1C0A" : undefined}>
        {props.label}
      </button>
    </form>
  );
}

// MARK: - Reports queue

interface QueueRow {
  id: number;
  run_id: string;
  reason: string;
  text: string | null;
  created: string;
  resolved: number;
  game_title: string | null;
  mac_key: string | null;
  setup_label: string | null;
  median_fps: number | null;
  hidden: number | null;
  video_id: string | null;
  banned: number | null;
}

export interface QueueData {
  rows: QueueRow[];
  open: number;
  resolved: number;
  showResolved: boolean;
}

export async function loadQueue(env: Env, showResolved: boolean): Promise<QueueData> {
  const { results } = await env.DB.prepare(
    `SELECT rp.id AS id, rp.run_id AS run_id, rp.reason AS reason, rp.text AS text, rp.created AS created,
            rp.resolved AS resolved, g.title AS game_title, r.mac_key AS mac_key, r.setup_label AS setup_label,
            r.median_fps AS median_fps, r.hidden AS hidden, r.video_id AS video_id, m.banned AS banned
       FROM reports rp LEFT JOIN runs r ON r.id = rp.run_id LEFT JOIN games g ON g.id = r.game_id
       LEFT JOIN macs m ON m.key_id = r.key_id
      WHERE rp.resolved = ? ORDER BY rp.created DESC, rp.id DESC LIMIT 200`,
  )
    .bind(showResolved ? 1 : 0)
    .all<QueueRow>();
  const counts = await env.DB.prepare(
    "SELECT sum(resolved = 0) AS open, sum(resolved = 1) AS resolved FROM reports",
  ).first<{ open: number | null; resolved: number | null }>();
  return { rows: results, open: counts?.open ?? 0, resolved: counts?.resolved ?? 0, showResolved };
}

export function QueuePage(props: { d: QueueData; who: string | null; notice?: string | null }) {
  const { d } = props;
  const back = d.showResolved ? "/admin?show=resolved" : "/admin";
  return (
    <AdminLayout title="Reports" who={props.who} notice={props.notice}>
      <h1>{d.showResolved ? "Resolved reports" : "Open reports"}</h1>
      <p class="muted">
        {d.open} open · {d.resolved} resolved ·{" "}
        {d.showResolved ? <a href="/admin">Show open</a> : <a href="/admin?show=resolved">Show resolved</a>}
      </p>
      {d.rows.length === 0 ? (
        <p class="card pad muted">{d.showResolved ? "No resolved reports." : "No open reports."}</p>
      ) : (
        <ul class="list card">
          {d.rows.map((r) => (
            <li>
              <div class="stack" style="gap:4px;flex:1 1 320px;min-width:0">
                <span class="t">
                  {reasonLabel(r.reason)} · <a href={`/admin/run/${r.run_id}`}>{r.game_title ?? "(run removed)"}</a>
                </span>
                <span class="small muted">
                  {r.mac_key ? macTitle(r.mac_key) : ""} {r.setup_label ? `· ${r.setup_label}` : ""}{" "}
                  {r.median_fps !== null ? `· ${fps(r.median_fps)} fps` : ""} · reported {date(r.created)}
                  {r.hidden ? " · hidden" : ""}
                  {r.banned ? " · key banned" : ""}
                </span>
                {r.text ? <p class="prose" style="margin:0">{r.text}</p> : null}
              </div>
              <div class="admin-actions">
                {r.resolved ? (
                  <Action action={`/admin/report/${r.id}/reopen`} label="Reopen" back={back} />
                ) : (
                  <Action action={`/admin/report/${r.id}/resolve`} label="Resolve" back={back} />
                )}
                {r.hidden === 0 ? <Action action={`/admin/run/${r.run_id}/hide`} label="Hide run" back={back} /> : null}
                {r.video_id ? <Action action={`/admin/run/${r.run_id}/remove-video`} label="Remove video link" back={back} /> : null}
              </div>
            </li>
          ))}
        </ul>
      )}
    </AdminLayout>
  );
}

// MARK: - Run

interface AdminRun {
  id: string;
  game_id: number;
  game_title: string;
  game_slug: string;
  key_id: string;
  banned: number;
  key_runs: number;
  published: string;
  chip: string | null;
  mac_key: string;
  setup_label: string;
  preset: string | null;
  width: number | null;
  height: number | null;
  median_fps: number | null;
  fps_per_watt: number | null;
  label: string | null;
  notes: string | null;
  settings_text: string | null;
  video_id: string | null;
  video_title: string | null;
  video_channel: string | null;
  video_locked: number;
  hidden: number;
  outlier: number;
}

interface RunReport {
  id: number;
  reason: string;
  text: string | null;
  created: string;
  resolved: number;
}

export interface RunData {
  run: AdminRun;
  reports: RunReport[];
}

export async function loadAdminRun(env: Env, id: string): Promise<RunData | null> {
  const run = await env.DB.prepare(
    `SELECT r.id AS id, r.game_id AS game_id, g.title AS game_title, g.slug AS game_slug, r.key_id AS key_id,
            m.banned AS banned, (SELECT count(*) FROM runs k WHERE k.key_id = r.key_id) AS key_runs,
            r.published AS published, r.chip AS chip, r.mac_key AS mac_key, r.setup_label AS setup_label,
            r.preset AS preset, r.width AS width, r.height AS height, r.median_fps AS median_fps,
            r.fps_per_watt AS fps_per_watt, r.label AS label, r.notes AS notes, r.settings_text AS settings_text,
            r.video_id AS video_id, r.video_title AS video_title, r.video_channel AS video_channel,
            r.video_locked AS video_locked, r.hidden AS hidden, r.outlier AS outlier
       FROM runs r JOIN games g ON g.id = r.game_id JOIN macs m ON m.key_id = r.key_id WHERE r.id = ?`,
  )
    .bind(id)
    .first<AdminRun>();
  if (run === null) return null;
  const { results } = await env.DB.prepare(
    "SELECT id, reason, text, created, resolved FROM reports WHERE run_id = ? ORDER BY created DESC, id DESC LIMIT 100",
  )
    .bind(id)
    .all<RunReport>();
  return { run, reports: results };
}

function Row(props: { k: string; children?: Child }) {
  return (
    <div class="row">
      <span>{props.k}</span>
      <span>{props.children}</span>
    </div>
  );
}

export function AdminRunPage(props: { d: RunData; who: string | null; notice?: string | null }) {
  const r = props.d.run;
  const back = `/admin/run/${r.id}`;
  return (
    <AdminLayout title={`Run ${r.id}`} who={props.who} notice={props.notice}>
      <h1>
        {r.game_title} · {macTitle(r.mac_key)}
      </h1>
      <p class="muted">
        {r.setup_label} · {r.preset ?? "—"} · {r.width ?? "?"}×{r.height ?? "?"} · {fps(r.median_fps)} fps · published{" "}
        {date(r.published)}
        {r.hidden ? " · HIDDEN" : ""}
        {r.outlier ? " · outlier" : ""}
      </p>
      <div class="admin-actions">
        {r.hidden ? (
          <a href={`/run/${r.id}`} class="muted small">Public page (hidden: 404)</a>
        ) : (
          <a href={`/run/${r.id}`}>Public page</a>
        )}
        <a href={`/admin/game/${r.game_id}`}>Game: {r.game_title}</a>
      </div>

      <div class="card pad kv">
        <h3>Run</h3>
        <Row k="Label">{r.label ?? "—"}</Row>
        <Row k="Chip">{r.chip ?? "—"}</Row>
        <Row k="Video">
          {r.video_id ? `${r.video_title ?? r.video_id} (${r.video_channel ?? "?"}) · youtu.be/${r.video_id}` : "none"}
          {r.video_locked ? " · locked by a moderator" : ""}
        </Row>
        <Row k="Key">
          <span class="mono">{r.key_id}</span> · {r.key_runs} run{r.key_runs === 1 ? "" : "s"}
          {r.banned ? " · BANNED" : ""}
        </Row>
        {r.notes ? <p class="prose">{r.notes}</p> : null}
        {r.settings_text ? <p class="prose">{r.settings_text}</p> : null}
      </div>

      <div class="admin-actions">
        {r.hidden ? (
          <Action action={`/admin/run/${r.id}/unhide`} label="Unhide run" back={back} />
        ) : (
          <Action action={`/admin/run/${r.id}/hide`} label="Hide run" back={back} />
        )}
        {r.video_id ? <Action action={`/admin/run/${r.id}/remove-video`} label="Remove video link" back={back} /> : null}
        {r.video_locked ? <Action action={`/admin/run/${r.id}/unlock-video`} label="Let the owner add a video again" back={back} /> : null}
        <Action action="/admin/recompute" label="Recompute this key's statistics" back={back} fields={{ scope: "key", key_id: r.key_id }} />
        {props.d.reports.some((x) => !x.resolved) ? (
          <Action action={`/admin/run/${r.id}/resolve-reports`} label="Resolve all its reports" back={back} />
        ) : null}
        {r.banned ? (
          <>
            <Action action="/admin/key/unban" label="Unban key and show its runs" back={back} fields={{ key_id: r.key_id, unhide: "1" }} />
            <Action action="/admin/key/unban" label="Unban key (runs stay hidden)" back={back} fields={{ key_id: r.key_id }} />
          </>
        ) : (
          <Action action="/admin/key/ban" label={`Ban key and hide its ${r.key_runs} run${r.key_runs === 1 ? "" : "s"}`} back={back} fields={{ key_id: r.key_id }} danger />
        )}
      </div>

      <h2>Reports on this run</h2>
      {props.d.reports.length === 0 ? (
        <p class="muted">None.</p>
      ) : (
        <ul class="list card">
          {props.d.reports.map((p) => (
            <li>
              <div class="stack" style="gap:4px;flex:1 1 320px;min-width:0">
                <span class="t">
                  {reasonLabel(p.reason)} · {date(p.created)} {p.resolved ? "· resolved" : ""}
                </span>
                {p.text ? <p class="prose" style="margin:0">{p.text}</p> : null}
              </div>
              <div class="admin-actions">
                {p.resolved ? (
                  <Action action={`/admin/report/${p.id}/reopen`} label="Reopen" back={back} />
                ) : (
                  <Action action={`/admin/report/${p.id}/resolve`} label="Resolve" back={back} />
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
    </AdminLayout>
  );
}

// MARK: - Games

interface GameListRow {
  id: number;
  slug: string;
  title: string;
  steam_id: string | null;
  runs: number;
  aliases: number;
}

export async function loadGames(env: Env, q: string): Promise<GameListRow[]> {
  const cols = `g.id AS id, g.slug AS slug, g.title AS title, g.steam_id AS steam_id,
                (SELECT count(*) FROM runs r WHERE r.game_id = g.id) AS runs,
                (SELECT count(*) FROM game_aliases a WHERE a.game_id = g.id) AS aliases`;
  const term = q.trim();
  if (term === "") {
    return (await env.DB.prepare(`SELECT ${cols} FROM games g ORDER BY g.title COLLATE NOCASE LIMIT 300`).all<GameListRow>()).results;
  }
  const like = `%${term.replace(/[\\%_]/g, "\\$&")}%`;
  return (
    await env.DB.prepare(
      `SELECT ${cols} FROM games g
        WHERE g.title LIKE ?1 ESCAPE '\\' OR g.slug LIKE ?1 ESCAPE '\\' OR g.steam_id = ?2
           OR g.id IN (SELECT game_id FROM game_aliases WHERE alias_norm LIKE ?1 ESCAPE '\\')
        ORDER BY g.title COLLATE NOCASE LIMIT 300`,
    )
      .bind(like, term)
      .all<GameListRow>()
  ).results;
}

export function GamesPage(props: { games: GameListRow[]; q: string; who: string | null }) {
  return (
    <AdminLayout title="Games" who={props.who}>
      <h1>Games</h1>
      <div class="admin-actions">
        <Action action="/admin/recompute" label="Recompute all statistics" back="/admin/games" fields={{ scope: "all" }} />
      </div>
      <form method="get" action="/admin/games" class="admin-actions">
        <label class="sr" for="gq">Find a game</label>
        <input id="gq" type="text" name="q" value={props.q} placeholder="Title, alias, slug or Steam ID" />
        <button class="btn small" type="submit">Find</button>
      </form>
      <div class="table-box card">
        <table class="data">
          <thead>
            <tr>
              <th>Game</th>
              <th>Address</th>
              <th>Steam</th>
              <th class="num">Runs</th>
              <th class="num">Names</th>
            </tr>
          </thead>
          <tbody>
            {props.games.map((g) => (
              <tr>
                <td>
                  <a href={`/admin/game/${g.id}`}>{g.title}</a>
                </td>
                <td class="mono">{g.slug}</td>
                <td class="mono">{g.steam_id ?? "—"}</td>
                <td class="num">{g.runs}</td>
                <td class="num">{g.aliases}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </AdminLayout>
  );
}

export interface GameData {
  game: { id: number; slug: string; title: string; steam_id: string | null; created: string };
  aliases: string[];
  runs: number;
  hidden: number;
  groups: number;
}

export async function loadAdminGame(env: Env, id: number): Promise<GameData | null> {
  const game = await env.DB.prepare("SELECT id, slug, title, steam_id, created FROM games WHERE id = ?")
    .bind(id)
    .first<GameData["game"]>();
  if (game === null) return null;
  const aliases = await env.DB.prepare("SELECT alias_norm FROM game_aliases WHERE game_id = ? ORDER BY alias_norm")
    .bind(id)
    .all<{ alias_norm: string }>();
  const n = await env.DB.prepare(
    `SELECT count(*) AS runs, coalesce(sum(hidden), 0) AS hidden,
            (SELECT count(*) FROM "groups" WHERE game_id = ?1) AS groups
       FROM runs WHERE game_id = ?1`,
  )
    .bind(id)
    .first<{ runs: number; hidden: number; groups: number }>();
  return { game, aliases: aliases.results.map((a) => a.alias_norm), runs: n?.runs ?? 0, hidden: n?.hidden ?? 0, groups: n?.groups ?? 0 };
}

export function AdminGamePage(props: { d: GameData; who: string | null; notice?: string | null }) {
  const { game: g } = props.d;
  const back = `/admin/game/${g.id}`;
  return (
    <AdminLayout title={g.title} who={props.who} notice={props.notice}>
      <h1>{g.title}</h1>
      <p class="muted">
        <a href={`/game/${g.slug}`}>/game/{g.slug}</a> · {props.d.runs} runs ({props.d.hidden} hidden) · {props.d.groups}{" "}
        counted groups · id {g.id}
      </p>
      <div class="admin-actions">
        <Action action="/admin/recompute" label="Recompute statistics" back={back} fields={{ scope: "game", id: String(g.id) }} />
      </div>

      <div class="card pad form">
        <h3>Rename</h3>
        <form method="post" action={`/admin/game/${g.id}/rename`} class="form">
          <label class="field">
            <span class="label">Title</span>
            <input type="text" name="title" value={g.title} maxlength={200} required />
          </label>
          <label class="field">
            <span class="label">Address (/game/…)</span>
            <input type="text" name="slug" value={g.slug} maxlength={121} />
          </label>
          <div>
            <button class="btn small" type="submit">Save</button>
          </div>
        </form>
      </div>

      <div class="card pad form">
        <h3>Steam app ID</h3>
        <p class="small muted">Learned from uploads (unchecked). Clear it if it's wrong; leave empty for none.</p>
        <form method="post" action={`/admin/game/${g.id}/steam`} class="admin-actions">
          <input type="text" name="steam_id" value={g.steam_id ?? ""} placeholder="e.g. 1091520" />
          <button class="btn small" type="submit">Save</button>
        </form>
      </div>

      <div class="card pad form">
        <h3>Names that match this game</h3>
        <p class="small muted">Uploads with one of these titles (normalised) join this game. Many are learned from uploads.</p>
        <ul class="list">
          {props.d.aliases.map((a) => (
            <li>
              <span class="mono">{a}</span>
              <Action action={`/admin/game/${g.id}/alias/remove`} label="Remove" back={back} fields={{ alias: a }} />
            </li>
          ))}
        </ul>
        <form method="post" action={`/admin/game/${g.id}/alias/add`} class="admin-actions">
          <input type="text" name="alias" placeholder="Another title" maxlength={200} />
          <button class="btn small" type="submit">Add name</button>
        </form>
      </div>

      <div class="card pad form">
        <h3>Merge into another game</h3>
        <p class="small muted">
          Moves this game's runs, names and (if the other has none) Steam ID to the other game, then deletes this game.
          /game/{g.slug} stops working.
        </p>
        <form method="post" action={`/admin/game/${g.id}/merge`} class="admin-actions">
          <input type="text" name="target" placeholder="Other game's id, address or URL" required />
          <label class="small">
            <input type="checkbox" name="confirm" value="1" required /> I'm sure
          </label>
          <button class="btn small" type="submit">Merge</button>
        </form>
      </div>
    </AdminLayout>
  );
}

export function AdminErrorPage(props: { message: string; back: string; who: string | null }) {
  return (
    <AdminLayout title="Not done" who={props.who} error={props.message}>
      <p>
        <a href={props.back}>Back</a>
      </p>
    </AdminLayout>
  );
}

export function RecomputePage(props: {
  who: string | null;
  done: number;
  left: number;
  last: string | null;
  fields: Record<string, string>;
  back: string;
}) {
  return (
    <AdminLayout title="Recompute statistics" who={props.who}>
      <h1>Recompute statistics</h1>
      <p class="notice" role="status">
        {props.done} group{props.done === 1 ? "" : "s"} recomputed.
        {props.left > 0 ? ` ${props.left} group${props.left === 1 ? "" : "s"} left — run again.` : " All done."}
      </p>
      {props.left > 0 && props.last !== null ? (
        <div class="admin-actions">
          <Action action="/admin/recompute" label="Run again" back={props.back} fields={{ ...props.fields, after: props.last }} />
        </div>
      ) : null}
      <p>
        <a href={props.back}>Back</a>
      </p>
    </AdminLayout>
  );
}
