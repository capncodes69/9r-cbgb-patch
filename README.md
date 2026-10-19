# 9r-cbgb-patch

> ### Need a CodeBuddy / WorkBuddy account?
>
> Order via Telegram: **[@contools_bot](https://t.me/contools_bot)**
>
> Third-party seller, not affiliated with this repo or with 9router. Check the
> offer yourself before paying.

Two fixes for **CodeBuddy (`cbai/*`) in 9router**.

Run it from the root of your 9router repo. No install, no environment variables,
no build step — it edits three source files in place, and `npm run dev` /
`npm run build` pick them up as usual.

---

## Run it

### Linux / macOS / WSL / Git Bash

```bash
bash patch.sh
```

Or without saving the file first:

```bash
curl -fsSL https://raw.githubusercontent.com/capncodes69/9r-cbgb-patch/main/patch.sh | bash
```

### Windows (PowerShell)

```powershell
.\patch.ps1
```

Or one line, without saving the file:

```powershell
irm https://raw.githubusercontent.com/capncodes69/9r-cbgb-patch/main/patch.ps1 | iex
```

> PowerShell blocks unsigned scripts by default. If `.\patch.ps1` refuses to run,
> use the `irm | iex` form above, or allow it for this session:
> ```powershell
> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
> ```

### cmd.exe

Use the PowerShell one-liner:

```cmd
powershell -NoProfile -Command "irm https://raw.githubusercontent.com/capncodes69/9r-cbgb-patch/main/patch.ps1 | iex"
```

The `irm | iex` form cannot take parameters, so check and revert use environment
variables instead:

```powershell
$env:NINEROUTER_CHECK=1;  irm https://raw.githubusercontent.com/capncodes69/9r-cbgb-patch/main/patch.ps1 | iex
$env:NINEROUTER_REVERT=1; irm https://raw.githubusercontent.com/capncodes69/9r-cbgb-patch/main/patch.ps1 | iex
```

---

## Check / revert

| | Linux, macOS, WSL, Git Bash | Windows PowerShell |
| --- | --- | --- |
| Apply | `bash patch.sh` | `.\patch.ps1` |
| Check | `bash patch.sh --check` | `.\patch.ps1 -Check` |
| Revert | `bash patch.sh --revert` | `.\patch.ps1 -Revert` |

`--check` exits `0` when patched, `1` when not patched, and `2` when the patch
would not apply (upstream moved). Applying twice is a no-op, not an error.

---

## Requirements

| | Needed for |
| --- | --- |
| **git** | applying and reverting the patch |
| bash | `patch.sh` only — present by default on Linux/macOS, via Git Bash or WSL on Windows |
| PowerShell 5.1+ | `patch.ps1` only — built into Windows 10/11 |

Nothing else. Node.js is **not** required by the script — you already have it if
you can run 9router.

Install git if it is missing:

```bash
# Linux
sudo apt install git        # or: sudo dnf install git / sudo pacman -S git
# macOS
xcode-select --install
```
```powershell
# Windows
winget install Git.Git
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

Three files, +221/−2. No dependencies, no config, no data.

## If the patch does not apply

It stops and tells you. That means upstream moved and the context no longer
matches — a partial application would leave you with one fix and not the other,
which is harder to diagnose than a clean failure.

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
patch.sh                      apply / revert / check  (Linux, macOS, WSL, Git Bash)
patch.ps1                     apply / revert / check  (Windows PowerShell)
patches/9r-cbgb-fix.patch     the bundle: 3 files
```

## License

MIT
