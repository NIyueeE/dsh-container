# Deployment & Maintenance

This guide targets running the dsh container on your own host (Docker or Podman, Linux preferred;
the Compose example also works on Docker Desktop for macOS/Windows).

## 1. Prerequisites

- Linux host (Docker Engine ≥ 24 or Podman ≥ 4.4) — or Docker Desktop for the Compose example
- Access to `ghcr.io`
- Port `3081` free (the exposed port; dsh itself listens on `127.0.0.1:3080` inside the container)
- In-container rootless podman needs a host runtime that allows nested user namespaces and fuse
  (Docker's default seccomp profile may block it); the image side is fully configured — see
  §7 "In-container podman" and [security.md](security.md)

## 2. Docker Compose deployment

```bash
docker compose -f examples/compose.yaml up -d
docker compose logs dsh | grep 'dsh web:'
```

Open `http://127.0.0.1:3081/` and follow the Web UI wizard to configure a model (API key) and pick
a working directory under `/home/dsh` (dsh creates folders there as needed). There is no separate
login form: the first visit is redirected to dsh's launch token, dsh sets an
`HttpOnly; SameSite=Strict` session cookie, and the browser holds it. The network edge can still
require basic auth (`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`); see [security.md](security.md).

Images are published by `dsh-v*` release tags that match upstream dsh tags; `:latest` points to
the most recent release.

- `compose.yaml` publishes the proxy on host loopback (`ports: ["127.0.0.1:3081:3081"]`) — reachable
  from the host itself and from a host-side reverse proxy, not from other machines.
  Inside the container, **Caddy** listens on `0.0.0.0:3081`, preserves the browser `Host`/`Origin`,
  and forwards to dsh on `127.0.0.1:3080`. dsh's `/api` fence accepts loopback and the authorities
  named by `DSH_TRUSTED_HOST` (the image derives it from `DSH_PUBLIC_URL`); Caddy rejects any other
  Host with `403`. For LAN/public set `DSH_PUBLIC_URL` to the browser-facing URL, add
  `DSH_TRUSTED_HOST` if you use more than one authority, and enable basic auth — see
  [security.md](security.md):
  - plain LAN publishing: change the mapping to `"3081:3081"` (then enable basic auth — it is
    mandatory once the port leaves loopback; see security.md);
  - container-only (not reachable from the host): just don't publish the port.
- Data persistence: the `dsh-home` volume is mounted on the **whole `/home/dsh` directory**.
  The volume holds only data — `~/.dsh` (profiles / sessions / plugins / credentials), writable
  caches (`~/.cargo` registry, uv data, pnpm store), dotfiles, and anything the user installs
  under `$HOME` — all of it survives image upgrades. The toolchain is image-owned: uv, pnpm, and
  the Rust toolchain live in the system layer (`/usr/local/bin`, `/opt/rust`) and are upgraded
  together with the image (the one writable exception is rustup's home `/opt/rust/rustup`, which
  rustup needs to write at runtime — it is built `dsh`-owned and the entrypoint repairs its
  ownership on every start), so a volume can never shadow a newer image's tools. The dsh
  source tree and built artifacts live in `/opt/deepseek-harness`, so an empty or fresh `/home/dsh`
  volume never hides dsh. To access user files directly from the host, switch the volume to a bind
  mount at `/home/dsh` and keep it owned by uid 1000; on SELinux hosts keep `:Z` in that
  bind-mount definition. Because all tools are image-owned, an empty bind mount loses nothing —
  no seeding step is needed. dsh/agent temporary files default to `~/.dsh/tmp` (`TMPDIR`), so
  scratch files also survive container recreation and can be cleared with `rm -rf ~/.dsh/tmp/*`.
  `/tmp` itself stays ephemeral: the launch token, Caddyfile, `dsh-web` PID file and the
  `XDG_RUNTIME_DIR` fallback are deliberately not persisted.

## 3. Podman Quadlet deployment (recommended)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service

systemctl status dsh.service
journalctl -u dsh.service -f | grep 'dsh web:'
```

Open `http://127.0.0.1:3081/` (default `PublishPort=127.0.0.1:3081:3081`) — the first visit is
redirected to dsh's launch token, and the browser keeps the session cookie from then on.

- `dsh.container` publishes the proxy on host loopback via `PublishPort=127.0.0.1:3081:3081`;
  access `http://127.0.0.1:3081`. For plain LAN publishing use `PublishPort=3081:3081` (basic auth
  then mandatory).
- The `dsh-home` volume is mounted on the whole `/home/dsh` directory (same persistence
  model as Compose). If you prefer host-visible storage, replace it with a bind mount at
  `/home/dsh` owned by uid 1000.
- For user-level (rootless podman) deployment, put the file in `~/.config/containers/systemd/`
  and change `WantedBy` in `[Install]` to `default.target`.

## 4. Updating dsh and the image

dsh is built into the image at `/opt/deepseek-harness` and there is no runtime npm auto-update.
To run a different dsh version, publish/use an image built from that upstream tag (minimum
0.2.1-alpha.3; `Containerfile` rejects older tags):

**Upgrading from v0.2.x images:** those images npm-installed dsh into the persisted volume
(`~/.local`). The stale copy is inert — PATH is image-first, so the image-provided dsh always
wins — but it wastes space and is confusing; remove it manually with the commands in
[releasing.md](releasing.md) § Upgrading data volumes to the image-owned toolchain. Toolchain
copies seeded into volumes by even older images are likewise inert (PATH prefers the image-owned
binaries); remove them the same way to reclaim space. After upgrading and
restarting the container, verify with `docker exec dsh dsh --version` (or `podman exec dsh dsh
--version`) — it must print the version matching the image tag. To inspect an image's provenance
stamp: `docker exec dsh cat /etc/dsh-container/provenance.json`.

**Volume migration is one-way.** A release may migrate data under `~/.dsh` **forward** —
session-log format, settings/preset storage, provider configuration. The upstream release notes
quoted on each Release page are the authority on what a version changes. Do not roll the image
back to an older `dsh-v*` tag after upgrading a volume.

- **Quadlet** already sets `Pull=newer` (pulls on restart when a newer remote image exists) and
  `AutoUpdate=registry`; combine with `systemctl enable --now podman-auto-update.timer` to
  periodically pull new images and restart the container.
- **Compose**: `docker compose pull && docker compose up -d` achieves the same manually.

### 4.1 Restart dsh web without restarting the container

`dsh web` runs under a small supervisor (`dsh-web`) that restarts it automatically if it exits. To
force a restart from inside the running container:

```sh
docker exec dsh dsh-restart
# or: podman exec dsh dsh-restart
```

This sends `SIGTERM` to the current `dsh web` process; the supervisor starts it again with the same
container command arguments. Use it after manually changing dsh config/files that need a reload,
without bouncing Caddy or the whole container.

## 5. Remote access

By default the proxy is published on host loopback only (`127.0.0.1:3081`) — the UI is reachable
from the host itself and from a host-side reverse proxy, but not from other machines. Serving other
devices is an explicit step; when you do, treat it like any network service:

- **plain LAN publishing** (`"3081:3081"` / `PublishPort=3081:3081`): set
  `DSH_PUBLIC_URL=http://<host>:3081/`, **enable basic auth** (`DSH_PROXY_USER` /
  `DSH_PROXY_PASSWORD`) — anyone reaching `3081` can complete the login and control the agent — and
  keep the port behind the host firewall when unused;
- **public HTTPS** (a host-side nginx in front, TLS at nginx): keep the container port on loopback
  and see "Public deployment (nginx in front)" below — basic auth stays mandatory and nginx adds
  rate limiting / banning;
- **anything beyond that**: use an SSH tunnel instead (`http://localhost:3081`, not the LAN address
  or the public name — DeepSeek account sign-in only works from a loopback origin, see below):

```bash
ssh -L 3081:127.0.0.1:3081 user@your-host
# open http://localhost:3081 in your local browser
```

The proxy preserves the browser authority; there is no Host/Origin rewriting. Set
`DSH_PUBLIC_URL` to the browser-facing URL (the image derives the trusted authority from it), or
set `DSH_TRUSTED_HOST` explicitly when more than one authority is used. Caddy's Host allowlist and
dsh's fence share that list; any other Host gets `403`. The container-adapt plugin writes dsh's
launch token, Caddy redirects the first visit to `/?token=...`, and dsh sets the browser-held
session cookie — there is no server-side cookie injection. **Basic auth
(`DSH_PROXY_USER` / `DSH_PROXY_PASSWORD`) is still the network access control** for any
non-loopback deployment (see [security.md](security.md)); `/api/remote.mux` is exempt and uses the
session cookie because browsers do not reliably attach `Authorization` to WebSocket upgrades.

The settings-document affordance is gated on the page authority: a loopback page (an SSH
tunnel) creates its controller, and the plugin reports `hasDocument: false` so the button never
renders; remote authorities do not create it. The plugin also serves the extracted images.

**The settings-document button is hidden** — "Open config file" (Settings) has no headless
fallback upstream and would spawn `xdg-open` into nothing in a container. The plugin makes
`settings/describe` report `hasDocument: false`, so upstream's own UI never renders the button.
Settings still live on the mounted volume under `~/.dsh`: upstream v0.1.7+ stores form values in
the active profile's plugin configuration (`~/.dsh/profiles/<profile>/cordis.patch.yml`, e.g.
`profiles/web/`) and imports the legacy `~/.dsh/settings.yaml` **once**, renaming it to
`settings.yaml.imported`; provider credentials stay in `~/.dsh/.credentials.yaml`. That import
runs only *after* the loader has settled, i.e. after the start that found the file has already
resolved its configuration — so a hand-written `settings.yaml` takes effect from the **next**
`dsh` start, not the current one (on a fresh home with a single start, never). Read or edit
them from the host, or inside the container (`docker exec dsh cat
~/.dsh/profiles/web/cordis.patch.yml`).

### DeepSeek account sign-in only works from a loopback browser origin

"Sign in" failing is an upstream constraint, not a proxy misconfiguration, and the proxy cannot
lift it. The account "Sign in" button runs an OAuth authorization-code flow with PKCE: the browser
hands its own origin (`window.location.origin`) to dsh, dsh registers `/oauth/callback` and passes
that origin to the platform as `redirect_uri`, and the browser is redirected there to finish.
Upstream accepts only three shapes for that origin — `http://localhost:<port>`,
`http://127.0.0.1:<port>`, `http://[::1]:<port>` — anything else (a remote domain, an `https://`
origin, a path-based proxy) is rejected before the platform is even contacted
(`packages/credentials/deepseek-account-platform/src/protocol.ts`, `loginOrigin()`). The observable
symptom is a sign-in dialog that opens a tab and leaves it on `about:blank` while the popup stays
empty.

The platform enforces the same policy on its own side, so patching the upstream check would buy
nothing: `POST https://platform.deepseek.com/auth-api/v0/dsh/auth_init` rejects a public
`redirect_uri` with `50005 PAYLOAD_SCHEMA_MISMATCH` *before* any authorization happens. Measured
against the live endpoint (no account, no consent screen involved):

| `redirect_uri` | Platform |
|---|---|
| `http://localhost:3080/oauth/callback` | accepted (`code: 0`, returns `authorize_url`) |
| `http://localhost:3081/oauth/callback` | accepted — any port, any path, query/fragment allowed |
| `http://127.0.0.1:3080/…`, `http://[::1]:3080/…` | accepted |
| `http://localhost/oauth/callback` (no port) | rejected `50005` |
| `https://localhost:3080/…` (https loopback) | rejected `50005` |
| `https://<your-domain>/oauth/callback` | rejected `50005` |
| `http://<public-ip>:3081/oauth/callback` | rejected `50005` |

So the accepted shape is *http + loopback host + explicit port* — the same policy upstream's
`loginOrigin()` encodes client-side, which is why the proxy cannot substitute for the tunnel: the
callback only has an effect where `localhost:<port>` actually reaches the container.

So the tunnel has to run in the **browser's** direction, and the sign-in browser has to be on a
machine that can reach the dsh host's own loopback:

```bash
# on the machine running the browser (not on the dsh host)
ssh -L 3081:127.0.0.1:3081 user@your-host
# then sign in from http://localhost:3081
```

Use `127.0.0.1` as the forward's *destination*, not `localhost`: the proxy listens on IPv4
(`0.0.0.0:3081`), and an SSH client that resolves the destination to `::1` forwards into a port
nothing is listening on. Do not add `-g` — that would expose the authenticated proxy to the
browser's whole network. Basic auth applies inside the tunnel too when
`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` are set.

`http://localhost:3081` and `http://<host>:3081` are different origins, so the session cookie is
**not** shared: the public name keeps its own, un-signed-in session, and account surfaces
(balance, bonuses, account-scoped models) only show data in the tunneled session. Signing in from a
remote browser that cannot reach the host's loopback is not supported — that is the constraint, not
a missing feature of this image.

Account sign-in and model access are independent: to use DeepSeek models without account features,
set an API key on the Models page (or in `~/.dsh/.credentials.yaml`), which needs no loopback origin
and therefore works over any of the exposure modes above.

Note the container needs outbound access to `platform.deepseek.com` too — `auth_init` is a
server-side request. That endpoint sits behind a WAF that filters by client, so a container forced
through a proxy or an unusual egress path can fail sign-in with a *network* error before the
platform ever sees the request; a `curl` probe from inside the container reproduces it as an
HTML `429 Request Blocked` page with curl's default User-Agent and `HTTP 200` with a browser
User-Agent. If sign-in fails while the platform is otherwise reachable, check which side is failing
before assuming the loopback constraint.

### External reverse proxy with TLS (WAN)

`3081` is plain HTTP, so for anything beyond the LAN, terminate TLS in front of the container with
an authenticated reverse proxy (nginx, Caddy, Traefik, ...). The proxy config matters — two common
mistakes silently break the Web UI's event streams while the page itself still loads:

- **Missing WebSocket upgrade headers.** The UI streams agent events over WebSocket
  (`/api/remote.mux`). Without `Upgrade`/`Connection` the handshake is answered with a plain
  `404 Not Found` (older dsh tags answered `426 Upgrade Required`), and proxies that strip these
  hop-by-hop headers (nginx's default) kill the streams outright. The page itself still loads and
  renders — an unauthenticated `GET /` is a normal `200` — so the deployment *looks* healthy while
  **every live element is frozen**: streaming output never appears, and running indicators, tool
  spinners, job progress and approval prompts never update until a manual refresh. Measured through
  a naive nginx in front of the container: `GET /` → `200`, `GET /api/remote.mux` → `404`, and
  0 % of a 15 s probe window had a live event socket.
- **Buffering + short idle timeouts.** dsh sends a WebSocket ping every 2 s, so a proxy that idles
  streams out after 60 s (nginx's default `proxy_read_timeout 60s`) is already too aggressive:
  a stream that sits quiet (agent thinking, no output) can still be cut, and an idle timeout
  *shorter* than the heartbeat cuts every connection in a loop. Measured with `proxy_read_timeout 1s`:
  7 disconnects in 15 s and ≈23 % of the time with no live socket — the UI intermittently freezes
  for the reconnect window (0.5–10 s backoff), and the container log fills with periodic
  `aborting with incomplete response ... context canceled` errors. Disable response buffering and
  raise the timeouts well above the heartbeat (`proxy_read_timeout 3600s`).

A minimal nginx example that works:

```nginx
location / {
    proxy_pass http://127.0.0.1:3081;       # container's exposed port
    proxy_http_version 1.1;                 # WebSocket requires HTTP/1.1
    proxy_set_header Upgrade $http_upgrade; # required for the UI's WebSocket streams
    proxy_set_header Connection "upgrade";  # required for the UI's WebSocket streams
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    # dsh sees HTTP and sets the session cookie without Secure; add it on the TLS leg
    proxy_cookie_flags ~ secure;            # nginx >= 1.19.3
    proxy_buffering off;                    # stream agent output without buffering
    proxy_read_timeout 3600s;               # don't cut quiet (idle) streams
    proxy_send_timeout 3600s;
}
```

Caddy and Traefik forward WebSocket upgrades and stream responses by default; with those you only
need the raised idle timeouts (Caddy's defaults are already unlimited).

On the container side, set `DSH_PUBLIC_URL` to the browser-facing URL (for example
`https://dsh.example.com/`) and add `DSH_TRUSTED_HOST=dsh.example.com` if you also use another
authority; the image derives the trusted authority from `DSH_PUBLIC_URL` when the variable is
unset. nginx must preserve the browser `Host` (`proxy_set_header Host $host`, already in the block)
so dsh's fence sees the trusted authority, and it must add `Secure` to the dsh cookie on the TLS
leg because dsh itself sees HTTP — `proxy_cookie_flags ~ secure` above does that. If you prefer
nginx to own authentication, configure it there and leave
`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` unset.

Verify the whole path (outer proxy → container) in ten seconds — the handshake must come back
`101 Switching Protocols`; `404` means an intermediary swallowed the upgrade headers, and a
connection that opens but closes within a few seconds means an idle timeout below the 2 s
heartbeat. Add your proxy's credentials when it authenticates:

```sh
# 101 = the event stream survives the hop; 404 = upgrade headers stripped; 401 = auth.
curl -sS -i --max-time 5 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://your-host:3081/api/remote.mux | head -n 1
```

For a continuous check, connect a real WebSocket client and confirm a ping frame roughly every
2 s with no disconnects over a minute — a client that only sees closes every couple of seconds is
talking through a too-short read timeout, not to a broken container.

### Public deployment (nginx in front)

Serving dsh over the public internet means exposing an agent that executes arbitrary commands
behind one authentication factor — treat this checklist seriously:

- **Keep the container port on loopback.** With `127.0.0.1:3081:3081` (the examples' default) the
  only path in is nginx; with `3081:3081` scanners can hit the plain-HTTP Caddy directly and skip
  your TLS layer entirely.
- **Basic auth stays on** (`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`) — nginx has no auth in this
  topology, so Caddy's prompt is the single authentication factor. Use a long random password
  (20+ chars): Caddy has no rate limiting, so password entropy is what stops online brute force.
- **Rate-limit and ban at nginx.** Brute force shows up as 401s in the nginx access log — a
  fail2ban jail matching those (`maxretry=5`, `findtime=10m`) or a `limit_req` zone shuts it down.
- **The nginx → container hop** is plain HTTP on host loopback — fine when nginx runs on the same
  host; across machines it must be encrypted or on a private network.
- **Consider mTLS** (`ssl_verify_client on` + client certs on your devices) or a VPN
  (WireGuard/Tailscale) — for a single-user deployment both are strictly stronger than a password
  factor on the public internet.

A public-exposure server block (TLS termination, HSTS, rate limiting) around the `location /` block
above:

```nginx
limit_req_zone $binary_remote_addr zone=dsh:10m rate=10r/s;

server {
    listen 443 ssl;
    http2 on;                             # nginx >= 1.25.1; older: listen 443 ssl http2;
    server_name dsh.example.com;

    ssl_certificate     /etc/letsencrypt/live/dsh.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dsh.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        limit_req zone=dsh burst=20 nodelay;
        # ... the location / block above (proxy_pass 127.0.0.1:3081,
        # Upgrade/Connection headers, buffering off, raised timeouts) ...
    }
}

server {
    listen 80;
    server_name dsh.example.com;
    return 301 https://$host$request_uri;
}
```

## 6. Built-in tools

The image bakes the tools an agent reaches for every day into the system layer, so a fresh
container never spends its first minutes downloading them:

| Group | Contents |
|---|---|
| Agent CLI basics | `git` + `git-lfs` (installed system-wide), `curl`, `wget`, `jq`, `ca-certificates`, `gnupg` |
| Search & patch | `ripgrep` (`rg`), `fd`, `patch`, `diff`/`sed`/`awk` from the base |
| Languages & runtimes | Node.js 24 LTS + npm/pnpm, uv, Rust/cargo with `rustfmt` + `clippy`, python3 (apt-managed; PEP 668 applies — prefer `uv run` / `uv pip` for project work), build-essential + libssl-dev for native builds, musl-tools (the static-musl `landlock-run` launcher behind dsh's `workspace-write` sandbox) |
| Editors & pagers | `vim.tiny` (`vi`), `nano`, `less` |
| Networking & debugging | `openssh-client`, `iputils-ping`, `iproute2` (`ss`/`ip`), `lsof`, `tree`, `htop` |
| Network diagnostics | `dig`/`nslookup`/`host` (`bind9-dnsutils`), `nc`, `socat`, `traceroute`, `iperf3`, `nft` (`nftables`) — this image's operational surface is mostly network plumbing (Caddy → dsh, plus nested podman's slirp4netns), so connectivity, bandwidth and firewall-rule checks are first-class |
| Files & processes | `file`, `ncdu`, `strace` — inspecting what a file is, what fills the volume, and where the `dsh-web`/Caddy/dsh trio is stuck |
| Compression & data | `zstd`, `lz4`, `bc`, `moreutils`, `pv`, `uuid-runtime` |
| Workspace / desktop integration | `xdg-user-dirs` (`xdg-user-dir`) — resolves the default Documents directory the UI uses to create its default workspace; the entrypoint provisions `~/Documents` and a minimal `~/.config/user-dirs.dirs` because a headless container has no XDG user-dirs config |
| Dev tooling | `just` (the repository's `justfile` recipes work inside the container, including `just build` via nested podman), `shellcheck` (the repository's lint gate runs in-container too) |
| YAML / JSON | `yq` — installed with `uv tool install` (see below), not via apt |

`tcpdump`, `iftop` and `mtr` are deliberately **not** installed: the container runs without
`CAP_NET_RAW` (`CapEff` is `cap_net_admin,cap_sys_admin`), so the capture sockets cannot be opened
and shipping them would only suggest they work. Add the capability on the host runtime if you need
packet capture inside the container.

### Installing tools that persist

Anything installed **at runtime** with `sudo apt install` lands in the container's writable layer
and is **lost when the container is recreated** (`--force-recreate`, image upgrade, Quadlet
`AutoUpdate`) — it survives an in-place `docker restart` only. Install paths that persist instead
(they live on the `/home/dsh` volume):

| Path | Lands in | On `PATH` |
|---|---|---|
| `cargo install <crate>` | `~/.cargo/bin` | yes |
| `uv tool install <pkg>` | `~/.local/share/uv/tools` + shims in `~/.local/bin` | yes |
| `uv pip` / uv-managed pythons | `~/.local` | yes |
| `npm -g` | `~/.local` (`NPM_CONFIG_PREFIX`) | yes |
| `pnpm add -g` | `~/.local/share/pnpm` (`PNPM_HOME`) + executables in `$PNPM_HOME/bin` | yes |
| `python3 -m pip install` | blocked by PEP 668 — use `uv pip` | — |

`rustup component add` writes the system layer and does not survive recreation — the frequently
used components (`rustfmt`, `clippy`) are preinstalled. If you need a permanent apt-level tool,
extend the image with a small child `Containerfile`
(`FROM ghcr.io/niyueee/dsh-container:latest`) and pin that image in the examples.

`yq` is the one tool installed through `uv tool install` at build time, into the image-owned
`/opt/uv-tools` (`/usr/local/bin/yq`, plus `tomlq`/`xq`). Three things are worth knowing:

- It is the **Python `yq`** (kislyuk's, 4.x), not Mike Farah's Go `yq` — the two have different
  syntax, and Debian 13's apt only packages this one. It shells out to `/usr/bin/jq` for JSON
  processing, so `jq` is a runtime dependency (the image installs it) and `yq --version` prints a
  second line with jq's version.
- It upgrades **with the image**, and `uv tool upgrade yq` deliberately fails inside the container
  (`/opt/uv-tools` is root-owned): this matches the image-owned toolchain model, where tools are
  upgraded by upgrading the image, never by mutating the volume.
- Installing your **own** `uv` tools at runtime is unaffected: `uv tool install` without
  `UV_TOOL_DIR` uses `~/.local/share/uv/tools` on the volume (the image never sets that variable).

The final image keeps a pre-warmed `/var/lib/apt/lists`, so `apt install` works without an update
first — but that index is a snapshot from build time. If an install fails with a 404 or hash
mismatch, run `sudo apt-get update` before retrying.

### Global agent instructions

dsh loads two **user-global** instruction files before any project file, on the first request of a
session (and reconciles them on later file activity and on session resume):

| Order | Path | Overridden by env |
|---|---|---|
| 1 | `~/.dsh/AGENTS.md` | `DSH_HOME` |
| 2 | `~/.agents/AGENTS.md` | `DSH_AGENTS_HOME` |

Both live on the `/home/dsh` volume, so they survive image upgrades. The two form a single
candidate group: identical content (after trimming) is rendered once, and the `~/.dsh` file wins.
The rendered baseline is capped (64 KiB in the `web` profile); over budget, broader files are
dropped before the most specific file is truncated, with a visible notice naming what was omitted.

The image deliberately ships **no** default there — pre-seeding a global instruction file would
silently change every agent's behavior and could never be updated without either overwriting your
edits or going stale. To teach the agent how this container is laid out, copy this into
`~/.dsh/AGENTS.md`:

```markdown
Runtime environment: this dsh runs inside a container image. The toolchain
(node, pnpm, uv, rust/cargo, caddy, podman, and dsh itself) lives in the
image-owned system layer under /usr/local/bin and /opt, so it updates with the
image. `apt install` and `rustup component add` at runtime land in the
disposable writable layer and are lost when the container is recreated.

/home/dsh is the persistent volume: ~/.dsh (settings, sessions, agent data),
~/.cargo, ~/.local, ~/.local/share/{uv,pnpm}. Install persistent tools there
(`cargo install`, `uv tool install`, `pnpm add -g`) rather than with apt.

Exact tool versions: /etc/dsh-container/provenance.json
```

## 7. In-container podman

The image installs podman with `crun`, `fuse-overlayfs`, `slirp4netns` and `uidmap`, and prepares
the runtime environment for **rootless podman as the `dsh` user** — the supported path, needing no
privileges beyond the container's own:

- **subuid/subgid carry the `dsh` range exactly once.** Duplicate lines make `newuidmap` build an
  overlapping mapping, which the kernel rejects with `Invalid argument` — rootless podman then
  cannot create its user namespace at all.
- **The image does *not* set `_CONTAINERS_USERNS_CONFIGURED`.** On podman 5.x that variable makes
  the inner podman skip user-namespace creation while its runtime still requires one (`euid != 0`
  → `needsUserns`), so the image store and the network backend are never initialized and every
  store-touching command dies on a nil-pointer panic. Without it the inner podman runs the standard
  rootless flow: `unshare` + setuid `newuidmap` over the subuid range, then a fully initialized
  runtime inside that user namespace.
- **Storage** is fully specified in `/etc/containers/storage.conf`: `driver = "overlay"` together
  with `mount_program = "/usr/bin/fuse-overlayfs"` and explicit `graphroot`/`runroot`. All four
  keys matter, because podman falls back to its compiled-in defaults only while the file is
  *absent* — once it exists, a missing key turns into a failure: without `driver` every single
  podman invocation warns `The storage 'driver' option should be set …`, and without
  `graphroot`/`runroot` *rootful* podman cannot even load its configuration (`runroot must be set`,
  podman 5.4.2). Rootless is unaffected either way: it keeps its own XDG paths (the system
  `graphroot`/`runroot` are ignored for a rootless user) and runs nested containers with working
  outbound networking. The one trade-off of pinning `driver` is losing the silent fall back to
  `vfs` — on a host where no overlay flavour works, podman now reports an error instead of quietly
  turning slow; `mount_program` still covers kernels without user-namespace overlay. `policy.json`
  accepts any registry.
- **Rootful podman (`sudo podman`) can load its configuration and pull images, but cannot *run*
  containers** — a host-invocation limit, not image configuration. crun creates the container's
  device nodes with `mknod`, which needs `CAP_MKNOD`; that capability is missing from the
  container's *bounding* set (`CapBnd`), so it cannot be acquired from inside (`sudo mknod` fails
  with `Operation not permitted`). Rootful then also hits cgroup v2's no-internal-process rule,
  because the container gets its own cgroup namespace — `--cgroups=disabled` clears that step.
  Enabling rootful would therefore take a host-side `--cap-add=MKNOD` (a genuine privilege
  increase) plus cgroup handling, and that combination is **not** verified end to end. Rootless
  podman needs none of it and is the path this image supports.
- **`/etc/containers/containers.conf`** presets `default_rootless_network_cmd = "slirp4netns"`
  (the image does not ship `pasta`, podman 5's preferred rootless network command) and empties
  `default_sysctls` — Debian's default `net.ipv4.ping_group_range` write fatally fails inside a
  nested rootless container (the nested `/proc/sys` is read-only), aborting container creation.
- **`XDG_RUNTIME_DIR` is provisioned by the entrypoint** (`/run/user/<uid>`, owned by the runtime
  user) — rootless podman cannot start without a writable runtime dir, and a container has no
  login session to create one. `/etc/bash.bashrc` exports the same default for **interactive**
  `docker exec` shells, which bypass the entrypoint; non-interactive exec (`docker exec dsh sh -c
  '...'`) does *not* read that file, so scripts must set it themselves:
  `docker exec dsh bash -lc 'export XDG_RUNTIME_DIR=/run/user/$(id -u); podman run --rm …'`.

What the **host** must still allow (the image cannot do this part):

- `seccomp=unconfined` (+ `apparmor=unconfined` on AppArmor hosts): the inner podman must be able
  to `unshare(2)` a new user namespace; Docker's and Podman's default seccomp profiles filter the
  relevant `clone`/`unshare` flags. The host kernel must also allow unprivileged user namespaces
  (the default on mainstream distros).
- `/dev/fuse` for the `fuse-overlayfs` storage driver.
- `/dev/net/tun` for the default rootless networking (slirp4netns/pasta open the tap device).
  Without it, run nested containers with `--network=host` or `--network=none`. On the host:
  `ls -l /dev/net/tun` and `modprobe tun` if it is missing.
- **No masked or read-only `/proc` submounts in the dsh container — the podman 5.x requirement
  that is easy to miss.** crun mounts a fresh `/proc` inside every nested container, and the
  kernel only allows that inside a user namespace when the container's own `/proc` is fully
  visible. Docker's/Podman's default masked and read-only paths (`/proc/kcore`, `/proc/sys`, …)
  break that, and the nested container fails with `crun: mount proc to proc: Operation not
  permitted`. Clear them on the outer container: Podman `--security-opt unmask=ALL`
  (Quadlet `Unmask=ALL`), Docker `--security-opt systempaths=unconfined`. The same flags keep
  `/proc/sys` writable, which the nested network setup needs.
- `CAP_SYS_ADMIN` + `CAP_NET_ADMIN` are *not* needed by the rootless flow itself (its user
  namespace carries the capabilities) — they only matter for the rootful fallback below.

| Host runtime | Working configuration |
|---|---|
| Docker (default, no userns) | `--cap-add=CAP_SYS_ADMIN --cap-add=CAP_NET_ADMIN --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt systempaths=unconfined --device /dev/fuse --device /dev/net/tun`, or `--privileged` |
| Docker with `userns-remap` | same as above (the remapped userns fixes file ownership, not the missing visibility) |
| Podman (rootless host) | `--userns=keep-id --security-opt unmask=ALL --security-opt seccomp=unconfined --device /dev/fuse --device /dev/net/tun`; then run `podman run …` as the `dsh` user inside — no `sudo` needed |
| Podman (rootful host) | `--security-opt unmask=ALL --cap-add=CAP_SYS_ADMIN --cap-add=CAP_NET_ADMIN --device /dev/fuse --device /dev/net/tun --security-opt seccomp=unconfined --security-opt apparmor=unconfined`, or `--privileged`. **Do not use `--userns=keep-id` here**: as root, keep-id overrides the image's `USER` and runs the container as root, so dsh data lands in `/root/.dsh` (container layer, lost on recreate) instead of the `/home/dsh` volume |
| Quadlet | `Unmask=ALL` (native key, podman 5.x; older podman: `PodmanArgs=--security-opt unmask=ALL`), `AddCapability=CAP_SYS_ADMIN CAP_NET_ADMIN`, `AddDevice=-/dev/fuse`, `AddDevice=-/dev/net/tun`, `SeccompProfile=unconfined`, `PodmanArgs=--security-opt apparmor=unconfined` (the native `AppArmor=` key needs podman ≥ 5.8; `PodmanArgs=--privileged` replaces the whole set) — see `examples/dsh.container` |

Verify inside the running container (see also the `XDG_RUNTIME_DIR` note above):

```bash
docker exec dsh bash -lc 'export XDG_RUNTIME_DIR=/run/user/$(id -u); podman run --rm docker.io/library/alpine:3.20 echo nested-ok'
```

Every one of these flags weakens the container boundary (see [security.md](security.md)) — enable
them only where nested containers are actually needed. Compose/Quadlet snippets are pre-commented
in `examples/compose.yaml` and `examples/dsh.container`. Docker Desktop (macOS/Windows) does not
support nested user namespaces at all — in-container podman is a Linux-host feature.

Fallbacks when the host cannot provide the above:

- **`sudo podman ...`** (rootful inside the container) skips `newuidmap` entirely, but it still
  needs the unmasked `/proc` and `/dev/fuse` above, and nested containers then hit the outer
  container's own limits: `/sys/fs/cgroup` is read-only (add `--cgroups=disabled`) and the default
  bridge network needs a writable `/proc/sys` (use `--network=host`/`--network=none`). Creating
  device nodes inside the nested container can additionally be denied by the outer container's
  device cgroup policy. Prefer the rootless flow wherever the host allows user namespaces.
- **`podman --storage-driver vfs ...`** works without `/dev/fuse` (skips fuse-overlayfs) at the
  cost of speed and disk space.

Two honest limits: in single-uid mode everything inside a nested container runs as one uid (images
that rely on multiple `USER` directives are not mapped correctly), and in-container podman is a
development convenience, not an isolation boundary — the host flags that enable it
(`--privileged`, unconfined seccomp) weaken the container boundary itself, so turn them on only
when nested containers are actually needed (see [security.md](security.md)).

### Resource limits inside nested containers

`--memory`, `--cpus`, `--pids-limit` and friends are **not enforced** inside nested containers:
`podman run --memory 64m ...` starts and runs, but the limit is silently ignored, and no compose
or Quadlet flag changes that. The reason is a cgroup v2 rule rather than a configuration gap: a
cgroup can either host member processes or distribute controllers to its children, never both.
Every process of this container — including everything `docker exec`, the healthcheck and the dsh
agent place into it — lives in the root of the container's cgroup namespace, so that root can
never enable controllers, and every cgroup libpod could create below it inherits the same
restriction.

The image deliberately does not work around this by emptying and re-seeding the namespace root
(relaying the stack into a child cgroup so the root can distribute controllers). That variant was
implemented and measured end to end: it does make nested `--memory` OOM-kill correctly, but it
also makes the kernel reject every process placement into the namespace root (`EBUSY`), which
breaks `docker exec`, the healthcheck and any host-side `run`/`attach` for as long as it is
enabled — an unacceptable trade for unflagged resource limits. Lifting the constraint requires
host-side setup instead: running the outer container with `--cgroupns=host` plus a delegated,
controller-enabled cgroup subtree that the `dsh` user owns. No in-image change can provide that,
so the docs promise the graceful degradation (containers run, limits are ignored) rather than
limits that only work on some hosts.

## 8. Offline use

The running image does not contact the npm registry, and there is no boot-time dsh update to
disable. The common agent CLI tools (`python3`, `rg`, `fd`, `ssh`, `zip`, ...) are built in, so a
fresh container works without any runtime downloads. Build the image once from the desired upstream
tag (pin `DSH_TAG`), then run it on hosts that only need access to `ghcr.io` for image pulls:

```bash
podman build --format docker \
             --build-arg DSH_TAG=dsh-v0.2.1-rc.2 \
             -t dsh-container .
```

## 9. FAQ

**Permission errors when writing to `/home/dsh`**
If you replace the named `dsh-home` volume with a host bind mount at `/home/dsh`, that host
directory must be owned by uid 1000: `sudo chown -R 1000:1000 <host-home-dir>`. The default named
volume handles ownership automatically.

**Port 3081 already in use**
The exposed port is `3081` (Caddy proxy → dsh's `127.0.0.1:3080` inside the container). Change
the host-side mapping instead: compose `ports: ["4081:3081"]`, quadlet `PublishPort=4081:3081`,
then use the new port. To move dsh's internal port, pass `command: ["--port", "8080"]` /
`Exec=--port 8080` — the proxy follows automatically. The entrypoint accepts an internal port in
`1–65535` and rejects `--port 3081` (proxy conflict), `--port 0` (the proxy needs a fixed internal
port), a missing value, and non-numeric or out-of-range values.

**Container exits with "DSH_PROXY_USER and DSH_PROXY_PASSWORD must be set together"**
Basic auth is enabled only when both variables are set. The supervisor (`dsh-web`) refuses to start
when just one is present, instead of silently leaving the proxy unauthenticated. Set both or remove both.

**Browser shows "dsh web authentication required"**
The first visit without a `dsh-auth-*` cookie should be redirected to `/?token=...`; if you see the
401 page instead, the launch-token write failed or the redirect was not applied: check
`docker compose logs dsh | grep -E 'dsh-web|dsh-container-adapt'` (or `journalctl -u dsh.service`
for Quadlet) for `launch token` errors, and confirm `/tmp/dsh-caddy/launch-token` exists inside the
container. The message is expected when hitting dsh's internal port `3080` directly (not published;
it is loopback-only inside the container). A stale cookie from an old image can also produce 401;
clear the site's cookies once, then reload.

**Account sign-in (the "Sign in" button) fails over a domain or LAN address**
Expected. Upstream only accepts a loopback browser origin for the OAuth callback
(`http://localhost:<port>` / `http://127.0.0.1:<port>` / `http://[::1]:<port>`), so `https://…`,
a LAN IP or a path-based proxy is rejected before the platform is contacted — typically a tab that
opens and stays on `about:blank`. Sign in from `http://localhost:3081` through an SSH tunnel
instead (`ssh -L 3081:127.0.0.1:3081 user@your-host`); see
[DeepSeek account sign-in](#deepseek-account-sign-in-only-works-from-a-loopback-browser-origin).
`DSH_PUBLIC_URL` does not change this: it is advertisement only, not an origin override. This
affects account features (balance, bonuses) only — an API key on the Models page works over any
exposure mode.

**How do I update dsh inside a running container?**
dsh is built into the image and immutable at runtime. Pull/run the image that is tagged with the
desired upstream dsh tag (`dsh-v*`), then recreate the container. `dsh-restart` only restarts the
current dsh web process; it does not change the dsh version.

**Remote access fails with `transport failure for /api/...: HTTP 403`**
The `/api` browser-trust fence is now real: it rejects a `Host` that is neither loopback nor in
dsh's trusted list. Set `DSH_PUBLIC_URL` to the browser-facing URL (the image derives the authority)
or add the authority to `DSH_TRUSTED_HOST`; Caddy's Host allowlist uses the same list. If the
settings page shows `settings are unavailable in this browser`, check the authority again; the
image does not inject `__DSH_TRANSPORT__` or rewrite the index body.

**Podman rootless + bind mounts**
If you bind-mount a host directory at `/home/dsh`, make sure it is owned by your uid and
readable by the container; keep the `:Z` label with SELinux.

**Quadlet: `converting "dsh.container": unsupported key 'AppArmor' in group 'Container'`**
The native `AppArmor=` Quadlet key only exists in podman ≥ 5.8 (the image ships 5.4.x). Use
`PodmanArgs=--security-opt apparmor=unconfined` instead, or drop the line on hosts without
AppArmor. Regenerate after editing with `systemctl daemon-reload`.

**Quadlet: `Failed to resolve unit specifiers in 'DSH_PROXY_PASSWORD=…': Invalid slot`**
The generated unit is a systemd unit, and systemd expands `%` there — a password containing a
percent sign (e.g. a URL-encoded `%7b`) breaks unit loading. Write the value with a doubled sign
(`%%`) in the Quadlet file; systemd turns it back into one `%` for the container.

**UI loads but event streams fail with 502 after an image upgrade**
The browser was holding a cached, pre-upgrade frontend that still calls WebSocket endpoints the
new dsh no longer serves. This image's Caddy proxy marks both index entries (`/` and
`/index.html`) `Cache-Control: no-store`,
so fresh loads always fetch the matching frontend; if you upgraded from an older image (or an
outer proxy cached the page), do one hard refresh (Ctrl+F5) or clear site data for the UI origin.
Confirm the running dsh version with `docker exec dsh dsh --version`.

**dsh web exits with `cannot resolve profile bundle "..."`**
A failed or partial plugin install can leave a bundle listed in
`/home/dsh/.dsh/profiles/<profile>/package.json` (`dsh.profile.bundles`) that no dsh
installation can resolve — for example a package that was never actually published. dsh refuses
to boot while that entry exists, and because the profile lives on the persisted `/home/dsh`
volume the failure survives image upgrades and `dsh-restart`. Remove the unresolvable entry from
the `dsh.profile.bundles` list (keep the default `@deepseek-ai/dsh-base` /
`@deepseek-ai/dsh-web-app` entries for the `web` profile; back the file up first), then run
`dsh-restart`. The entrypoint does not rewrite profile manifests automatically — user data on the
volume is never modified behind your back.

**Some animations look static**
dsh honours the OS/browser `prefers-reduced-motion` preference (85 stylesheets gate animation on
it): under `reduce` the running indicator falls back to a still icon, the run shimmer disappears,
most panel/dialog transitions become instant, and JS-driven animations render their end state. This
is upstream accessibility behaviour, not a proxy or container effect — and a *stable* subset of
animations being static points here, whereas streams that freeze mid-run and recover after a reload
point at the proxy path instead (see "External reverse proxy with TLS (WAN)"). Chromium browsers
expose no setting for it: on Windows the value mirrors the system "Animation effects" toggle
(`SPI_GETCLIENTAREAANIMATION`), so Edge reports `reduce` whenever that is off — Remote Desktop
sessions commonly are. Confirm with `matchMedia('(prefers-reduced-motion: reduce)').matches`; the
other sources are DevTools' *Emulate CSS media feature prefers-reduced-motion* and a
`--force-prefers-reduced-motion` launch flag (`edge://version` prints the command line).

**Remote access feels slow**
The proxy is not the bottleneck: WebSocket streams pass through unchanged and dsh's 2 s heartbeat
arrives with a constant 2001 ms gap (verified through Caddy 2.6 and through an nginx front-end
configured as above). Transfer size dominates, and this image shrinks it at build time: a cold page
load measured in a headless browser is **≈1.6 MiB on the wire**, against ≈5.8 MiB for upstream's
unprocessed payload (the client-plugin combos alone: 1187 KiB vs 5394 KiB). Three post-processing
steps run after `pnpm run build:official`: images inlined at ≥ 100 KiB are extracted to
`/container-assets/<content-hash>`, the client bundles are minified with esbuild (whitespace and
syntax only — see below), and the `.dsh-build` record is refreshed to match. The largest remaining
request is the combined client-plugin bundle `plugins/??…` at **≈1.0 MiB gzip (≈3.6 MiB raw, 57
modules)**, down from 5.06 MiB gzip (10.0 MiB raw); on a rate-limited 2 Mbit/s path that request
drops from ≈21 s to ≈4.2 s.

The minifier deliberately stops short of renaming identifiers. dsh concatenates several client
artifacts into **one response** (`plugins/??a/client.js,b/client.js…`) and the browser evaluates
that as a single script, so every artifact's top-level declarations share one scope while the
per-module factories run later — with identifiers renamed, a module body can call a *different*
file's same-named helper and the whole client fails to boot (measured: 58 of 65 entries failed to
activate with `--minify`, zero with `--minify-whitespace --minify-syntax`). Keeping upstream's
identifiers costs ≈0.1 MiB gzip on this bundle and keeps the boot deterministic.

Caching decides whether a repeat visit is nearly free or pays again:

- `/` and `/index.html` are `no-store`: the index is the dynamic boot manifest.
- The combined bundle and the plugin chunks carry `immutable` plus a `rev` derived from each
  artifact's mtime/ctime/size — so an image upgrade, or even a metadata-only rewrite of those
  files, invalidates them and the browser re-downloads the bundle.
- The Vite-hashed `/assets/*` tree gets no cache header from dsh itself; this image's proxy adds
  `Cache-Control: public, max-age=31536000, immutable`, so a repeat navigation re-fetches only the
  index (≈6 KiB gzip) instead of ~475 KiB of shell assets.
- The extracted images (≈3.7 MiB in total) live under `/container-assets/*` (served by the
  container-adapt plugin, not by Caddy's `/assets/*` rule) and are requested only when the
  account-onboarding screen that uses them opens; they are `immutable` from then on.

Server-side, dsh re-gzips the combined bundle on every request (there is no compressed-output
cache): ≈0.2 s of CPU per cold request on a 20-core host before post-processing, proportionally
less at the smaller payload; upstream's unminified JavaScript also costs the client more parse time
than the minified output shipped here. With basic auth enabled, Caddy caches a verified credential,
so steady-state requests cost ~2–3 ms — but the first request after a Caddy restart or cache expiry
pays one full bcrypt verification (measured **1.47 s** at the default cost 14, longer on a slow
host), which is why opening the UI can stall for a second or two right after startup. For anything
beyond the LAN, put an authenticated TLS reverse proxy in front.

`/api/remote.mux` (the WebSocket upgrade) is deliberately exempt from basic auth: browsers do not
reliably attach `Authorization` to WebSocket handshakes. It is authenticated by the browser's
`SameSite=Strict` session cookie, so enable basic auth without breaking live agent output. If the
WebSocket returns `401`, the browser has no valid session cookie (log in again); if it returns
`403`, the Host is not in the allowlist or the Origin is not the request authority.
