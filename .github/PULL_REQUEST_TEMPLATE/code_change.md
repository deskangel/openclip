## Summary

<!-- What this changes, and what problem it solves. One or two sentences. -->

Fixes #

## Why

<!-- The problem, not the diff. Link any related issue or discussion. -->

## How it was verified

<!-- Tick what you actually ran. The PR Intake check reads this section and echoes it back. -->

- [ ] `./scripts/test.sh core` — fast domain suite
- [ ] `./scripts/test.sh` — full suite, 0 skips
- [ ] `./scripts/dev_run.sh` — exercised live in the app
- [ ] Not applicable (docs / build tooling / no behavior change)

## Things a reviewer should look at hard

<!-- Optional. Call out the risky part, the invariant you had to bend, or the edge case you
     are least sure about. A maintainer would rather see this than find it. -->

## Checklist

Only the boxes that apply to this change. The hard rules live in [AGENTS.md](../blob/main/AGENTS.md) —
read it before ticking any of these.

- [ ] Behavior change has test coverage in `Tests/OpenClipTests`
- [ ] New user-facing copy went through `String(localized:)` and `scripts/generate_localizable.py`
- [ ] Any new subprocess goes through `ShellProcessRunner` with the `Constants.scriptTimeout` watchdog
- [ ] Logs go through a `Log` category — no `print()`, no ad-hoc `Logger()`
- [ ] `AGENTS.md` / `docs/` updated in this same commit if a convention or behavior changed
