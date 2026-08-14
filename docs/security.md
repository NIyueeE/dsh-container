# Security Notes

dsh's agents can execute arbitrary commands inside the container — remote code execution is its
day job — so follow this baseline when running it:

## Networking & exposure

`dsh web` listens on `127.0.0.1` by default, and the npm releases reject `--host 0.0.0.0`
(upstream main supports an explicit all-interface opt-in, but it is not published yet). This image
exposes the UI anyway by running a small **socat forwarder** (`0.0.0.0:3080 → 127.0.0.1:3080`)
when `DSH_WEB_HOST=0.0.0.0` (the default), and the orchestration examples publish port `3080` on
plain bridge networking.

There is no TLS or authentication, so anyone who can reach port `3080` can drive the agent — remote
code execution. This is an intentional design decision: the UI is reachable from the LAN out of the
box, at the cost of network exposure — the host firewall is the first line of defense. Two ways to
tighten it:

- keep the published port host-only: `127.0.0.1:3080:3080` (compose) /
  `PublishPort=127.0.0.1:3080:3080` (quadlet);
- restore loopback-only inside the container: `DSH_WEB_HOST=127.0.0.1` (no forwarder) — port
  mapping then no longer works, so you need host networking or a tunnel/forwarder (see
  [deployment.md](deployment.md)).

## Don't mount host credentials

Avoid bind-mounting `~/.ssh`, `~/.aws`, `~/.config/gh`, cloud vendor credentials, etc.
(see the [official Claude Code container security warning](https://code.claude.com/docs/en/devcontainer)).
Agents can read everything reachable inside the container, including mounted credentials.

## DSH_HOME holds API keys

The `dsh-home` volume contains model API credentials and session data. Mind the volume's access
permissions and backups; don't share it with untrusted containers.

## Only run trusted repositories

Even with the approval mechanism in place, don't let agents process untrusted code repositories.

## Remote access

With bridge networking the service is LAN-reachable by default, so treat it like any network service:

- keep port `3080` closed in the host firewall unless LAN access is actually needed;
- for anything beyond the LAN, put an authenticated reverse proxy (e.g. Caddy + basic auth) on the
  host, or use an SSH tunnel — don't rely on the raw port;
- when browsers access the UI from other machines, the `/api` browser-trust fence may require
  `--trusted-host <host>:3080` (pass it via the container `command` / `Exec=--trusted-host ...`).
