// /run/:id (spec §4.F): header, settings chips, "Published from Metal-PT", tiles, FPS chart (server-built SVG from
// `fps_series`), power, notes, video card, Copy link, Compare with…, Download, Report a problem.
import type { Env } from "../index.ts";
import { fpsChart, parseSeries } from "./chart.ts";
import { notCountedReason, RUN_COLS, systemFPW, type RunRow } from "./data.ts";
import {
  date, DASH, duration, fps, fpw, frameGen, frameMs, macName, powerSourceLine, preset, resolution, setupShort,
  upscaler, watts,
} from "./format.ts";
import { Layout } from "./layout.tsx";

export interface RunDetail extends RunRow {
  memory_gb: number | null;
  model_id: string | null;
  os_version: string | null;
  runtime: string | null;
  runtime_version: string | null;
  graphics_layers: string | null;
  recorded_app: string | null;
  p1_low_fps: number | null;
  mean_system_w: number | null;
  limiter_verdict: string | null;
  steady_s: number | null;
  notes: string | null;
  settings_text: string | null;
  video_id: string | null;
  video_title: string | null;
  video_channel: string | null;
  fps_series: string | null;
  app_version: string | null;
}

export const DETAIL_COLS = `${RUN_COLS}, r.memory_gb, r.model_id, r.os_version, r.runtime, r.runtime_version,
  r.graphics_layers, r.recorded_app, r.p1_low_fps, r.mean_system_w, r.limiter_verdict, r.steady_s, r.notes,
  r.settings_text, r.video_id, r.video_title, r.video_channel, r.fps_series, r.app_version`;

/** A visible run with whether its group has uncapped eligible runs (for "frame-capped, not counted"). */
export async function loadRun(env: Env, id: string): Promise<{ run: RunDetail; uncapped: boolean } | null> {
  const run = await env.DB.prepare(
    `SELECT ${DETAIL_COLS} FROM runs r JOIN games g ON g.id = r.game_id WHERE r.id = ? AND r.hidden = 0`,
  )
    .bind(id)
    .first<RunDetail>();
  if (run === null) return null;
  let uncapped = false;
  if (run.limiter_primary === "frameCap") {
    const n = await env.DB.prepare(
      `SELECT count(*) AS n FROM runs WHERE group_key = ? AND hidden = 0 AND median_fps IS NOT NULL
          AND (on_ac IS NULL OR on_ac <> 0) AND (power_mode IS NULL OR power_mode <> 'low')
          AND (limiter_primary IS NULL OR limiter_primary <> 'frameCap')
          AND mac_key <> 'unknown' AND setup_key <> 'unknown'`,
    )
      .bind(run.group_key)
      .first<{ n: number }>();
    uncapped = (n?.n ?? 0) > 0;
  }
  return { run, uncapped };
}

/** "Cyberpunk 2077 · M4 Max · 49 fps · 0.39 FPS/W". */
export function runOGTitle(r: RunDetail): string {
  const parts = [r.game_title, macName(r.mac_key).chip === "Unknown Mac" ? (r.chip ?? "Mac").replace(/^apple\s+/i, "") : macName(r.mac_key).chip, `${fps(r.median_fps)} fps`];
  const w = systemFPW(r);
  if (w !== null) parts.push(`${fpw(w)} FPS/W`);
  return parts.join(" · ");
}

/** The runtime with its full version and graphics layers: "CrossOver 25.1 · D3DMetal". */
function fullSetup(r: RunDetail): string {
  if (r.runtime === null || r.runtime === "native") return r.setup_label;
  const head = r.runtime_version ? `${r.runtime} ${r.runtime_version}` : r.runtime;
  return r.graphics_layers ? `${head} · ${r.graphics_layers}` : head;
}

/** The YouTube watch URL, only from a stored 11-character id (never stored text otherwise). */
function watchURL(id: string): string | null {
  return /^[A-Za-z0-9_-]{11}$/.test(id) ? `https://www.youtube.com/watch?v=${id}` : null;
}

export function RunPage(props: { run: RunDetail; uncapped: boolean; url: string }) {
  const r = props.run;
  const mac = macName(r.mac_key);
  const chip = mac.chip === "Unknown Mac" && r.chip ? r.chip.replace(/^apple\s+/i, "") : mac.chip;
  const w = systemFPW(r);
  const why = notCountedReason(r, props.uncapped);
  const series = parseSeries(r.fps_series);
  const chart = series ? fpsChart(series, r.median_fps) : null;
  const length = chart?.endS ?? null;
  const sub = [
    r.gpu_cores ? `${r.gpu_cores}-core GPU` : null,
    r.memory_gb ? `${r.memory_gb} GB` : null,
    r.model_id,
    r.os_version ? `macOS ${r.os_version}` : null,
    r.runtime !== null && r.runtime !== "native" ? fullSetup(r) : r.recorded_app && r.setup_key.startsWith("native-via-") ? `via ${r.recorded_app}` : null,
    r.recorded ? `recorded ${date(r.recorded)}` : null,
    length !== null ? duration(length) : null,
  ].filter((x): x is string => x != null && x !== "");
  const video = r.video_id ? watchURL(r.video_id) : null;
  return (
    <Layout
      title={`${r.game_title} on ${chip}`}
      og={{
        title: runOGTitle(r),
        description: `${r.game_title} on ${chip} (${r.setup_label}), published from Metal-PT.`,
        url: props.url,
      }}
    >
      <section class="page-head top">
        <div class="stack gap8">
          <a href={`/game/${r.game_slug}`} class="small" style="font-weight:500">
            {r.game_title}
          </a>
          <h1 class="run">
            {chip} · {setupShort(r.setup_label)}
          </h1>
          {r.label ? <p class="strong">{r.label}</p> : null}
          <p class="muted" style="font-size:15px">{sub.join(" · ")}</p>
          <div class="chips" style="margin-top:4px">
            <span class="chip">{preset(r.preset)}</span>
            <span class="chip">{resolution(r.width, r.height)}</span>
            <span class="chip">{upscaler(r.upscaler, r.upscaler_mode)}</span>
            <span class="chip">{frameGen(r.frame_gen)}</span>
            <span class="chip ok">Published from Metal-PT</span>
            {why !== null ? <span class="chip warn">Not counted: {why}</span> : null}
          </div>
        </div>
        <div class="actions">
          <a class="btn" href={`/run/${r.id}`} data-copy>
            Copy link
          </a>
          <a class="btn primary" href={`/compare?runs=${r.id}`}>
            Compare with…
          </a>
        </div>
      </section>

      <section class="tiles" aria-label="Headline numbers">
        <div class="tile">
          <span class="k">Median FPS</span>
          <span class="v num">{fps(r.median_fps)}</span>
          <span class="d">
            {r.p1_low_fps !== null ? `1% low ${fps(r.p1_low_fps)} · ` : ""}steady {duration(r.steady_s)}
          </span>
        </div>
        <div class="tile power">
          <span class="k">FPS per watt</span>
          <span class="v num">{w !== null ? fpw(w) : DASH}</span>
          <span class="d">
            {w !== null
              ? `at ${watts(r.mean_system_w)} whole-Mac power`
              : r.power_source === "gpuOnly"
                ? "Only GPU power was measured, so FPS/W isn't shown"
                : "No power readings"}
          </span>
        </div>
        <div class="tile">
          <span class="k">Frame time</span>
          <span class="v num">{frameMs(r.median_fps)}</span>
          <span class="d">{r.p1_low_fps !== null ? `1% low ${frameMs(r.p1_low_fps)}` : "1% low not recorded"}</span>
        </div>
        <div class="tile">
          <span class="k">What held it back</span>
          <span class="w">{r.limiter_verdict ?? DASH}</span>
          <span class="d">Metal-PT's reading of the steady part of the run</span>
        </div>
      </section>

      {chart ? (
        <section class="card pad chart-card" aria-label="FPS over time">
          <div class="page-head" style="align-items:baseline;gap:8px">
            <h2>FPS over the run</h2>
            <span class="small muted">
              Shaded: warm-up, left out of the numbers · dashed: median · scale 0–{chart.yMax} fps
            </span>
          </div>
          {/* Built by chart.ts from numbers only (Review Focus 5). */}
          <div dangerouslySetInnerHTML={{ __html: chart.svg }}></div>
          <div class="ticks num" aria-hidden="true">
            {chart.ticks.map((t) => (
              <span style={`left:${t.at.toFixed(1)}%`}>{t.label}</span>
            ))}
          </div>
        </section>
      ) : null}

      <section class="details" aria-label="Details">
        <div class="card pad kv">
          <h3>Power and setup</h3>
          <div class="row"><span>Whole-Mac power</span><span class="num">{r.power_source === "system" ? watts(r.mean_system_w) : DASH}</span></div>
          <div class="row"><span>Power measured</span><span>{r.power_source === "system" ? "Whole Mac" : r.power_source === "gpuOnly" ? "GPU only" : "Not measured"}</span></div>
          <div class="row"><span>Power source</span><span>{powerSourceLine(r.on_ac, r.power_mode)}</span></div>
          <div class="row"><span>Setup</span><span>{fullSetup(r)}</span></div>
          {r.recorded_app ? <div class="row"><span>Recorded app</span><span>{r.recorded_app}</span></div> : null}
          {r.app_version ? <div class="row"><span>Metal-PT</span><span>{r.app_version}</span></div> : null}
          <div class="row"><span>Published</span><span>{date(r.published)}</span></div>
        </div>
        <div class="card pad kv">
          <h3>Notes from the tester</h3>
          {r.notes ? <p class="prose">{r.notes}</p> : <p class="muted">No notes.</p>}
          {r.settings_text ? (
            <>
              <h3 style="margin-top:6px">Game settings</h3>
              <p class="prose">{r.settings_text}</p>
            </>
          ) : null}
          <a class="small" href={`/run/${r.id}/download`} style="margin-top:auto">
            Download this run (.mptrun.zip)
          </a>
          <a class="small muted" href={`/run/${r.id}/report`}>
            Report a problem with this run
          </a>
        </div>
        {video ? (
          <div class="card pad">
            <a class="video" href={video} target="_blank" rel="nofollow ugc noopener">
              <span class="play" aria-hidden="true"></span>
              <span class="stack" style="gap:2px">
                <span class="strong">{r.video_title ?? "Video of this run"}</span>
                <span class="small muted">{r.video_channel ? `${r.video_channel} · YouTube` : "YouTube"}</span>
              </span>
            </a>
          </div>
        ) : null}
      </section>
    </Layout>
  );
}
