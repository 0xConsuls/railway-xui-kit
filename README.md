# railway-3xui-kit

Run **3x-ui** (Xray-core panel) on Railway behind a single public HTTPS port.

- One domain serves the panel, the subscription server and up to 10 HTTP-based inbounds
  (ws / xhttp / httpupgrade), routed by path through an internal nginx.
- Optional raw-TCP inbound through Railway's TCP Proxy (VLESS/Trojan/Shadowsocks over TCP, Reality).
- Secure defaults: random panel path, random initial password, panel bound to loopback.
- Real client IPs, working IP Limit, auto-filled Subscription URI and share-link host.
- The subscription watcher follows panel-side changes without a redeploy.
- Health check, crash supervision, and amd64 + arm64 builds.

```
                     Railway edge (TLS)                 container
client ──https──▶  <domain>:443  ──http──▶  nginx :3000
                                              ├─ /<panel-path>/  → 3x-ui panel  127.0.0.1:2053
                                              ├─ /<sub-paths>/   → sub server   127.0.0.1:2096
                                              ├─ /in1 … /in9     → inbounds     :8081 … :8089
                                              ├─ /healthz        → 200
                                              └─ /  (anything)   → inbound      :8080
client ──tcp───▶  xxx.proxy.rlwy.net:NNNNN ───────────▶  raw-TCP inbound (optional)
```

## Files

| Path | Purpose |
|---|---|
| `Dockerfile` | Installs 3x-ui (pinned version), nginx, fail2ban |
| `railway.toml` | Build, health check, restart policy |
| `core/entrypoint.sh` | Orchestrator and supervisor |
| `core/nginx-gen.sh` | Renders nginx.conf, connection events, settings watcher |
| `core/nginx.conf.template` | nginx skeleton with `@@PLACEHOLDERS@@` |
| `core/proxy-common.conf` | Proxy headers shared by every location |
| `core/lib.sh` | Logging, validation, SQLite helpers |
| `adapters/3x-ui.sh` | 3x-ui specifics: settings, credentials, subscription paths, fail2ban |
| `adapters/3x-ui-sockopt.sh` | Sidecar that auto-fixes `trustedXForwardedFor` and `externalProxy` |

## Deploy

1. Push this repository to GitHub (private is fine).
2. Railway → **New Project → Deploy from GitHub repo** → pick the repo.
3. **Settings → Volumes → Add volume**, mount path **`/etc/x-ui`**.
   Do this before creating inbounds; without it every redeploy wipes all data.
4. **Settings → Networking → Generate Domain**, target port **`3000`**.
5. Open **Deployments → View Logs**. The log prints:
   - the panel URL (`https://<domain>/<random-path>/`);
   - the initial admin password (fresh database only);
   - the subscription URL.
6. Log in and change the password, or set `ADMIN_USERNAME` / `ADMIN_PASSWORD` variables.

## Inbounds over HTTPS (through nginx)

**Inbounds → Add Inbound**:

| Field | Value |
|---|---|
| Protocol | VLESS (or VMess / Trojan) |
| Port | from the table below |
| Network | `ws` (most stable), `xhttp` or `httpupgrade` |
| Security | **none** (Railway terminates TLS) |
| Path | matching the port |
| Listen IP | empty |

| Path | Port |
|---|---|
| anything not listed below (e.g. `/cdn`, `/a/b`) | **8080** |
| `/in1…` | 8081 |
| `/in2…` | 8082 |
| … | … |
| `/in9…` | 8089 |

- **Prefix matching.** Routes match by prefix, so `/in1mobile` goes to 8081. For the same
  reason, the 8080 inbound's path must not start with `/in1`–`/in9`.
- **One inbound per port.** Two inbounds on one port with different paths make the kernel
  split connections randomly between them, so about half of the connections fail.
- **Handled automatically** within about 20 s of creating an inbound:
  - `sockopt.trustedXForwardedFor = ["X-Forwarded-For"]`, so real client IPs appear in the
    panel and IP Limit works;
  - `externalProxy = <domain>:443 + TLS`, so share links and subscriptions point at the
    public edge instead of `:8080`.
- **Cloudflare / CDN.** If your custom domain is behind Cloudflare, leave the ws **Host**
  field empty. Otherwise clients bypass the CDN.
- **gRPC** does not work through Railway's HTTP edge.

**Quick test:** open `https://<domain>/in7`.
- `400` or `404` → the inbound is answering.
- `502` → no inbound is listening on 8087 yet.

## Raw-TCP inbound (Railway TCP Proxy)

1. **Settings → Networking → TCP Proxy**, application port e.g. `20000`.
2. Create an inbound on port `20000` with network `tcp`. Reality works too.
3. In the client link, use the `xxx.proxy.rlwy.net:<port>` printed in the boot log.

Some proxy hostnames resolve to addresses that are filtered on certain networks. Deleting and
re-creating the TCP proxy assigns a new one.

**Limits:** Railway gives one TCP proxy per service and no UDP, so Hysteria2/TUIC are not
possible. A TCP proxy also hides the client IP.

## Subscription links

- The panel builds sub links from **Settings → Subscription → Subscription URI**.
- On first boot it is pre-filled with `https://<domain>/sub/`. It is never overwritten after that.
- nginx serves all the paths a sub link could use, so a link never 404s:
  - the path inside Subscription URI;
  - Subscription Path;
  - the default `/sub/`;
  - the JSON / Clash paths, when enabled.
- If you change these in the panel, nginx follows within 15 s. No redeploy is needed.
- Leave **Sub Domain** empty. When it is set, the sub server rejects every other Host.
- Do not change **Sub Port** unless you have a reason to. It is internal-only; the watcher
  follows it anyway.

## Variables (Railway → Variables)

| Variable | Default | Meaning |
|---|---|---|
| `HTTP_PORT` | `3000` | nginx port = domain target port. `$PORT` is ignored on purpose (Railway often injects 8080). |
| `PANEL_PATH` | DB value, else random | Panel base path, e.g. `/mypanel/` |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | — | Applied on every boot when both are set |
| `DEFAULT_INBOUND_PORT` | `8080` | Catch-all inbound port, or `off` (→ 404) |
| `INBOUND_ROUTES` | `/in1:8081,…,/in9:8089` | Comma list of `path:port` |
| `ROOT_REDIRECT` | `false` | `true` = bare domain redirects to the panel (reveals it to scanners) |
| `PUBLIC_HOST` | `$RAILWAY_PUBLIC_DOMAIN` | Public host for sub URI / share links (set it for a custom domain) |
| `AUTO_SUB_URI` | `true` | Pre-fill Subscription URI if empty |
| `SUB_PATH` | — | Force the subscription path (written into the panel) |
| `SUB_WATCH` / `SUB_WATCH_INTERVAL` | `true` / `15` | Follow panel-side changes without redeploy |
| `XUI_AUTO_SOCKOPT` | `true` | Run the sockopt sidecar |
| `AUTO_EXTERNAL_PROXY` | `true` | Let the sidecar write `externalProxy` |
| `XUI_ENABLE_FAIL2BAN` | `true` | Keep the IP Limit field usable |
| `EVENT_WEBHOOK_URL` | — | Connection open/close webhook (see below) |
| `NGINX_ACCESS_LOG` | `false` | `true` = access log to stdout |
| `NGINX_WORKERS` | `1` | nginx worker processes |
| `PANEL_INTERNAL_PORT` | `2053` | Internal panel port |
| `TZ` | `Asia/Tehran` | Time zone |

### IP Limit

- IP Limit is saved and excess devices are disconnected.
- Permanent bans are not possible: Railway does not allow iptables. Use `limitIp` 2–3, not 1.

### Connection events

When `EVENT_WEBHOOK_URL` is set, nginx sends a GET request whenever a tunnel opens or closes:

```
<url>?ev=open|close&u=<inbound-path>&ip=<client-ip>&h=<host>
```

- If the URL already has a query string, the parameters are appended with `&`.
- The URL is validated before it is written into nginx.conf.
- An invalid URL disables the feature. The panel stays up.

## Safety nets

- Every value written into nginx.conf is validated: characters, length, prefix overlap and
  port collisions.
- A config that fails `nginx -t` is never applied. Recovery happens in order:
  1. connection events are disabled;
  2. custom subscription paths are dropped (only `/sub/` is kept).
- The panel and the sub server listen only on `127.0.0.1`.
- If the panel or nginx exits, the container exits and Railway restarts it.

## Upgrading 3x-ui

- In `Dockerfile`, change `ARG XUI_VERSION=3.8.5` and commit.
- Railway rebuilds automatically. Data on the volume is kept.

## Migrating from other templates

**From `baddarksss/railway-3xui`:**
- The volume path (`/etc/x-ui`), the ports and the `/in1…/in9` routes are the same.
- Your existing `/managepanel/` path is read from the database and kept.
- Existing passwords are never reset.
- Rename the variable `IB_PUSH_URL` to `EVENT_WEBHOOK_URL`.

**From `arvin341az-glitch/railway-x3ui`:**
- That template has no volume, so export your inbounds and clients before switching.
- Attach a volume at `/etc/x-ui`.
- Change the domain target port to `3000`.
- Keep your TCP proxy and point it at the port of your TCP inbound.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Application failed to respond` | Domain target port must be `3000` |
| Everything gone after redeploy | Volume not mounted at `/etc/x-ui` |
| Lost the panel URL / password | Read the boot log. Or set `PANEL_PATH`, `ADMIN_USERNAME` and `ADMIN_PASSWORD` and redeploy |
| Sub link shows `http://…:2096` | Set Subscription URI to `https://<domain>/sub/` |
| Sub link 404 | Clear Sub Domain; wait 15 s after changing paths |
| Inbound works only sometimes | Two inbounds share a port |
| Connects but no traffic | Clear the ws Host field |
| IP table empty | Wait 20 s after creating the inbound (sidecar), then reconnect |

## Caveats

- Check Railway's terms of service regarding proxy workloads.
- Anyone who can read the deploy logs sees the initial password. Change it after your first login.
- `post_action` (used for close events) is an undocumented nginx directive.
