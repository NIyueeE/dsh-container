# Security Notes

dsh's agents can execute arbitrary commands inside the container — remote code execution is its
day job — so follow this baseline when running it:

## Why host networking?

`dsh web` deliberately **refuses to bind `0.0.0.0`** (to avoid exposing remote code execution to the
network) and only listens on `127.0.0.1`. Both orchestration examples therefore use host networking:
the service appears directly on the host at `http://127.0.0.1:3080`, with no port mapping needed or
supported. Host networking is Linux-only (not available on Docker Desktop for macOS/Windows).

For remote access, use an SSH tunnel or a host-side reverse proxy — never change the bind address.
See the "Remote access" section of [deployment.md](deployment.md).

## Don't mount host credentials

Avoid bind-mounting `~/.ssh`, `~/.aws`, `~/.config/gh`, cloud vendor credentials, etc.
(see the [official Claude Code container security warning](https://code.claude.com/docs/en/devcontainer)).
Agents can read everything reachable inside the container, including mounted credentials.

## DSH_HOME holds API keys

The `dsh-home` volume contains model API credentials and session data. Mind the volume's access
permissions and backups; don't share it with untrusted containers.

## Only run trusted repositories

Even with the approval mechanism in place, don't let agents process untrusted code repositories.

## Remote access only via SSH tunnel

The 127.0.0.1-only listener is a security design, not a limitation. If you must expose the service
beyond localhost, put an authenticated reverse proxy (e.g. Caddy + basic auth) on the host and
consider dsh's `--trusted-host` option.
