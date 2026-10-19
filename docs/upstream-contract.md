# Upstream Contract

This document is the machine-checkable statement of **what this image depends on from upstream
dsh**. It has three consumers:

- `tests/contract.sh` — the executable form: statically greps an upstream tag for every critical
  item below in seconds, before any image is built. Release preparation runs it first; any `MISS`
  means compatibility drift.
- `tests/triage-diff.sh` — the code-level agent admission gate: combines the contract verdict with
  the complete upstream changed-file list (`git diff --name-only` between the two tags; the compare
  API caps at 300 files and would miss the adaptation surface) and admits the release-prep agent
  only when the contract drifted (outside the security fence) or the diff touches the adaptation
  surface. Fence drift and mis-dispatched older tags fail the run without an agent.
- The release-prep agent (`.github/workflows/release-prep.yml`) — when drift is detected (or the
  surface is hit), the agent reads this document, compares it against the upstream diff, and
  repairs this repository (usually by re-anchoring a plugin API dependency or the build-time
  post-processing in `container/plugin/`), or exits early with `NO_ACTION_NEEDED`.

Behavioral assertions (login flow, fence responses, proxy behavior) are enforced end-to-end by
`tests/smoke.sh` after the image is built. The two layers are complementary: contract.sh decides
*early* whether an upstream tag can be released as-is; smoke.sh is the hard gate that nothing
bypasses.

**Supported upstream dsh: 0.2.1-alpha.3 and newer.** The image deliberately has no compatibility
layer for older tags; `Containerfile` rejects a `DSH_TAG` below 0.2.1-alpha.3. (alpha.1 and alpha.2
still gate settings persistence on `$host.isLoopback`; the image no longer injects the
`__DSH_TRANSPORT__` row that lifted that gate.) The contract is written against
`dsh-v0.2.1-rc.2` and stays valid for later tags unless a check reports drift.

When a contract item changes, update **all three** of: this document, `tests/contract.sh`, and the
affected enforcement point in `container/*.sh`.

## Critical items (checked by `tests/contract.sh`)

| # | Item | Upstream location (`dsh-v0.2.1-rc.2`) | Why this image needs it | Enforcement |
|---|---|---|---|---|
| 1 | Header-based `/api` trust fence (checks `Host`/loopback/`trustedHosts`, `Origin`, `sec-fetch-site`) | `packages/client/connection/src/api-request-trust.ts` | Caddy preserves the browser `Host`/`Origin` and is the only exposure path; `dsh-web` passes `--trusted-host` for the authorities derived from `DSH_PUBLIC_URL`/`DSH_TRUSTED_HOST`, and Caddy rejects any other Host with `403` before the request reaches dsh. The index token exchange itself does not apply the API fence, so the proxy-side Host allowlist is mandatory. The image never rewrites Host/Origin or injects cookies | `contract.sh server.request_fence` + `server.trusted_hosts` + smoke 200/401/403 assertions |
| 2 | `dsh web` accepts `--port`, `--trusted-host`, and `--public-url` | `apps/cli` arg pass-through + `packages/bundle/web-app/src/startup.ts` | `container/entrypoint.sh` parses `--port`; `container/dsh-web.sh` adds `--trusted-host` for each configured authority and always passes `--public-url` (0.2.1-alpha.3 is the minimum supported tag). dsh still binds `127.0.0.1`; upstream rejects `--host 0.0.0.0` by design | `contract.sh cli.port` + `cli.trusted-host` + `web.public_url` |
| 3 | `dsh web` accepts `--no-open` | same | `container/dsh-web.sh` appends `--no-open` (the container has no browser) | `contract.sh cli.no-open` |
| 4 | `dsh` launcher accepts root `--patch <file>` (used as `--patch <overlay> --profile web`; the `web` alias rejects parent flags by design) | `apps/cli/src/args.ts` | `container/dsh-web.sh` mounts the plugin overlay with the root flag combination — the `web` alias would be rejected by `rejectParentOptions` | `contract.sh cli.patch` |
| 5 | `Connection.authenticatedUrl()` (process launch token) | `packages/client/connection/src/rpc.ts` | The container-adapt plugin reads the process launch token from it and writes `/tmp/dsh-caddy/launch-token`; Caddy redirects a browser without a session cookie to `/?token=...`, and dsh sets the browser-held session cookie. `ctx.webServer.port` is the other dependency | `contract.sh plugin.authenticated_url` + smoke login-redirect/token assertions |
| 6 | `settings/describe` hardcodes `hasDocument: true`, and the browser `SettingsDocumentAction` renders nothing unless its describe mirror reports `hasDocument: true` | `packages/api/settings-controller/src/index.ts` + `packages/client/ui-settings-general/src/client/SettingsDocumentAction.tsx` | The container-adapt plugin wraps the `settingsController` instance's `describe` so it reports `hasDocument: false` (Gateway resolves remote methods dynamically at invoke time — `Reflect.get(callReceiver, 'describe')` + `Reflect.apply` — so an instance property shadowing the prototype works). The headless-hostile "Open settings document" button (no upstream fallback; would spawn the native text-editor command into nothing) never renders — no client code, no download endpoint | `contract.sh plugin.settings_document_hidden` + `plugin.settings_action_gate` + smoke describe/gone-endpoint assertions |
| 7 | `session-telemetry-otel` reads its `mode` from `process.env.DSH_TELEMETRY_MODE` (upstream default `FEEDBACK_ONLY`) | `packages/bundle/base/cordis.patch.yml` | `container/entrypoint.sh` defaults `DSH_TELEMETRY_MODE=DISABLED` so nothing leaves the container unless the user opts in; if upstream renames the variable or stops wiring it, that default silently stops working and the upstream default (upload the session prefix on explicit feedback) applies | `contract.sh telemetry.default_off` |

Notes:

- Upstream has **no literal `PRIVILEGED_METHODS` identifier**. The current fence is
  authority-based, not method-based: `--trusted-host` admits an external authority for every
  `/api` method, and the proxy does not bypass the fence by rewriting Host/Origin. The behavior
  is verified by smoke (200 with a browser cookie + trusted Host, 401/403 without).
- The index token exchange (`/?token=...`) does not run the `/api` fence. Caddy's Host allowlist
  therefore rejects an untrusted Host **before** the login redirect; without that, a DNS-rebinding
  page could obtain a cookie for its own authority (useless for the API, but still a credential).
- The remaining plugin dependencies are upstream API shapes, not built bundle strings. The client
  bundles are upstream artifacts after this image's build post-processing (large inline images
  extracted, esbuild minification), which is also why the delivered build record must match the
  delivered artifacts (`refresh-build-record.mjs` after both steps).

## Warning-level items (never fail the check)

| Item | Meaning when present |
|---|---|
| `web.token_url` (`token=` in source) | Informational; the one-time login URL flow is verified behaviorally by smoke (token extraction → `303` Set-Cookie → browser session works) |

## Behavioral contract (verified by `tests/smoke.sh`, not statically checkable)

1. `dsh web` prints a one-time `?token=...` login URL. The container-adapt plugin (mounted via
   `dsh --patch /opt/dsh-container-plugin/overlay.yml --profile web`) writes the process launch
   token to `/tmp/dsh-caddy/launch-token` as a state file. `dsh-web.sh` waits only for that file,
   generates a Caddyfile whose Host allowlist/redirect uses it, and `caddy reload`s when the token
   changes. Caddy redirects a request without a `dsh-auth-*` cookie to `/?token=...`; dsh mints the
   `HttpOnly; SameSite=Strict` cookie and the browser holds it. A still-valid browser cookie
   survives `dsh-restart` and `docker restart` because the signing secret persists in the volume;
   the new process token only seeds the next login. The smoke test covers `dsh-restart`, a
   `docker restart`, old-cookie survival, token rotation, and a 130 s liveness window (issue #12).
2. With a browser-held cookie, `/` and `/api/settings/describe` return `200` through `:3081`;
   without a cookie they return `401`; a Host outside the allowlist returns `403`; an Origin that
   is not the request authority returns `403`; direct `:3080` without a cookie returns `401`.
   The index is served at **two** entry paths — the dist root `/` and the configured index path
   `/index.html` — and both must carry `Cache-Control: no-store` (the served index is the dynamic
   boot manifest: its inline bundle URLs and `rev` change every image upgrade, so a cached entry
   would run the old frontend against the new server).
3. Nothing in the served index is rewritten. The image does **not** inject
   `__DSH_TRANSPORT__`; minimum supported dsh is 0.2.1-alpha.3, and the only remaining `isLoopback`
   consumer is the settings-document controller, which `hasDocument: false` already hides.
   Upstream's own insecure-context `randomUuid()` is used as-is; no polyfill is injected.
4. The served client bundles are minified and contain no inline image ≥ 100 KiB: the eight account
   onboarding illustrations are served from `/container-assets/<content-hash>` with `immutable`
   caching, and the delivered `.dsh-build` record matches the delivered artifacts.
5. `settings/describe` reports `hasDocument: false` (the plugin wraps the controller's
   `describe`), so the browser never renders the "Open settings document" button;
   `/download/settings.yaml` is served by nothing — the path falls through to the SPA fallback
   (HTML, never an attachment).
6. Data lives at upstream's default `~/.dsh`; the agent workspace is the process cwd
   (`$HOME` in the container).

## Anticipated tightening scenarios

The remote-access model depends on one invariant: **the proxy preserves the browser
`Host`/`Origin`, and dsh admits the browser-visible authority through `--trusted-host`; the browser
holds the session cookie.** If upstream evolves its security design in ways that attack that
invariant, the response is a design negotiation (an upstream issue/PR or an image-side redesign),
never a patch. The matrix below records how each anticipated tightening is detected and who owns
the response — review it whenever upstream ships a breaking release.

| Upstream tightening | Detection layer | Automated response | Resolution owner |
|---|---|---|---|
| New explicit trust switch / deployment-mode env | `contract.sh` (new form of item 1) | agent aligns entrypoint/contract once the contract is updated | agent + contract update |
| CLI flags / ports / login-flow changes | `contract.sh` items 2–3 → MISS | agent reports HOLD (security posture, no workaround) | human |
| Fence moves to transport-level trust (unix socket, `SO_PEERCRED`, shared secret) | `contract.sh` item 1 → MISS; behaviorally the smoke 200/401 assertions fail | verify fails → release refused → diagnostics on the tracker issue | human (redesign: Caddy mTLS / unix socket, or an upstream trusted-proxy proposal) |
| Client bundle integrity checks (SRI / startup checksum) | smoke payload assertions (static checks may pass — the source form is unchanged) | verify fails → release refused | human (the build post-processing must preserve or recompute whatever the check covers) |
| Session cookie bound to client fingerprint | smoke session assertions | verify fails → release refused | human |
| Client build/concatenation changes break post-processing | smoke payload assertions | agent re-anchors the build-time post-processing | agent |

Notes:

- A fence that moves to **TCP source-address checking** does *not* break this image: Caddy and dsh
  share the container network namespace, so Caddy's connection to `127.0.0.1:3080` originates from
  loopback and passes source-address checks unchanged. Cryptographic binding (signed cookies tied
  to non-forwardable state, mTLS, per-request HMAC) is different: the browser-held cookie is still
  the browser's credential, but the proxy would have to carry whatever proof the design adds; that
  is a redesign, not a header fix.
- Tightening of this kind is upstream's security intent evolving — the proxy now preserves the
  browser authority and the browser holds the session, which is the upstream model; a design that
  requires the proxy to forge or rewrite auth is exactly what this image no longer does. Patching
  around it would be a security anti-pattern; the correct paths are an upstream trusted-proxy
  proposal or an image-side redesign.
- Detection coverage: every behavioral assertion the smoke suite makes today (302 login redirect /
  cookie 200 / direct 401 / untrusted-Host 403 / untrusted-Origin 403, payload post-processing,
  session survival, `no-store`) maps to a row above. If a future tightening affects behavior
  outside these assertions, neither detection layer sees it — that is what the human review of this
  matrix is for.

## Simplification triggers

The image keeps its adaptation surface (the hack layer) as small as upstream allows. The
**release-prep agent reviews this table against the upstream diff whenever the code-level triage
admitted it** (contract drift or adaptation-surface hits) — a simplification opportunity is
taken whenever an upstream change makes one of these hacks redundant, and the outcome is recorded
in the release note (the commits themselves) and the tracker issue (the Adaptation review).

| Our adaptation | Upstream change that simplifies it | How to detect | Simplification action |
|---|---|---|---|
| Build post-processing: `extract-inline-assets.js` (large inline images → served files) + `minify-client.mjs` (esbuild) | Upstream emits large image assets as files instead of inlining them, or minifies its own client bundles | grep an upstream client bundle for `data:image/…;base64` blobs; check the client build config for a minifier | Drop the now-redundant script + its Containerfile step and relax the matching smoke assertion (the "no inline image ≥ 100 KiB" assertion stays as long as it holds) |
| Caddy launch-token login redirect (plugin `launch-token` writer + Caddy `redir`) | Upstream ships a headless/auto-login session mechanism (static cookie file / `--session-cookie`-style flag / pre-seeded signing secret), or a stable login URL that needs no token file | grep upstream CLI flags and connection startup for non-browser auth entry points | Drop the token writer and Caddy redirect; let users open the printed token URL (or the official mechanism); simplify `dsh-web.sh` state/reload |
| Hidden settings-document button (`describe` wrapper in the plugin) | Upstream adds a headless fallback for `openSettingsDocument` (`{opened:false, path}` like `openAgentPresetDirectory`), a config knob to hide the action, or moves the document into the right-sidebar preview (`dsh-resource://file/...` infrastructure already exists) | read upstream `settings-controller` return types and `SettingsDocumentAction` client code | Delete the wrapper (`forceNoSettingsDocument`) from the plugin; adjust contract item 6 and the smoke describe assertions |
| Caddy Host allowlist + `--trusted-host` plumbing | Upstream adds a proxy-aware/dynamic trust source or wildcard trust that makes the static allowlist unnecessary — not expected (the fence is deliberately authority-based) | `contract.sh` fence/CLI checks | No action (expected to stay) |
| `DSH_TELEMETRY_MODE=DISABLED` default in entrypoint | Upstream defaults telemetry to `DISABLED` | read `packages/bundle/base/cordis.patch.yml` telemetry row default | Drop the env default from `container/entrypoint.sh` |

When a trigger fires: implement the simplification within the restricted paths, keep
`docs/upstream-contract.md` + `tests/contract.sh` + `tests/smoke.sh` consistent, and say so in
the report's Adaptation review. When none fires, state that explicitly — "no simplification
opportunity in this tag" is a valid and expected outcome.

## Adaptation review log

The release-prep agent records its Adaptation review on the tracker issue for each tag. When a tag
is released **without** that path — e.g. the tag already existed here, so the upstream watcher never
opened a tracker issue or dispatched release-prep (`dsh-v0.1.7-alpha.1`) — record the review in the
table below instead, so the decision record still exists.

| Tag | Scope | Outcome |
|---|---|---|
| `dsh-v0.1.7-alpha.1` | 1299-commit diff vs `dsh-v0.1.6-alpha.2`; all five simplification triggers re-checked by hand (`tests/contract.sh`: 9 pass / 0 miss / 1 warn) | **No simplification fires at the time.** The browser-side loopback gate was still patched then; the transport row and the `documentPath` flip described in that review are historical and were removed when the support floor moved to 0.2.1-alpha.3; no headless `openSettingsDocument` fallback landed; `DSH_TELEMETRY_MODE` still gates `session-telemetry-otel`; upstream still rejects `--host 0.0.0.0`. Two gaps found and closed: the index is also served at `/index.html` (the Caddy `@index` rule matches both entries) and the telemetry mapping had no static anchor (the telemetry item above) |

## Update protocol

When `contract.sh` reports drift for a new upstream tag:

1. Read the upstream diff (or checkout) and identify which contract item changed and why.
2. For the plugin's upstream API anchors (items 5–6), re-anchor the dependency against the new
   contract. The only thing that runs after `build:official` is the post-processing in
   `container/plugin/scripts/` (image extraction → minification → build-record refresh), and it
   must leave a matching record behind. Rewriting upstream build artifacts is **not** part of this
   repository's adaptation surface.
3. For items 1–4 and 7, do **not** improvise a workaround; report the drift for human review —
   these define the image's security posture, CLI contract, or telemetry default.
4. Update this document and `tests/contract.sh` so both describe the new reality.
5. `tests/smoke.sh` remains the final gate: if behavior broke in a way the static checks cannot
   see, the release still stops there.
