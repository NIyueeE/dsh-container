# Security Notes

dsh's agents can execute arbitrary commands inside the container — remote code execution is its
day job — so follow this baseline when running it:

## Networking & exposure

`dsh web` listens on `127.0.0.1` by default, and upstream dsh rejects
`--host 0.0.0.0` (an intentional upstream safety design: without an auth layer it would expose
remote code execution to the network). This image exposes the UI through a **Caddy reverse proxy**
(`0.0.0.0:3081` → `127.0.0.1:3080`), and the orchestration examples publish the proxy on host
loopback (`127.0.0.1:3081`) — LAN/public exposure is an explicit step (change the publish line, or
put a host-side proxy in front). The proxy gzip-compresses UI assets, passes SSE/WebSocket streams
through unbuffered, and restarts itself if it crashes (the container HEALTHCHECK marks it unhealthy
while the proxy stays down).

### The proxy is the security boundary

The proxy rewrites the `Host` and `Origin` headers to loopback before forwarding. dsh's `/api`
browser-trust fence checks **HTTP headers only** (it never looks at the connection's source
address), so from dsh's point of view every proxied request comes from `127.0.0.1` and passes the
trust fence — **including the settings/credentials methods that upstream deliberately pins to
loopback** (`settings/describe`, `settings/update`, `credentials.*`, `agentPreset.*`,
`host.pickDirectory`/`host.openPath`, `llm.discoverModels`).

Upstream also requires a browser session: `dsh web` prints a one-time `?token=...` login URL and
mints a signed session cookie from it (30 days by default, backed by a signing secret persisted in
`~/.dsh`). This image absorbs that flow entirely at the proxy: on every container start the
supervisor (`dsh-web`) exchanges the printed token against `127.0.0.1:3080` itself and configures
Caddy to inject the resulting session cookie into every proxied request. Browsers never see a
token — opening `3081` is enough and there is no 401/login step left on the proxy path.
Authentication therefore lives **only** in Caddy (basic auth, or the network exposure you choose):

- anyone who can reach port `3081` gets a fully authenticated session — enable basic auth
  (`DSH_PROXY_USER` + `DSH_PROXY_PASSWORD`, set together or the supervisor refuses to start) for
  any non-loopback deployment;
- reading the container logs no longer grants anything extra — there is no token to fish out;
- dsh's own fence is untouched behind the proxy: a direct request to `127.0.0.1:3080` (i.e. a peer
  container on the same Docker network, which bypasses Caddy) still needs the session cookie and
  gets `401` without it — the proxy is the only path in.

Upstream dsh's browser code still gates the settings/credentials pages on `window.location.hostname`,
so the header rewrite and session injection alone would not make those pages usable in a remote
browser. This image therefore runs `dsh-client-patch` before every `dsh web` start: it treats
proxied remote browsers as loopback and injects a `crypto.randomUUID` polyfill for plain-HTTP LAN
use (upstream now ships its own insecure-context `randomUuid()`; the polyfill stays as insurance
for other bundle code). The patch is best-effort and skips with a warning if upstream changes the
bundle strings.

Consequences:

- **Enable basic auth** on the proxy by setting both `DSH_PROXY_USER` and `DSH_PROXY_PASSWORD`
  (recommended for any non-loopback deployment). The supervisor refuses to start when only one is
  set — a half-configured auth block must never silently start open. Without auth, anyone who can
  reach `3081` gets full control — same exposure as before, plus settings/credentials, now without
  even needing the token from the logs.
- Keep the host firewall closed for `3081` unless LAN access is actually needed.
- For anything beyond the LAN, put an authenticated reverse proxy (e.g. Caddy + basic auth) or an
  SSH tunnel in front — don't rely on the raw port; there is still no TLS on `3081` itself.
- Keep the host-side exposure minimal: the examples already bind to host loopback
  (`127.0.0.1:3081:3081`) — don't loosen that unless you mean to expose the port.

## Don't mount host credentials

Avoid bind-mounting `~/.ssh`, `~/.aws`, `~/.config/gh`, cloud vendor credentials, etc.
(see the [official Claude Code container security warning](https://code.claude.com/docs/en/devcontainer)).
Agents can read everything reachable inside the container, including mounted credentials.
For the same reason, don't bind-mount the host Docker socket (`/var/run/docker.sock`) or run the
container with `--privileged`: either gives the agent a straightforward path to the host's root
account.

## Container-internal privileges

The Debian slim image gives uid 1000 passwordless `sudo` via the `sudo` group
(`%sudo ALL=(ALL) NOPASSWD:ALL`), so `USER 1000` is not a privilege boundary inside the container.
Treat the container root as reachable by the agent; for stricter sandboxes, remove that sudoers
entry or use an additional isolation layer (user namespace, VM, etc.).

## In-container rootless podman

The image installs podman and configures subuid/subgid for uid 1000, so the agent can use podman
for nested containers. Whether `podman run` actually works depends on the host runtime: it needs
nested user namespaces and appropriate seccomp/AppArmor settings. Docker's default seccomp profile
or a locked-down Kubernetes runtime may reject the `unshare`/`clone` calls. Treat podman as an
experimental in-container dev tool, not a guaranteed isolation primitive.

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
  (WireGuard/Tailscale) is the strongest option for a single user;
- if you front it with an external reverse proxy, forward the WebSocket upgrade headers
  (`Upgrade`/`Connection`) and raise the idle timeouts — without them the UI's event streams
  silently fail (see [deployment.md](deployment.md) for a working nginx example).
