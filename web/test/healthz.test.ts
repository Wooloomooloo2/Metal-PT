import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("scaffold", () => {
  it("GET /healthz answers 200 ok", async () => {
    const res = await SELF.fetch("https://example.com/healthz");
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });

  it("applies the migrations to the local D1", async () => {
    const { results } = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_%' ESCAPE '\\' AND name NOT LIKE 'sqlite%' AND name <> 'd1_migrations' ORDER BY name",
    ).all<{ name: string }>();
    expect(results.map((r) => r.name)).toEqual(["game_aliases", "games", "groups", "macs", "reports", "runs"]);

    const { results: idx } = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'runs' AND name LIKE 'runs\\_%' ESCAPE '\\' ORDER BY name",
    ).all<{ name: string }>();
    expect(idx.map((r) => r.name)).toEqual([
      "runs_game_id",
      "runs_group_key",
      "runs_key_id",
      "runs_mac_key",
      "runs_published",
      "runs_setup_key",
    ]);
  });

  it("rejects the same bundle twice", async () => {
    const insert = (id: string) =>
      env.DB.prepare(
        "INSERT INTO runs (id, game_id, key_id, bundle_sha256, published, mac_key, setup_key, setup_label, group_key) VALUES (?, 1, 'k', 'abc', '2026-11-25T00:00:00Z', 'unknown', 'unknown', 'Unknown', 'g')",
      )
        .bind(id)
        .run();
    await env.DB.prepare("INSERT INTO macs (key_id, public_key, first_seen) VALUES ('k', 'pk', '2026-11-25T00:00:00Z')").run();
    await env.DB.prepare("INSERT INTO games (id, slug, title, created) VALUES (1, 'g', 'G', '2026-11-25T00:00:00Z')").run();
    await insert("a");
    await expect(insert("b")).rejects.toThrow(/UNIQUE/);
  });

  it("binds the local R2 bucket", async () => {
    await env.RUNS.put("runs/x.zip", "z");
    expect(await (await env.RUNS.get("runs/x.zip"))?.text()).toBe("z");
  });
});
