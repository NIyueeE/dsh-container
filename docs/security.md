# Security Notes

dsh's agents can execute arbitrary commands inside the container — remote code execution is its
day job — so follow this baseline when running it:

## Networking & exposure

`dsh web` listens on `127.0.0.1` by default, and both the npm releases and upstream main reject
`--host 0.0.0.0` (an intentional upstream safety design: without an auth layer it would expose
remote code execution to the network). This image exposes the UI through a **Caddy reverse proxy**
(`0.0.0.0:3081` → `127.0.0.1:3080`), and the orchestration examples publish port `3081` on plain
bridge networking. The proxy gzip-compresses UI assets, passes SSE/WebSocket streams through
unbuffered, and restarts itself if it crashes (the container HEALTHCHECK marks it unhealthy while
the proxy stays down).

### The proxy is the security boundary

The proxy rewrites the `Host` and `Origin` headers to loopback before forwarding. dsh's `/api`
browser-trust fence checks **HTTP headers only** (it never looks at the connection's source
address), so from dsh's point of view every proxied request comes from `127.0.0.1` and passes every
endpoint — **including the settings/credentials methods that upstream deliberately pins to
loopback** (`settings.*`, `credentials.*`, `agentPreset.*`, `host.pickDirectory`/`host.openPath`,
`llm.discoverModels`). This is intentional: it makes remote access fully functional, but it means
**the fence's loopback pin no longer protects anything** — whoever can reach port `3081` can read
and modify all configuration and API credentials, not just drive the agent.

Consequences:

- **Enable basic auth** on the proxy by setting both `DSH_PROXY_USER` and `DSH_PROXY_PASSWORD`
  (recommended for any non-loopback deployment). The entrypoint refuses to start when only one is
  set — a half-configured auth block must never silently start open. Without auth, anyone who can
  reach `3081` gets full control — same exposure as before, plus settings/credentials.
- Keep the host firewall closed for `3081` unless LAN access is actually needed.
- For anything beyond the LAN, put an authenticated reverse proxy (e.g. Caddy + basic auth) or an
  SSH tunnel in front — don't rely on the raw port; there is still no TLS on `3081` itself.
- Keep the host-side exposure minimal: bind to host loopback (`127.0.0.1:3081:3081`) or don't
  publish the port at all (container-only).

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
session data — plus `~/.cargo`, npm cache, dotfiles, and folders created by dsh under `$HOME`.
Mind the volume's access permissions and backups; don't share it with untrusted containers.

## Only run trusted repositories

Even with the approval mechanism in place, don't let agents process untrusted code repositories.

## Auto-update trust

`DSH_AUTO_UPDATE=1` is opt-in (default `0`). It runs an npm global install with install scripts on
every boot, and uid 1000 can escalate to root inside the container via passwordless sudo. For
untrusted networks or long-running production deployments, keep auto-update off and pin
`DSH_VERSION` at build time, or at least treat npm registry access as a supply-chain trust
boundary.

## Remote access

With bridge networking the service is LAN-reachable by default, so treat it like any network service:

- keep port `3081` closed in the host firewall unless LAN access is actually needed;
- for anything beyond the LAN, put an authenticated reverse proxy (e.g. Caddy + basic auth) on the
  host, or use an SSH tunnel — don't rely on the raw port;
- if you front it with an external reverse proxy, forward the WebSocket upgrade headers
  (`Upgrade`/`Connection`) and raise the idle timeouts — without them the UI's event streams
  silently fail (see [deployment.md](deployment.md) for a working nginx example);
- enable the proxy's own basic auth (`DSH_PROXY_USER` / `DSH_PROXY_PASSWORD`) for any
  non-loopback deployment; remote browsers then get full functionality, including settings and
  credentials.
