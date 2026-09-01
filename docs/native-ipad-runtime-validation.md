# Native iPad Runtime validation record

This record distinguishes automated infrastructure evidence from manual TFT
compatibility. No real prepared TFT `.app` was provided, so no claim is made
about Riot login, rendering, gameplay, persistence, provenance, or performance.

| Check | Status | Evidence |
| --- | --- | --- |
| Bundle validation | PASS | `./scripts/test-mactician.command`; temporary fake bundles cover valid and invalid metadata |
| arm64 executable | PASS | Unit tests cover arm64 acceptance, Intel-only rejection, and fixed `/usr/bin/lipo` arguments |
| Signature validation | PASS | Unit tests cover signature classification injection and damaged-signature rejection; production source typechecks Security framework calls |
| App launch | NOT RUN | No real prepared TFT application was supplied; lifecycle is covered only by injected `NSWorkspace` mocks |
| Riot login | NOT RUN | Requires manual credentials in a real prepared application |
| Lobby rendering | NOT RUN | Requires a real prepared application |
| Match start | NOT RUN | Requires a real prepared application |
| Full match | NOT RUN | Requires a real prepared application |
| Relaunch and login persistence | NOT RUN | Requires a real prepared application; Mactician does not read or change login state |
| Graceful Stop | PASS | Unit tests cover graceful termination, timeout, exact-process force termination, deduplication, and observer cleanup |
| Android fallback | PASS | Runtime-selection and native-state isolation tests plus full repository/typecheck regression commands |
| CPU/RAM comparison | NOT RUN | Requires repeatable real native and Android sessions on the same host and game build |

## Automated command results

- `./scripts/test-mactician.command`: PASS (`Mactician tests: OK` and full
  production `Mactician typecheck: OK`).
- `./scripts/verify-repository.command`: PASS. The safeguard excludes the Git
  worktree's administrative `.git` link while continuing to scan repository
  content for developer-specific paths.
- Full optimized production-source link check against pinned Sparkle: PASS.
- `git diff --check`: PASS.

## Manual validation blocker

The only blocker to manual validation is the absence of a lawfully obtained,
already prepared, runnable TFT `.app` bundle. When one is available, perform the
steps in `docs/native-ipad-runtime.md` without automating credentials, modifying
the bundle, bypassing a platform or Riot control, or reverse-engineering network
traffic. Record exact failures and stop at any signature, entitlement, DRM,
login, anti-cheat, integrity, or crash blocker.
