# Upstream Contract

This document is the machine-checkable statement of **what this image depends on from upstream
dsh**. It has two consumers:

- `tests/contract.sh` — the executable form: statically greps an upstream tag for every critical
  item below in seconds, before any image is built. Release preparation runs it first; any `MISS`
  means compatibility drift.
- The release-prep agent (`.github/workflows/release-prep.yml`) — when drift is detected, the agent
  reads this document, compares it against the upstream diff, and repairs this repository (usually
  by updating the patch anchors in `container/dsh-client-patch.sh`).

Behavioral assertions (login flow, fence responses, proxy behavior) are enforced end-to-end by
`tests/smoke.sh` after the image is built. The two layers are complementary: contract.sh decides
*early* whether an upstream tag can be released as-is; smoke.sh is the hard gate that nothing
bypasses.

When a contract item changes, update **all three** of: this document, `tests/contract.sh`, and the
affected enforcement point in `container/*.sh`.

## Critical items (checked by `tests/contract.sh`)

| # | Item | Upstream location (`dsh-v0.1.2-rc.1`) | Why this image needs it | Enforcement |
|---|---|---|---|---|
| 1 | Browser-side `isLoopback` gate compiled from `isLoopback: transport?.ownsHost === true \|\| pageLocation === undefined \|\| isLoopbackHostname(pageLocation.hostname)` | `packages/client/connection/src/client/index.ts:228` | `dsh-client-patch.sh` rewrites the built form (`pageLocation === void 0`) to `isLoopback: true` so remote browsers can use settings/credentials; if the expression changes shape the patch silently skips | `contract.sh connection.isLoopback.source` (static) + smoke bundle assertions (behavioral) |
| 2 | `index.html` module-script anchor `<script type="module"` | `apps/web/index.html` | `dsh-client-patch.sh` injects the `crypto.randomUUID` polyfill immediately before the first module script | `contract.sh web.index.anchor` + smoke polyfill assertions |
| 3 | Header-based `/api` trust fence (checks `Host`/loopback/`trustedHosts`, `Origin`, `sec-fetch-site`) | `packages/client/connection/src/api-request-trust.ts` | The Caddy proxy rewrites `Host`/`Origin` to loopback and is the only exposure path; the whole remote-access design assumes the fence inspects headers, never TCP source | `contract.sh server.request_fence` + smoke 200/401 assertions on `/api/settings/describe` |
| 4 | `dsh web` accepts `--port` | `apps/cli` arg pass-through (spec in `apps/cli/tests/args.spec.ts`) | `container/entrypoint.sh` parses `--port` and forwards it; upstream rejects `--host 0.0.0.0` by design, which the image works with (loopback + proxy) | `contract.sh cli.port` |
| 5 | `dsh web` accepts `--no-open` | same | `container/dsh-web.sh` appends `--no-open` (the container has no browser) | `contract.sh cli.no-open` |

Notes:

- Upstream has **no literal `PRIVILEGED_METHODS` identifier** — that is this repository's name for
  the set of privileged methods (`settings/describe`, `settings/update`, `credentials.*`,
  `agentPreset.*`, `host.pickDirectory`/`host.openPath`, `llm.discoverModels`) that the fence pins
  to loopback via an empty trust list. Their reachability through the proxy is verified
  behaviorally by smoke, not by a string check.
- `connection.isLoopback.built` (the exact built candidate string) is checked only when the
  upstream checkout contains `packages/client/connection/lib/client.js`; source builds compile
  `lib/` during image build, so the built form is verified by smoke against the served bundle.

## Warning-level items (never fail the check)

| Item | Meaning when present |
|---|---|
| `web.token_url` (`token=` in source) | Informational; the one-time login URL flow is verified behaviorally by smoke (token extraction → `303` cookie exchange → session works) |
| `web.trustedHosts` | Server-side only (item 3): non-loopback authorities accepted by the fence. Does not affect the browser-side gate patched by item 1, but the agent should confirm that during drift review |

## Behavioral contract (verified by `tests/smoke.sh`, not statically checkable)

1. `dsh web` prints a one-time `?token=...` login URL; exchanging it through the proxy returns
   `303` and sets the signed session cookie; the signing secret persists in the volume so sessions
   survive `dsh web` restarts.
2. With the cookie injected by Caddy, `/` and privileged methods return `200` through `:3081`;
   direct `:3080` access without a cookie returns `401` (the fence is not bypassed).
3. The served connection bundle contains the `isLoopback: true` patch and no longer contains the
   original gate; the served `index.html` contains the polyfill — including after `dsh-restart`.
4. Data lives at upstream's default `~/.dsh`; the agent workspace is the process cwd
   (`$HOME` in the container).

## Anticipated tightening scenarios

The remote-access model depends on one invariant: **dsh's server-side trust can be satisfied by
header rewriting from a loopback proxy.** If upstream evolves its security design in ways that
attack that invariant, the response is a design negotiation (an upstream issue/PR or an image-side
redesign), never a patch. The matrix below records how each anticipated tightening is detected and
who owns the response — review it whenever upstream ships a breaking release.

| Upstream tightening | Detection layer | Automated response | Resolution owner |
|---|---|---|---|
| New explicit trust switch / deployment-mode env | `contract.sh` (new form of item 3) | agent aligns entrypoint/contract once the contract is updated | agent + contract update |
| CLI flags / ports / login-flow changes | `contract.sh` items 4–5 → MISS | agent reports HOLD (security posture, no workaround) | human |
| Fence moves to transport-level trust (unix socket, `SO_PEERCRED`, shared secret) | `contract.sh` item 3 → MISS; behaviorally the smoke 200/401 assertions fail | verify fails → release refused → diagnostics on the tracker issue | human (redesign: Caddy mTLS / unix socket, or an upstream trusted-proxy proposal) |
| Client bundle integrity checks (SRI / startup checksum) | smoke bundle assertions (static checks may pass — the source form is unchanged) | verify fails → release refused | human (patch script must maintain checksums) |
| Session cookie bound to client fingerprint | smoke session assertions | verify fails → release refused | human |
| Bundling/minification makes anchor strings unstable | `contract.sh` MISS (existing mechanism) | agent derives the new built form | agent |

Notes:

- A fence that moves to **TCP source-address checking** does *not* break this image: Caddy and dsh
  share the container network namespace, so Caddy's connection to `127.0.0.1:3080` originates from
  loopback and passes source-address checks unchanged. The class that header rewriting cannot
  satisfy is **cryptographic binding** (signed cookies tied to non-forwardable state, mTLS,
  per-request HMAC).
- Tightening of this kind is upstream's security intent evolving — the mode this image relies on (a
  same-host proxy rewriting headers to loopback) is exactly what such a design defends against.
  Patching around it would be a security anti-pattern; the correct paths are an upstream
  trusted-proxy proposal or an image-side redesign.
- Detection coverage: every behavioral assertion the smoke suite makes today (proxied 200 / direct
  401, bundle patch, session survival, `no-store`) maps to a row above. If a future tightening
  affects behavior outside these assertions, neither detection layer sees it — that is what the
  human review of this matrix is for.

## Update protocol

When `contract.sh` reports drift for a new upstream tag:

1. Read the upstream diff (or checkout) and identify which contract item changed and why.
2. If it is item 1 or 2: derive the new built-form string and update the candidate list in
   `container/dsh-client-patch.sh` (keep old candidates if they are merely extended, and keep the
   header note about the verified upstream revision).
3. If it is item 3–5: do **not** improvise a workaround; report the drift for human review — these
   define the image's security posture.
4. Update this document and `tests/contract.sh` so both describe the new reality.
5. `tests/smoke.sh` remains the final gate: if behavior broke in a way the static checks cannot
   see, the release still stops there.
