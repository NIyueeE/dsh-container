# Security Notes

dsh's agents can execute arbitrary commands inside the container — remote code execution is its
day job — so follow this baseline when running it:

## Networking & exposure

`dsh web` listens on `127.0.0.1` by default, and upstream dsh rejects
`--host 0.0.0.0` (an intentional upstream safety design: without an auth layer it would expose
remote code execution to the network). This image exposes the UI through a **Caddy reverse proxy**
(`0.0.0.0:3081` → `127.0.0.1:3080`), and the orchestration examples publish the proxy on host
loopback (`127.0.0.1:3081`) — LAN/public exposure is an explicit step (change the publish line, or
put a host-side proxy in front). The proxy passes SSE/WebSocket streams through unbuffered and
restarts itself if it crashes (the container HEALTHCHECK marks it unhealthy while the proxy stays
down; UI assets are gzip-compressed by dsh's own webserver, not the proxy).

### The proxy preserves dsh's security fence

Caddy forwards the browser's `Host` and `Origin` unchanged. dsh's `/api` fence is therefore real,
not bypassed: an external authority is accepted only when it is declared with
`DSH_TRUSTED_HOST` (or derived from `DSH_PUBLIC_URL`), and Caddy's Host allowlist rejects every
other Host with `403` before the request reaches dsh. That Host check is what stops DNS rebinding;
`DSH_TRUSTED_HOST` is the explicit trust declaration for the deployment, not a hidden rewrite.

Upstream also requires a browser session: `dsh web` prints a one-time `?token=...` login URL and
mints a signed session cookie from it (30 days by default, backed by a signing secret persisted in
`~/.dsh`). The container-adapt plugin writes the process launch token to
`/tmp/dsh-caddy/launch-token`, and Caddy redirects a browser that has no `dsh-auth-*` cookie to
`/?token=...`. dsh then sets `HttpOnly; SameSite=Strict` on the cookie and the browser sends it on
every later request; **the proxy never injects or rewrites the session**. A still-valid browser
cookie survives `dsh-restart` and container restarts because the signing secret lives on the
volume. When the 30-day cookie expires, the next visit is redirected to the launch token again.

The launch token is a process credential and is also printed by `dsh web` into the container log;
treat container logs as sensitive. Caddy's startup-failure path no longer prints the Caddyfile,
because that file contains the token.

Access control still lives at the proxy/network edge:

- anyone who can reach port `3081` can complete the login and gets a fully authenticated session;
  enable basic auth (`DSH_PROXY_USER` + `DSH_PROXY_PASSWORD`, set together or the supervisor refuses
  to start) for any non-loopback deployment, or put the port behind a VPN/authenticated proxy;
- `/api/remote.mux` (the WebSocket upgrade) is exempt from basic auth because browsers do not
  reliably attach `Authorization` to WebSocket handshakes; it is authenticated by the browser's
  `SameSite=Strict` session cookie, which a cross-site page cannot send. All other paths still
  require basic auth when it is configured;
- dsh itself binds `127.0.0.1:3080`, and that port is not published. Caddy on `0.0.0.0:3081` is the
  only path into the container; a direct request to `127.0.0.1:3080` from inside the container
  still gets `401` without the session cookie;
- `3081` is plain HTTP. Terminate TLS in front of it (the docs include an nginx example); the outer
  proxy must also add `Secure` to the cookie (`proxy_cookie_flags ~ secure`), because dsh sees HTTP.

`DSH_PUBLIC_URL` is advertisement only: it sets the printed/agent-visible URL and the initial
launch-token URL, and it grants no trust. The browser-visible authority must still be named by
`DSH_TRUSTED_HOST` (the image derives it from `DSH_PUBLIC_URL` when the variable is unset).

The settings-document affordance is gated on the page authority: the browser creates its
controller only when `$host.isLoopback` is true (loopback access such as an SSH tunnel). On such a
page the container-adapt plugin forces `hasDocument: false`, and remote authorities do not create
the controller at all. The proxy preserves Host/Origin and does not inject `__DSH_TRANSPORT__`.

The same plugin keeps the headless-hostile settings-document affordance out of the UI:
upstream's "Open config file" would spawn the native text-editor command into nothing in a
container. The plugin wraps the settings controller's `describe` method so `settings/describe`
reports `hasDocument: false`, so the browser never renders the button. No download endpoint exists
— settings live on the mounted volume under `~/.dsh` (upstream v0.1.7+ keeps them in the active
profile's plugin configuration, `~/.dsh/profiles/<profile>/cordis.patch.yml`, with the legacy
`settings.yaml` imported once), and only the user who mounts the volume and uid 1000 can read it.

Consequences:

- **Enable basic auth** on the proxy for any non-loopback deployment (set both variables; a
  half-configured auth block must never silently start open). Without it, anyone who can reach
  `3081` can log in.
- Keep the host firewall closed for `3081` unless LAN access is actually needed; for anything beyond
  the LAN, put an authenticated TLS reverse proxy (e.g. Caddy + basic auth) or an SSH tunnel in
  front — there is still no TLS on `3081` itself.
- **DeepSeek account sign-in still requires a loopback browser origin.** The browser hands
  `window.location.origin` to dsh and the platform only accepts `http://localhost:<port>`,
  `http://127.0.0.1:<port>`, or `http://[::1]:<port>`; a public `https://` hostname is rejected
  before the platform is contacted. Use an SSH tunnel ending at `http://localhost:3081` for
  account sign-in; API-key/model use works over any exposure. `DSH_PUBLIC_URL` does not change this.
- Keep the host-side exposure minimal: the examples already bind to host loopback
  (`127.0.0.1:3081:3081`) — don't loosen that unless you mean to expose the port.

## Telemetry is off by default

dsh ships an OTel-based feedback uploader. With the upstream default
(`DSH_TELEMETRY_MODE=FEEDBACK_ONLY`), clicking 👍/👎 on a message exports the complete canonical
session prefix up to that feedback — message text, tool arguments and results, and workspace paths
included — to `https://harness-telemetry.deepseeksvc.com/v1/logs`, regardless of the model
provider.

This image defaults to **`DSH_TELEMETRY_MODE=DISABLED`** (set by the entrypoint): nothing leaves
the container **through the OTel paths**, and clicking feedback records it in the session log while
printing a one-line "not uploaded through OpenTelemetry" warning. To opt back in, pass
`DSH_TELEMETRY_MODE=FEEDBACK_ONLY` (or point `DSH_TELEMETRY_OTLP_URL` at your own collector); a
non-empty `DSH_TELEMETRY_DISABLED` disables the row entirely (`FULL` is rejected upstream).

**This switch does not cover the DeepSeek session-log contributor.** Upstream ships
`session-log-deepseek` mounted with `enabled: true` — independently of `DSH_TELEMETRY_MODE` — so
when you talk to the DeepSeek API (the default provider), complete unaccepted session-log suffixes
(message text, tool arguments and results, workspace paths) are attached to those requests,
including through a configured gateway. If you use a non-DeepSeek provider it never fires; if you
want it off while using DeepSeek, set `enabled: false` on the `session-log-deepseek` entry in the
active profile's plugin configuration (`~/.dsh/profiles/<profile>/cordis.patch.yml`) and restart
dsh web. The image deliberately does not disable it for you — it is part of the DeepSeek API
protocol, and upstream's own docs describe it as default-on.

## Don't mount host credentials

Avoid bind-mounting `~/.ssh`, `~/.aws`, `~/.config/gh`, cloud vendor credentials, etc.
(see the [official Claude Code container security warning](https://code.claude.com/docs/en/devcontainer)).
Agents can read everything reachable inside the container, including mounted credentials.
For the same reason, don't bind-mount the host Docker socket (`/var/run/docker.sock`), and run the
container with `--privileged` only when in-container podman requires it (see "In-container
rootless podman"): either gives the agent a straightforward path to the host's root account.

## Container-internal privileges

The Debian slim image gives uid 1000 passwordless `sudo` via the `sudo` group
(`%sudo ALL=(ALL) NOPASSWD:ALL`), so `USER 1000` is not a privilege boundary inside the container.
Treat the container root as reachable by the agent; for stricter sandboxes, remove that sudoers
entry or use an additional isolation layer (user namespace, VM, etc.).

## In-container rootless podman

The image installs podman (with `crun`, `fuse-overlayfs`, `slirp4netns`, `uidmap`) and configures
subuid/subgid for uid 1000 (exactly one range per file — duplicates break `newuidmap`), and it
prepares the runtime environment itself: the entrypoint provisions a writable
`XDG_RUNTIME_DIR` (rootless podman cannot start without one), and
`/etc/containers/containers.conf` presets `slirp4netns` as the rootless network command and
empties `default_sysctls`. The inner podman runs the **standard rootless flow** — it creates its
own user namespace with `unshare` + `newuidmap`; the image deliberately does *not* set
`_CONTAINERS_USERNS_CONFIGURED`, which on podman 5.x would skip that step and leave the runtime
half-initialized (nil-pointer panics on every store-touching command).

Whether `podman run` actually succeeds still depends on the host: unprivileged user namespaces and
`/dev/fuse` must be allowed (plus `/dev/net/tun` for default rootless networking), the seccomp
profile must permit the inner `unshare(2)`, and — the podman 5.x requirement — the container's
`/proc` must not carry masked or read-only submounts, because crun mounts a fresh `/proc` inside
the nested container and the kernel only allows that in a user namespace when `/proc` is fully
visible (`--security-opt unmask=ALL`, Quadlet `Unmask=ALL`, Docker
`--security-opt systempaths=unconfined`); Docker
Desktop does not support it at all. Treat in-container podman as an experimental
in-container dev tool, not a guaranteed isolation primitive — and note that the host flags which
enable it (`--privileged`, unconfined seccomp, the unmasked `/proc`) weaken the container boundary
itself, so enable them only when nested containers are actually needed. See
[deployment.md](deployment.md) § In-container podman for the full host matrix and the
rootful/`vfs` fallbacks.

## `~/.dsh` holds API keys

The persisted `/home/dsh` volume contains `~/.dsh` — model API credentials, profiles and
session data — plus `~/.cargo`, pnpm store/cache, dotfiles, and folders created by dsh under `$HOME`.
Mind the volume's access permissions and backups; don't share it with untrusted containers.

## Only run trusted repositories

Even with the approval mechanism in place, don't let agents process untrusted code repositories.

## Build-time source trust

The image builds dsh from the official `deepseek-ai/deepseek-harness` repository at a pinned
`dsh-v*` tag. Runtime updates happen only by replacing the image; the container does not run a
boot-time package update. Treat the upstream repository and its pnpm dependency tree as the
supply-chain trust boundary.

## Remote access

By default the proxy is published on host loopback only (`127.0.0.1:3081`) — other machines cannot
reach it, and serving them is an explicit step. When you do:

- **plain LAN publishing** (`"3081:3081"`): enable basic auth and keep the port behind the host
  firewall when unused;
- **public HTTPS** (a host-side nginx in front): keep the container port on loopback and follow
  [deployment.md](deployment.md) "Public deployment (nginx in front)" — rate limiting/banning and
  basic auth both stay on;
- **or don't expose at all**: an SSH tunnel (`ssh -L 3081:127.0.0.1:3081 ...`) or a VPN
  (WireGuard/Tailscale) is the strongest option for a single user. It is also the only exposure
  mode in which DeepSeek **account sign-in** works: upstream accepts a loopback browser origin only,
  so the tunnel has to end in the browser and be reached as `http://localhost:3081` (see
  [deployment.md](deployment.md) § DeepSeek account sign-in);
- if you front it with an external reverse proxy, forward the WebSocket upgrade headers
  (`Upgrade`/`Connection`) and raise the idle timeouts — without them the UI's event streams
  silently fail (see [deployment.md](deployment.md) for a working nginx example).
