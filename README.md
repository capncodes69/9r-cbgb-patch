# 9r-cbgb-patch

Two fixes for **CodeBuddy (`cbai/*`) in 9router**.

From the root of your 9router repo:

```bash
bash patch.sh
```

That is the whole thing. No install, no environment variables, no build step. It
edits three source files in place; `npm run dev` and `npm run build` pick them up
as usual.

```bash
bash patch.sh --check     # is it patched? (exit 0 yes, 1 no, 2 upstream moved)
bash patch.sh --revert    # put the source back to stock
```

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

## What it changes

```
open-sse/executors/codebuddy-intl.js    header family on every request
open-sse/config/errorConfig.js          two provider-scoped backoff rules
open-sse/services/combo.js              pass the provider to checkFallbackError
```

Nothing else. No dependencies, no config, no data.

## Requirements

`git` (used to apply and revert). That is it — no Node version check, because
this script never runs the app.

## If the patch does not apply

It stops and tells you. That means upstream moved and the context no longer
matches — a partial application would leave you with one fix and not the other,
which is harder to diagnose than a clean failure.

```bash
bash patch.sh --check   # exit 2 = would not apply
```

The bundle is written against upstream `87a74e1b` (v0.5.104).

## Notes and limits

- **Downstream patch, not an upstream merge.** Reported upstream
  ([#4944](https://github.com/decolua/9router/pull/4944),
  [#5024](https://github.com/decolua/9router/issues/5024)) but not merged. When
  they are, stop using this.
- **`workbuddy.ai` support is partial.** The header family handles both brand
  hosts, but only `codebuddy-intl` is registered as a provider upstream.
- **The WAF backoff is not verified against a real block.** Classification and
  the backoff path are tested against the exact upstream payloads from the
  report; triggering a real block would burn a real account. When a block does
  happen you should see `AUTH <conn> locked modelLock_<model> for Ns [400]` with
  `N` increasing per attempt.
- **Not included:** the brand-host DNS pin and the `access_token` usage fix from
  the same downstream branch. Those are separate concerns; this bundle is
  deliberately limited to the two CodeBuddy defects.

## Layout

```
patch.sh                      apply / revert / check
patches/9r-cbgb-fix.patch     the bundle: 3 files
```

## License

MIT
