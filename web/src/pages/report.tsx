// "Report a problem with this run" (spec §4.H): a reason and some words, behind Turnstile. A report stores only the
// run id, the reason, the (scrubbed) text and the time: nothing about the sender (spec §4.I). Never edge-cached.
import type { Deps } from "../deps.ts";
import { isoSeconds, RUN_ID } from "../db.ts";
import type { Env } from "../index.ts";
import { scrub } from "../lib/scrub.ts";
import { REPORT_ACTION, TURNSTILE_SCRIPT, turnstileMode, verifyTurnstile } from "../turnstile.ts";
import { macName } from "./format.ts";
import { Layout } from "./layout.tsx";

export const REPORT_REASONS = [
  ["wrong_game", "Wrong game"],
  ["wrong_settings", "Wrong settings"],
  ["impossible_numbers", "Impossible numbers"],
  ["bad_video_link", "Bad video link"],
  ["other", "Something else"],
] as const;
export type ReportReason = (typeof REPORT_REASONS)[number][0];

export const MAX_REPORT_TEXT = 1000;
/** Largest form body read. */
const MAX_FORM_BYTES = 16 * 1024;
/** Open reports kept per run; more are thanked and dropped (one run can't fill the queue or D1). */
const MAX_OPEN_REPORTS_PER_RUN = 50;

export function reasonLabel(code: string): string {
  return REPORT_REASONS.find(([c]) => c === code)?.[1] ?? code;
}

interface ReportRun {
  id: string;
  game_title: string;
  mac_key: string;
  chip: string | null;
  setup_label: string;
  has_video: number;
}

async function loadReportRun(env: Env, id: string): Promise<ReportRun | null> {
  if (!RUN_ID.test(id)) return null;
  return env.DB.prepare(
    `SELECT r.id AS id, g.title AS game_title, r.mac_key AS mac_key, r.chip AS chip, r.setup_label AS setup_label,
            (r.video_id IS NOT NULL) AS has_video
       FROM runs r JOIN games g ON g.id = r.game_id WHERE r.id = ? AND r.hidden = 0`,
  )
    .bind(id)
    .first<ReportRun>();
}

function runName(r: ReportRun): string {
  const chip = macName(r.mac_key).chip === "Unknown Mac" ? (r.chip ?? "Mac").replace(/^apple\s+/i, "") : macName(r.mac_key).chip;
  return `${r.game_title} · ${chip} · ${r.setup_label}`;
}

interface FormState {
  reason?: string;
  text?: string;
  error?: string;
}

function ReportPage(props: { run: ReportRun; siteKey: string | null; closed: boolean; state: FormState }) {
  const { run, state } = props;
  return (
    <Layout
      title="Report a problem"
      noindex
      head={props.siteKey ? <script src={TURNSTILE_SCRIPT} async defer></script> : undefined}
    >
      <section class="form">
        <p class="small">
          <a href={`/run/${run.id}`}>← Back to the run</a>
        </p>
        <h1>Report a problem with this run</h1>
        <p class="muted">{runName(run)}</p>
        {props.closed ? (
          <p class="notice bad">Reports can't be sent just now. Please try again later.</p>
        ) : (
          <form method="post" action={`/run/${run.id}/report`} class="form">
            {state.error ? <p class="notice bad" role="alert">{state.error}</p> : null}
            <fieldset class="field">
              <legend class="label">What's wrong?</legend>
              <div class="choices">
                {REPORT_REASONS.filter(([c]) => c !== "bad_video_link" || run.has_video || state.reason === c).map(([code, label]) => (
                  <label>
                    <input type="radio" name="reason" value={code} required checked={state.reason === code} />
                    <span>{label}</span>
                  </label>
                ))}
              </div>
            </fieldset>
            <label class="field">
              <span class="label">Tell us more</span>
              <textarea name="text" maxlength={MAX_REPORT_TEXT} placeholder="What looks wrong, and how you know (optional unless you chose Something else).">
                {state.text ?? ""}
              </textarea>
            </label>
            {props.siteKey ? <div class="cf-turnstile" data-sitekey={props.siteKey} data-action={REPORT_ACTION}></div> : null}
            <p class="small muted">
              The report keeps the run, the reason and your words, nothing about you. Don't include your name or email.
            </p>
            <div>
              <button class="btn primary" type="submit">
                Send report
              </button>
            </div>
          </form>
        )}
      </section>
    </Layout>
  );
}

function ThanksPage(props: { run: ReportRun }) {
  return (
    <Layout title="Report sent" noindex>
      <section class="form">
        <h1>Thanks — report sent</h1>
        <p>It will be looked at by hand. If the run is wrong it will be fixed or taken down.</p>
        <p>
          <a href={`/run/${props.run.id}`}>Back to the run</a>
        </p>
      </section>
    </Layout>
  );
}

async function page(node: { toString(): string | Promise<string> }, status = 200): Promise<Response> {
  return new Response("<!doctype html>" + (await node.toString()), {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "strict-origin-when-cross-origin",
    },
  });
}

/** Control characters other than tab and newline removed, CRLF folded, trimmed. */
function cleanText(s: string): string {
  return s.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "").trim();
}

export type NotFound = () => Promise<Response>;

/** GET /run/:id/report */
export async function reportForm(env: Env, id: string, notFound: NotFound): Promise<Response> {
  const run = await loadReportRun(env, id);
  if (run === null) return notFound();
  const mode = turnstileMode(env);
  if (mode.kind === "unconfigured") return page(<ReportPage run={run} siteKey={null} closed state={{}} />, 503);
  return page(<ReportPage run={run} siteKey={mode.kind === "on" ? mode.siteKey : null} closed={false} state={{}} />);
}

/** POST /run/:id/report */
export async function submitReport(req: Request, env: Env, deps: Deps, id: string, notFound: NotFound): Promise<Response> {
  const run = await loadReportRun(env, id);
  if (run === null) return notFound();
  const mode = turnstileMode(env);
  const siteKey = mode.kind === "on" ? mode.siteKey : null;
  if (mode.kind === "unconfigured") return page(<ReportPage run={run} siteKey={null} closed state={{}} />, 503);

  const again = (state: FormState, status = 400) => page(<ReportPage run={run} siteKey={siteKey} closed={false} state={state} />, status);
  const length = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_FORM_BYTES) return again({ error: "That report is too long." }, 413);
  let form: FormData;
  try {
    const raw = await req.arrayBuffer();
    if (raw.byteLength > MAX_FORM_BYTES) return again({ error: "That report is too long." }, 413);
    form = await new Response(raw, { headers: { "content-type": req.headers.get("content-type") ?? "" } }).formData();
  } catch {
    return again({ error: "The report could not be read. Please try again." });
  }
  const reason = String(form.get("reason") ?? "");
  const text = cleanText(String(form.get("text") ?? ""));
  const state: FormState = { reason, text };
  if (!REPORT_REASONS.some(([c]) => c === reason)) return again({ ...state, error: "Choose what's wrong with the run." });
  if (text.length > MAX_REPORT_TEXT) return again({ ...state, error: `Please keep it to ${MAX_REPORT_TEXT} characters.` });
  if (reason === "other" && text === "") return again({ ...state, error: "Say what's wrong in a few words." });

  if (mode.kind === "on") {
    const token = String(form.get("cf-turnstile-response") ?? "");
    if (!(await verifyTurnstile(token, mode.secret, new URL(req.url).hostname, deps.fetch))) {
      return again({ ...state, error: "The check that you're a person didn't pass. Please try again." });
    }
  }

  const open = await env.DB.prepare("SELECT count(*) AS n FROM reports WHERE run_id = ? AND resolved = 0")
    .bind(id)
    .first<{ n: number }>();
  if ((open?.n ?? 0) < MAX_OPEN_REPORTS_PER_RUN) {
    await env.DB.prepare("INSERT INTO reports (run_id, reason, text, created) VALUES (?, ?, ?, ?)")
      .bind(id, reason, text === "" ? null : scrub(text), isoSeconds(deps.now()))
      .run();
  }
  return page(<ThanksPage run={run} />);
}
