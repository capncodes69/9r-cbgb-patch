# 9r-cbgb-patch

Two fixes for **CodeBuddy (`cbai/*`) in 9router**.

From the root of your 9router source checkout:

```bash
bash patch.sh
```

Or without one, which clones the pinned upstream commit first:

```bash
curl -fsSL https://raw.githubusercontent.com/capncodes69/9r-cbgb-patch/main/patch.sh | bash
```

Run it as many times as you like — it detects an already-applied patch and only
rebuilds.

---

## Fix 1 — channel verification rejects every request

On 2026-10-15 the intl gateway started refusing any request that does not carry
the `X-Conversation-*` header family the official IDE sends:

```
HTTP 400  code 11128  "conversation id missing"
```

Every `cbai/*` model failed 100% of requests. The patch attaches the family — all
three members are required, any two still answer `11128`:

| Header | Value |
| --- | --- |
| `X-Conversation-ID` | stable per conversation, derived from the session key or the opening user message |
| `X-Conversation-Request-ID` | fresh per call |
| `X-Conversation-Message-ID` | fresh per call; `X-Request-ID` mirrors it |

Caller-supplied values are preserved, read case-insensitively: a duplicate key
would make undici join both into `"theirs, ours"` and silently corrupt the id.

## Fix 2 — a refused request never backs off

Both refusal modes — the WAF (`"request illegal"`) and the channel gate
(`"conversation id missing"`) — arrive as `HTTP 400` code `11128`. Neither text
matched any `ERROR_RULES` entry, so both fell through to the request-scoped
catch-all:

```js
return { shouldFallback: false, cooldownMs: 0 };
```

No cooldown, no backoff, no account lock. The router re-fired into the refusal on
every request, so it never got the idle time it needed to expire. Reported
upstream as [decolua/9router#5024](https://github.com/decolua/9router/issues/5024)
— still blocked after 4+ minutes with requests spaced 60–120s apart.

Two provider-scoped rules now apply, matched on **text** and never on code alone:
`11128` is overloaded and also carries a request-scoped body-shape error that
must keep `cooldownMs: 0`. Backoff escalates:

```
2s → 4s → 8s → 16s → 32s → 64s → 128s → 256s
```

`combo.js` needed a one-line fix too: `checkFallbackError` skips any rule whose
`provider` differs from its fourth argument, and that argument was never passed
on the combo path — so every provider-scoped rule, including the pre-existing
`codex` one, was dead there.

---

## Requirements

- **Node.js ≥ 22.5**, npm, git
- ~1 GB free disk, 5–10 minutes

## What it does

1. Uses your checkout, or clones `decolua/9router` at `87a74e1b` (v0.5.104)
2. Applies `patches/9r-cbgb-fix.patch` and verifies both fixes landed
3. `npm install --legacy-peer-deps && npm run build`
4. If a global `9router` CLI exists, backs up its `app/` and installs the build

If the patch does not apply cleanly it **stops** — a half-patched build is harder
to diagnose than a clean failure.

## Options

| Variable | Default | Meaning |
| --- | --- | --- |
| `NINEROUTER_HOME` | `./9router` | where to clone when not in a checkout |
| `NINEROUTER_LOCAL_PATCH` | — | use a patch bundle from disk |
| `NINEROUTER_NPM_CACHE` | `<repo>/.npm-cache` | npm cache location |

## Rollback

The script prints the backup path. To undo:

```bash
rm -rf "$(npm root -g)/9router/app"
mv "$(npm root -g)/9router/app.bak-<timestamp>" "$(npm root -g)/9router/app"
```

Or `npm i -g 9router@latest` to restore the stock build.

## Your data is not touched

This patches the server build only. Dashboard data — SQLite DB, `jwt-secret`,
`machine-id`, connections, API keys — lives in `~/.9router` and is never written.

## Limits

- **Downstream patch, not an upstream merge.** Reported upstream
  ([#4944](https://github.com/decolua/9router/pull/4944),
  [#5024](https://github.com/decolua/9router/issues/5024)) but not merged. When
  they are, stop using this.
- **Pinned to v0.5.104.** That is what the patch was written and tested against.
  On a newer upstream it will refuse to apply rather than guess.
- **WAF backoff is not verified against a real block.** Classification and the
  backoff path are tested against the exact upstream payloads from the report;
  triggering a real block would burn a real account. When a block happens you
  should see `AUTH <conn> locked modelLock_<model> for Ns [400]` with `N`
  increasing per attempt.

## Layout

```
patch.sh                      the script
patches/9r-cbgb-fix.patch     the bundle: 3 files, no deploy config
```

## License

MIT
