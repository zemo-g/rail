/**
 * Ledatic Worker — ledatic.org (public site) + reports.ledatic.org (client portal)
 *
 * Design:
 *   - ledatic.org: hybrid allow/deny. Internal KV keys (client:*, reports:*,
 *     session:*, entropy:* internals, snapshot, devlog, intakes, dead-page
 *     orphans) are denied at the Worker level. Everything else is served
 *     directly from KV with extension-based MIME + cache policy, so new
 *     pages (mission control, plasma landing, future tools) ship without
 *     Worker edits.
 *   - reports.ledatic.org: authed client portal, KV-backed client/session
 *     records, R2-backed PDF downloads.
 *   - Every response carries the strict-CSP security header stack.
 *
 * Bindings:
 *   LEDATIC_KV  — KV namespace (site content + client/report/session records)
 *   REPORTS_R2  — R2 bucket `ledatic-reports` (PDF storage)
 *
 * Source of truth: tools/deploy/worker.js in the rail repo. Deploy via
 *   tools/deploy/deploy_worker.sh
 */

// ─── Security ────────────────────────────────────────────────────────────────

const CSP = [
  "default-src 'self'",
  "script-src 'self' 'wasm-unsafe-eval' https://static.cloudflareinsights.com",
  "style-src 'self'",
  "img-src 'self' data: https://pub-e9d7c87d3a1b43bea50d3bd0d8ba9ffb.r2.dev",
  "font-src 'self'",
  "connect-src 'self' https://cloudflareinsights.com",
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "object-src 'none'",
  "upgrade-insecure-requests",
].join("; ");

const SECURITY_HEADERS = {
  "strict-transport-security": "max-age=31536000; includeSubDomains; preload",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
  "referrer-policy": "strict-origin-when-cross-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=(), interest-cohort=()",
  "content-security-policy": CSP,
};

function sec(headers) {
  return { ...SECURITY_HEADERS, ...headers };
}

// ─── Deny list ───────────────────────────────────────────────────────────────

// Any KV key whose raw value must never be exposed via a public URL.
// Colon-namespaced keys (client:*, reports:*, session:*, entropy:* internals)
// are denied by pattern. Everything else is enumerated.
const DENY_EXACT = new Set([
  // Internal data with no dedicated /data/ handler
  "intakes",
  "snapshot",          // served via /data/snapshot.json
  "devlog",            // served via /data/devlog.json
  "_test_ping",
  // Dead-page orphans from older site incarnations
  "agent.html",
  "demo.html",
  "pipeline.html",
  "tls",
  "tls/main.css",
  "playground",
  "assets/app.js",
  "assets/index-De4AavCV.js",
  "css/style.css",
  "js/main.js",
]);

function isPrivateKey(key) {
  return key.includes(":") || DENY_EXACT.has(key);
}

// ─── MIME + cache ────────────────────────────────────────────────────────────

const MIME = {
  html: "text/html; charset=utf-8",
  htm:  "text/html; charset=utf-8",
  css:  "text/css; charset=utf-8",
  js:   "application/javascript; charset=utf-8",
  mjs:  "application/javascript; charset=utf-8",
  json: "application/json; charset=utf-8",
  xml:  "application/xml; charset=utf-8",
  txt:  "text/plain; charset=utf-8",
  svg:  "image/svg+xml",
  png:  "image/png",
  jpg:  "image/jpeg",
  jpeg: "image/jpeg",
  gif:  "image/gif",
  webp: "image/webp",
  ico:  "image/x-icon",
  woff: "font/woff",
  woff2:"font/woff2",
  ttf:  "font/ttf",
  wasm: "application/wasm",
};

const BINARY_EXT = new Set([
  "png", "jpg", "jpeg", "gif", "webp", "ico",
  "woff", "woff2", "ttf",
  "wasm",
]);

const LONG_CACHE_EXT = new Set([
  "css", "js", "mjs", "json", "xml", "txt", "svg",
  "woff", "woff2", "ttf",
  "png", "jpg", "jpeg", "gif", "webp", "ico",
  "wasm",
]);

function extOf(key) {
  const slash = key.lastIndexOf("/");
  const dot = key.lastIndexOf(".");
  if (dot < 0 || dot < slash) return "";
  return key.slice(dot + 1).toLowerCase();
}

function notFound() {
  return new Response("Not Found", {
    status: 404,
    headers: sec({
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "public, max-age=60",
    }),
  });
}

async function serveFromKV(key, env) {
  const ext = extOf(key);
  const isBin = BINARY_EXT.has(ext);
  const val = isBin
    ? await env.LEDATIC_KV.get(key, "arrayBuffer")
    : await env.LEDATIC_KV.get(key);
  if (val === null || val === undefined) return null;
  const mime = MIME[ext] || MIME.html;
  const cache = LONG_CACHE_EXT.has(ext)
    ? "public, max-age=3600, s-maxage=3600"
    : "public, max-age=300, s-maxage=300";
  return new Response(val, {
    headers: sec({
      "content-type": mime,
      "cache-control": cache,
    }),
  });
}

// ─── reports.ledatic.org helpers ─────────────────────────────────────────────

const SESSION_TTL = 86400 * 30; // 30 days

async function hashPassword(password) {
  const data = new TextEncoder().encode(password);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, "0")).join("");
}

async function createSession(clientId, env) {
  const token = crypto.randomUUID();
  await env.LEDATIC_KV.put(`session:${token}`, clientId, { expirationTtl: SESSION_TTL });
  return token;
}

async function getSession(request, env) {
  const cookie = request.headers.get("Cookie") || "";
  const match = cookie.match(/lr_session=([^;]+)/);
  if (!match) return null;
  return await env.LEDATIC_KV.get(`session:${match[1]}`);
}

function setCookie(token, host) {
  const secure = host.includes("ledatic.org") ? "; Secure" : "";
  return `lr_session=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${SESSION_TTL}${secure}`;
}

function clearCookie(host) {
  const secure = host.includes("ledatic.org") ? "; Secure" : "";
  return `lr_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0${secure}`;
}

async function getClient(clientId, env) {
  return await env.LEDATIC_KV.get(`client:${clientId}`, { type: "json" });
}

async function getClientReports(clientId, env) {
  return (await env.LEDATIC_KV.get(`reports:${clientId}`, { type: "json" })) || [];
}

function loginPage(error) {
  return `<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Ledatic Reports</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { background: #0a0a0a; color: #e2e8f0; font-family: 'Courier New', monospace;
    min-height: 100vh; display: flex; align-items: center; justify-content: center; }
  .login { width: 100%; max-width: 380px; padding: 24px; }
  .brand { color: #33ff33; font-size: 1.4em; font-weight: bold; letter-spacing: 2px;
    text-shadow: 0 0 10px rgba(51,255,51,0.3); margin-bottom: 4px; text-align: center; }
  .sub { color: #1a8a1a; font-size: 0.8em; margin-bottom: 32px; text-align: center; }
  label { display: block; color: #1a8a1a; font-size: 0.75em; letter-spacing: 2px;
    text-transform: uppercase; margin-bottom: 6px; margin-top: 16px; }
  input { width: 100%; background: #111; border: 1px solid #1a3a1a; color: #e2e8f0;
    font-family: inherit; font-size: 1em; padding: 10px 12px; outline: none; }
  input:focus { border-color: #33ff33; }
  button { width: 100%; background: #33ff3322; border: 1px solid #33ff3344; color: #33ff33;
    font-family: inherit; font-size: 0.9em; padding: 10px; margin-top: 24px; cursor: pointer;
    letter-spacing: 1px; text-transform: uppercase; font-weight: bold; }
  button:hover { background: #33ff3333; }
  .err { color: #ff3333; font-size: 0.8em; margin-top: 12px; text-align: center; }
</style></head><body>
<div class="login">
  <div class="brand">&gt; LEDATIC REPORTS</div>
  <div class="sub">client portal</div>
  <form method="POST" action="/login">
    <label>Client ID</label>
    <input type="text" name="client_id" autocomplete="username" required autofocus>
    <label>Password</label>
    <input type="password" name="password" autocomplete="current-password" required>
    <button type="submit">Log In</button>
    ${error ? `<div class="err">${error}</div>` : ""}
  </form>
</div></body></html>`;
}

function dashboardPage(client, reports) {
  const byVertical = {};
  for (const r of reports) {
    if (!byVertical[r.vertical]) byVertical[r.vertical] = [];
    byVertical[r.vertical].push(r);
  }
  const verticalCards = Object.entries(byVertical).sort(([a],[b]) => a.localeCompare(b)).map(([vertical, rpts]) => {
    const niceName = vertical.replace(/_/g, " ");
    const fileLinks = rpts.sort((a,b) => (b.uploaded||"").localeCompare(a.uploaded||"")).map(r => {
      const sz = r.size > 1048576 ? (r.size/1048576).toFixed(1)+" MB" : Math.round(r.size/1024)+" KB";
      const date = r.uploaded ? r.uploaded.slice(0,10) : "";
      return `<div class="rpt"><a href="/dl/${encodeURIComponent(r.r2_key)}" target="_blank">${r.name}</a><span class="meta">${sz} &middot; ${date}</span></div>`;
    }).join("");
    return `<div class="vertical"><div class="v-header"><span class="v-name">${niceName}</span><span class="v-count">${rpts.length} report${rpts.length!==1?"s":""}</span></div>${fileLinks}</div>`;
  }).join("");
  const totalReports = reports.length;
  const totalVerticals = Object.keys(byVertical).length;
  return `<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Ledatic Reports — ${client.name}</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { background: #0a0a0a; color: #e2e8f0; font-family: 'Courier New', monospace;
    min-height: 100vh; padding: 40px 24px; max-width: 760px; margin: 0 auto; }
  .top { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 32px; }
  .brand { color: #33ff33; font-size: 1.4em; font-weight: bold; letter-spacing: 2px;
    text-shadow: 0 0 10px rgba(51,255,51,0.3); margin-bottom: 4px; }
  .sub { color: #1a8a1a; font-size: 0.8em; }
  .logout { color: #333; font-size: 0.75em; text-decoration: none; padding: 4px 12px;
    border: 1px solid #222; }
  .logout:hover { color: #666; border-color: #444; }
  .section-title { color: #33ff33; font-size: 0.7em; letter-spacing: 3px;
    text-transform: uppercase; margin-bottom: 12px; padding-bottom: 8px;
    border-bottom: 1px solid #1a3a1a; }
  .vertical { border: 1px solid #1a2a1a; padding: 16px 20px; margin-bottom: 8px;
    border-radius: 6px; }
  .vertical:hover { border-color: #33ff3344; }
  .v-header { display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 10px; }
  .v-name { font-weight: bold; font-size: 1em; }
  .v-count { font-size: 0.7em; color: #666; }
  .rpt { padding: 4px 0; font-size: 0.8em; display: flex; justify-content: space-between;
    align-items: center; }
  .rpt a { color: #33ff33; text-decoration: none; }
  .rpt a:hover { text-decoration: underline; }
  .rpt .meta { color: #1a6a1a; font-size: 0.85em; }
  .stats { margin-top: 32px; padding-top: 16px; border-top: 1px solid #1a2a1a;
    display: flex; gap: 32px; font-size: 0.8em; color: #1a8a1a; }
  .stats .num { color: #33ff33; font-weight: bold; }
  .empty { color: #333; font-size: 0.85em; padding: 40px 0; text-align: center; }
</style></head><body>
<div class="top">
  <div>
    <div class="brand">&gt; LEDATIC REPORTS</div>
    <div class="sub">${client.name}</div>
  </div>
  <a href="/logout" class="logout">log out</a>
</div>
<div class="section-title">Your Reports</div>
${verticalCards || '<div class="empty">No reports yet. They will appear here as they are generated.</div>'}
<div class="stats">
  <div><span class="num">${totalVerticals}</span> verticals</div>
  <div><span class="num">${totalReports}</span> reports</div>
  <div><span class="num">$0</span> per report</div>
</div>
</body></html>`;
}

// ─── reports.ledatic.org handler ─────────────────────────────────────────────

async function handleReports(request, env, pathname) {
  const method = request.method;
  const host = request.headers.get("Host") || "";

  if (pathname === "/" || pathname === "/login") {
    if (method === "GET") {
      const clientId = await getSession(request, env);
      if (clientId) return Response.redirect(new URL("/dashboard", request.url).href, 302);
      return new Response(loginPage(), { headers: sec({ "content-type": MIME.html }) });
    }
    if (method === "POST") {
      const form = await request.formData();
      const clientId = (form.get("client_id") || "").trim().toLowerCase();
      const password = form.get("password") || "";
      const client = await getClient(clientId, env);
      if (!client) {
        return new Response(loginPage("Invalid client ID or password"), {
          status: 401, headers: sec({ "content-type": MIME.html }),
        });
      }
      const hash = await hashPassword(password);
      if (hash !== client.password_hash) {
        return new Response(loginPage("Invalid client ID or password"), {
          status: 401, headers: sec({ "content-type": MIME.html }),
        });
      }
      const token = await createSession(clientId, env);
      return new Response(null, {
        status: 302,
        headers: sec({ "location": "/dashboard", "set-cookie": setCookie(token, host) }),
      });
    }
  }

  if (pathname === "/logout") {
    return new Response(null, {
      status: 302,
      headers: sec({ "location": "/", "set-cookie": clearCookie(host) }),
    });
  }

  // Authed-only below
  const clientId = await getSession(request, env);
  if (!clientId) return Response.redirect(new URL("/", request.url).href, 302);
  const client = await getClient(clientId, env);
  if (!client) {
    return new Response(null, {
      status: 302,
      headers: sec({ "location": "/", "set-cookie": clearCookie(host) }),
    });
  }

  if (pathname === "/dashboard") {
    const reports = await getClientReports(clientId, env);
    return new Response(dashboardPage(client, reports), { headers: sec({ "content-type": MIME.html }) });
  }

  if (pathname.startsWith("/dl/")) {
    const r2Key = decodeURIComponent(pathname.slice(4));
    if (!r2Key.startsWith(clientId + "/")) {
      return new Response("Forbidden", { status: 403, headers: sec({ "content-type": "text/plain" }) });
    }
    const obj = await env.REPORTS_R2.get(r2Key);
    if (!obj) return notFound();
    const filename = r2Key.split("/").pop();
    return new Response(obj.body, {
      headers: sec({
        "content-type": "application/pdf",
        "content-disposition": `inline; filename="${filename}"`,
        "cache-control": "private, max-age=3600",
      }),
    });
  }

  return notFound();
}

// ─── Internal API (Bearer-authed, shared across hosts) ───────────────────────

const API_BEARER = "YW4poVpINEaOEsPctzf8FRPTmycXHbH7lFyjRVRqsnc";

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: sec({ "content-type": "application/json" }),
  });
}

async function handleAPI(request, env) {
  if (request.headers.get("Authorization") !== `Bearer ${API_BEARER}`) {
    return new Response("Unauthorized", { status: 401, headers: sec({ "content-type": "text/plain" }) });
  }

  const body = await request.json();

  if (body.type === "devlog") {
    const today = body.date || new Date().toISOString().slice(0, 10);
    const tagList = Array.isArray(body.tags) ? body.tags : (body.tags || "").split(",").map(t => t.trim()).filter(Boolean);
    const entries = await env.LEDATIC_KV.get("devlog", { type: "json" }) || [];
    entries.unshift({ date: today, title: body.title, body: body.entry_body, tags: tagList });
    await env.LEDATIC_KV.put("devlog", JSON.stringify(entries.slice(0, 20)));
    return jsonResponse({ ok: true });
  }

  if (body.type === "snapshot") {
    const cur = await env.LEDATIC_KV.get("snapshot", { type: "json" }) || {};
    const updated = Object.assign({}, cur, {
      updated: new Date().toISOString().slice(0, 10),
      stats: Object.assign({}, cur.stats, body.stats || {}),
      services: Object.assign({}, cur.services, body.services || {}),
    });
    await env.LEDATIC_KV.put("snapshot", JSON.stringify(updated));
    return jsonResponse({ ok: true });
  }

  if (body.type === "focus") {
    const cur = await env.LEDATIC_KV.get("snapshot", { type: "json" }) || {};
    cur.focus = { big_picture: body.big_picture, next_up: body.next_up, set_at: body.set_at };
    await env.LEDATIC_KV.put("snapshot", JSON.stringify(cur));
    return jsonResponse({ ok: true });
  }

  if (body.type === "oversight_status") {
    const cur = await env.LEDATIC_KV.get("snapshot", { type: "json" }) || {};
    cur.oversight_status = { tuning: body.tuning, regime: body.regime, this_week: body.this_week || [], updated_at: body.updated_at };
    await env.LEDATIC_KV.put("snapshot", JSON.stringify(cur));
    return jsonResponse({ ok: true });
  }

  if (body.type === "report_meta") {
    const { client_id, vertical, report } = body;
    if (!client_id || !report) return jsonResponse({ error: "Missing fields" }, 400);
    const key = `reports:${client_id}`;
    const existing = await env.LEDATIC_KV.get(key, { type: "json" }) || [];
    existing.unshift({ ...report, vertical });
    await env.LEDATIC_KV.put(key, JSON.stringify(existing));
    return jsonResponse({ ok: true, count: existing.length });
  }

  if (body.type === "create_client") {
    const { client_id, name, password } = body;
    if (!client_id || !name || !password) return jsonResponse({ error: "Missing fields" }, 400);
    const hash = await hashPassword(password);
    const client = {
      id: client_id,
      name: name,
      password_hash: hash,
      created: new Date().toISOString(),
      preferences: {},
    };
    await env.LEDATIC_KV.put(`client:${client_id}`, JSON.stringify(client));
    return jsonResponse({ ok: true, client_id });
  }

  if (body.type === "update_client_prefs") {
    const { client_id, preferences } = body;
    if (!client_id) return jsonResponse({ error: "Missing client_id" }, 400);
    const client = await env.LEDATIC_KV.get(`client:${client_id}`, { type: "json" });
    if (!client) return jsonResponse({ error: "Client not found" }, 404);
    client.preferences = Object.assign({}, client.preferences, preferences);
    await env.LEDATIC_KV.put(`client:${client_id}`, JSON.stringify(client));
    return jsonResponse({ ok: true });
  }

  return jsonResponse({ error: "Unknown type" }, 400);
}

// ─── ledatic.org handler ─────────────────────────────────────────────────────

async function handleSite(request, env, url) {
  // http → https
  if (url.protocol === "http:") {
    url.protocol = "https:";
    return Response.redirect(url.toString(), 301);
  }

  // www → apex
  if (url.hostname === "www.ledatic.org") {
    url.hostname = "ledatic.org";
    return Response.redirect(url.toString(), 301);
  }

  const pathname = url.pathname;
  const method = request.method;

  // Dynamic public JSON. KV values may be malformed (e.g. legacy "undefined"
  // strings from earlier deploy tooling); fall through to empty default rather
  // than 500.
  if (pathname === "/data/devlog.json") {
    const raw = await env.LEDATIC_KV.get("devlog");
    let data = [];
    try { if (raw) data = JSON.parse(raw); } catch (_) { data = []; }
    return new Response(JSON.stringify(data), {
      headers: sec({ "content-type": "application/json", "cache-control": "no-store" }),
    });
  }
  if (pathname === "/data/snapshot.json") {
    const raw = await env.LEDATIC_KV.get("snapshot");
    let data = {};
    try { if (raw) data = JSON.parse(raw); } catch (_) { data = {}; }
    return new Response(JSON.stringify(data), {
      headers: sec({ "content-type": "application/json", "cache-control": "no-store" }),
    });
  }

  // Entropy beacon
  if (pathname === "/entropy") {
    const html = await env.LEDATIC_KV.get("entropy:index");
    if (!html) return new Response("Beacon page not yet deployed", {
      status: 503, headers: sec({ "content-type": "text/plain" }),
    });
    return new Response(html, {
      headers: sec({ "content-type": MIME.html, "cache-control": "public, max-age=60" }),
    });
  }
  if (pathname === "/entropy/pulse") {
    const pulse = await env.LEDATIC_KV.get("entropy:pulse:current");
    if (!pulse) return new Response('{"error":"no pulse yet"}', {
      status: 503,
      headers: sec({ "content-type": "application/json", "access-control-allow-origin": "*" }),
    });
    return new Response(pulse, {
      headers: sec({ "content-type": "application/json", "cache-control": "no-store", "access-control-allow-origin": "*" }),
    });
  }
  if (pathname === "/entropy/pulse/log") {
    const log = await env.LEDATIC_KV.get("entropy:pulse:log");
    return new Response(log || "[]", {
      headers: sec({ "content-type": "application/json", "cache-control": "no-store", "access-control-allow-origin": "*" }),
    });
  }
  if (pathname === "/entropy/frame/current") {
    const frame = await env.LEDATIC_KV.get("entropy:frame:current", { type: "arrayBuffer" });
    if (!frame) return new Response("No frame yet", {
      status: 503, headers: sec({ "content-type": "text/plain" }),
    });
    return new Response(frame, {
      headers: sec({
        "content-type": "application/octet-stream",
        "cache-control": "no-store",
        "access-control-allow-origin": "*",
        "content-disposition": 'attachment; filename="plasma_frame.bin"',
      }),
    });
  }

  // API
  if (pathname === "/api/update" && method === "POST") {
    return handleAPI(request, env);
  }

  // Canonicalize /index.html → /
  if (pathname === "/index.html") {
    return Response.redirect(new URL("/", request.url).href, 301);
  }

  // Static content via KV
  let key = pathname === "/" ? "index.html" : pathname.slice(1);

  // Deny internal namespaces + dead orphans
  if (isPrivateKey(key)) return notFound();

  const served = await serveFromKV(key, env);
  if (served) return served;

  // SPA fallback: clean URL without extension → homepage
  if (!extOf(key)) {
    const fallback = await env.LEDATIC_KV.get("index.html");
    if (fallback) {
      return new Response(fallback, {
        headers: sec({ "content-type": MIME.html, "cache-control": "public, max-age=300, s-maxage=300" }),
      });
    }
  }

  return notFound();
}

// ─── Top-level dispatch ──────────────────────────────────────────────────────

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.hostname.startsWith("reports.") || url.hostname.startsWith("reports-")) {
      if (url.pathname === "/api/update" && request.method === "POST") {
        return handleAPI(request, env);
      }
      return handleReports(request, env, url.pathname);
    }

    return handleSite(request, env, url);
  },
};
