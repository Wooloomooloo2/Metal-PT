import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

// Spec §4.I: no IP addresses or user agents are stored anywhere.
describe("schema privacy", () => {
  it("no table has a column named like an IP address or user agent", async () => {
    const { results: tables } = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite%' AND name NOT LIKE '\\_%' ESCAPE '\\'",
    ).all<{ name: string }>();
    expect(tables.length).toBeGreaterThan(0);
    const forbidden = /(^|_)ip($|_)|ip_?addr|remote_?addr|user_?agent|(^|_)ua($|_)|cf_connecting|x_forwarded/i;
    for (const { name } of tables) {
      const { results: cols } = await env.DB.prepare(`SELECT name FROM pragma_table_info(?)`).bind(name).all<{
        name: string;
      }>();
      expect(cols.length).toBeGreaterThan(0);
      for (const c of cols) expect(c.name, `${name}.${c.name}`).not.toMatch(forbidden);
    }
  });

  it("the pattern would catch the obvious names", () => {
    const forbidden = /(^|_)ip($|_)|ip_?addr|remote_?addr|user_?agent|(^|_)ua($|_)|cf_connecting|x_forwarded/i;
    for (const bad of ["ip", "ip_address", "client_ip", "user_agent", "useragent", "ua", "ipaddr"]) {
      expect(bad).toMatch(forbidden);
    }
    for (const ok of ["key_id", "description", "zip_sha", "equipment", "updated"]) expect(ok).not.toMatch(forbidden);
  });
});
