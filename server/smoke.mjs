#!/usr/bin/env node
// smoke.mjs — read-only checks against a running slappd.
//   node smoke.mjs [http://127.0.0.1:8123]
// Safe against the live daemon: GETs only, no sessions created, nothing mutated.
// Set SLAPP_TOKEN if the daemon is locked.
import test from "node:test";
import assert from "node:assert/strict";

const BASE = (process.argv[2] || process.env.SLAPP_URL || "http://127.0.0.1:8123").replace(/\/$/, "");
const TOKEN = process.env.SLAPP_TOKEN || "";
const HEADERS = TOKEN ? { "x-slapp-token": TOKEN } : {};
const get = (path) => fetch(BASE + path, { headers: HEADERS });

test("health answers ok", async () => {
  const r = await get("/api/health");
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.ok, true);
  assert.equal(typeof j.secured, "boolean");
  assert.ok(Array.isArray(j.sessions));
});

test("sessions listing is an array of sane shapes", async () => {
  const r = await get("/api/sessions");
  assert.equal(r.status, 200);
  const list = await r.json();
  assert.ok(Array.isArray(list));
  for (const s of list) {
    assert.ok(typeof s.slug === "string" && s.slug.length > 0);
    assert.ok("busy" in s && "phase" in s);
  }
});

test("unknown session 404s in human words", async () => {
  for (const p of ["/api/session/__nope__/log", "/api/session/__nope__/screen", "/api/session/__nope__/events"]) {
    const r = await get(p);
    assert.equal(r.status, 404);
  }
  const j = await (await get("/api/session/__nope__/log")).json();
  assert.ok(j.error && typeof j.error === "string");
});

test("unknown share card is 404", async () => {
  const r = await get("/s/__nope__");
  assert.equal(r.status, 404);
});

test("status page renders the brand", async () => {
  const r = await get("/");
  assert.equal(r.status, 200);
  assert.match(await r.text(), /slapp/);
});

test("token gate actually gates (when secured)", async () => {
  const { secured } = await (await get("/api/health")).json();
  if (!secured) return; // daemon is open — nothing to assert
  const r = await fetch(BASE + "/api/sessions"); // no token header
  assert.equal(r.status, 401);
});

test("cross-origin POSTs are refused", async () => {
  const r = await fetch(BASE + "/api/session/__nope__/prompt", {
    method: "POST",
    headers: { origin: "https://evil.example", "content-type": "text/plain" },
    body: "nope",
  });
  assert.equal(r.status, 403);
});
