# Benchmarks

This document summarizes the retained performance evidence without promoting
single runs or comparisons from different scenes.

## Test environment

Unless a row says otherwise, measurements were collected on an Apple M1 Max Mac
with 32 GiB RAM, eight performance and two efficiency cores, macOS 26.6
(25G72), Android Emulator 37.1.11 build 15917651, and an Android 36 ARM64 Google
APIs `userdebug` AVD. The selected graphics path was TFT GLES → guest ANGLE →
Vulkan → gfxstream/MoltenVK → Metal.

The selected display profile used 2560×1440 at density 416, seven vCPUs, and a
separately configurable guest memory value. The quality-preserving control used
100% Unreal screen percentage, FXAA quality 4, anisotropy 8, and a 4 KiB ASG
write step. Performance Max keeps the native-resolution UI but uses a 67% 3D
screen percentage, anisotropy 2, lower-cost effects/LOD, and a 16 KiB ASG write
step. Both use the verified 1 MiB ASG write buffer and 800 µs draw flush.

## Fixed-scene methodology

Early menu/lobby observations were useful diagnostically but are not benchmark
claims. The later harness starts a fresh Tocker's Trial, advances using bounded
XP-first/no-reroll actions, and captures stages 1-2, 1-5, and 1-8 only when both
the stage and combat-phase classifier agree before and after the window.

Each accepted sample records:

- display size and density;
- requested graphics/profile/environment flags;
- active APK, device-profile, emulator, QEMU, and gfxstream hashes;
- host power and thermal state;
- frame count, FPS, mean, median, p95, p99, max, and long-frame counts;
- semantic before/after classifications;
- launch completion and AVD/process-wrapper rollback.

The current navigation loop records planning duration and asserts zero rerolls.
It analyzes one shop while combat is running, buys at most one expensive unit,
batches reward collection, XP, and a one-time carry item pass, and performs at
most one evidence-driven board placement per round. Early deaths replay in the
same emulator and preserve already valid target captures. An obscuring choice
screen, wrong stage/phase, login/lobby state, changed SurfaceView, missing
summary, incomplete Trial, or failed rollback invalidates the affected result.
A transient capture failure is retried at most once and only after a fresh
screenshot still proves the same stage/combat with the shop closed.

### Late-player-combat methodology

Trial stage 1-8 is a useful repeatable proxy, but it is not the user's reported
late-game player battle. For that workload,
[`scripts/capture-late-pvp-session.command`](../scripts/capture-late-pvp-session.command)
passively observes an already running match and never sends game input. The
default gate accepts combat at stages 4 and later in rounds 1, 2, 3, 5, and 6;
round 4 carousel and round 7 PvE are excluded. OCR runs between measurements,
not inside the pacing window. Each result is retained only when the stage and
combat phase still match after capture.

Run Performance Max, sign in manually, start a match, and then use:

```sh
./scripts/capture-late-pvp-session.command \
  --candidate-id performance-max-ubo-pool-16m-screen \
  --duration 90m
```

The candidate ID resolves the variant, profile path, and current profile hash
from the campaign manifest. Use the same command with `--print-selection`
before a match for a read-only attestation; an unknown ID fails before ADB is
used. Control and the seven priority candidates additionally fail before ADB
if their current file differs from the queue's pinned SHA-256. This avoids
pooling a manually mistyped or edited profile under the right label. At capture
startup the observer also resolves the live TFT PID, hashes
the private active `DeviceProfiles.ini`, and requires exactly one bind mount at
that destination. A missing process, unreadable or different hash, or ambiguous
mount count fails before a session directory is created. The manifest records
the expected hash and this live attestation. The same PID, hash, and single
mount are rechecked immediately before and after every pacing window; a process
restart or profile rollback makes that window ineligible. Only capture
directories with a post-window acceptance marker enter the session aggregate,
so an already-written helper summary cannot leak through a failed attestation.

`--print-priority-queue` prints the seven hash-pinned late-PvP experiments in
evidence order without using ADB. The current order targets UBO transport, RHI
command lists, the significance-aware animation budget, GPU Scene updates,
dynamic meshes, early FX scheduling, and Niagara task batching. Each entry
carries its visual/correctness gates; the UBO entry also exposes its unsized
16 MiB capacity gate and 512× synthetic-working-set ratio. Two independent
control and candidate sessions are still required.

The observer records up to eight input-free windows by default, aggregates FPS,
p95/p99, and frames over 50 ms, and keeps rejected semantic windows visible in
its event log. After the first accepted pacing window, it separately records a
two-second guest CPU profile, retains its raw callgraph data, then repeats the
stage/combat gate.
Immediately around that profile it also snapshots every TFT thread's procfs CPU
ticks, scheduled runtime, run-queue wait, context slices, priority/nice, and
wait channel. The generated `thread-scheduler-comparison.json` groups
GameThread, RHIThread, RenderThread, AudioMixer, TaskGraph, and PSO workers.
This distinguishes CPU work from scheduler delay; run-queue wait is not a GPU
stall and must be interpreted beside the symbol profile. Profiling therefore
never overlaps the FPS measurement and is rejected if the same fight ended.
“Passive” here means input-free, not overhead-free: the one-time two-second
Simpleperf recording and derived reports can perturb the remainder of that
combat after the accepted pacing window. Their timings are diagnostic only and
must never be folded into player-visible FPS.
The raw perf file retains CPU call chains and mapped symbols for offline
caller-inclusive attribution, and the capture also emits a non-gating
`simpleperf-children-report.txt` whose Children overhead accumulates samples
through the recorded call chains and includes file-relative addresses for the
stripped Unreal binary. Neither contains a game log. Screenshots remain local
to the session. Thread snapshots contain only names and scheduler counters.
The record/report design follows the official
[Android Simpleperf command-line guidance](https://developer.android.com/ndk/guides/simpleperf).
The session summary reports attempted, accepted, and raw-callgraph profile
counts separately from accepted pacing captures. A failed raw-data pull leaves
the pacing sample usable but rejects the CPU profile, records no SHA-256, and
still removes the guest temporary file; profiling is diagnostic and is never a
promotion gate by itself. The active PID/profile hash/single-mount attestation
also brackets `simpleperf record`; a change rejects attribution even if the raw
file was pulled successfully. A zero-byte pull is likewise rejected and removed
even when ADB returns success.
Compare candidates only on the same late stage/round and power state; do not
pool different board compositions as if they were identical.

The scheduler collector was also exercised against a live 120-thread TFT
process. It matched every thread and normalized the Android `comm` boundary.
RHIThread, GameThread, and RenderThread were already priority 10 / nice −10, as
were the active TaskGraph workers. Raising those priorities is therefore
rejected as a redundant and starvation-prone experiment. The login-screen
run-queue ratios are diagnostic only and cannot substitute for the semantic
late-PvP capture. Curated validation is in
[`artifacts/thread-scheduler-login-validation-20260815.json`](../artifacts/thread-scheduler-login-validation-20260815.json).

After collecting at least two independent observer sessions per variant, build
the matched screen with:

```sh
./scripts/summarize-late-pvp-sessions.command \
  runtime/measurements/late-pvp \
  performance_max_67_no_fbo \
  performance_max_animation_budget_1ms_screen \
  runtime/measurements/late-pvp-animation-budget-comparison.json
```

The comparison keeps only exact stage/round strata whose power source, power
mode, thermal state, game version, active base-APK SHA-256, display, density,
renderer, and guest GL driver also match.
Power source, the active AC or battery power mode, and thermal state are sampled
on both sides of each pacing window; a missing value or transition rejects that
window before matching.
It equal-weights common strata so one frequently sampled round cannot dominate.
Each variant must resolve to exactly one known profile SHA-256 across all common
strata, and the control and candidate hashes must differ; reusing a label after
editing its profile therefore fails rather than silently pooling experiments.
The summarizer also rejects a session unless its manifest contains a successful
PID/single-mount/hash attestation and every retained capture reports that exact
64-character profile hash.
The performance screen also needs two common strata, two contributing sessions
per variant, at least 3% mean-FPS gain, no mean-p95 regression, and at most 3%
mean-p99 regression. It deliberately leaves `promotion_eligible=false`: board
and opponent composition are uncontrolled, and cold-repeat plus visual-fidelity
gates still apply.

## Cold, warm, and sustained runs

- **Cold** means a new emulator/AVD session for the candidate. Cold confirmation
  is required for promotion.
- **Warm/live switch** keeps more state constant and is useful for narrow
  resolution or flag A/B tests, but cannot prove cold-start reproducibility.
- **Sustained** requires the declared minimum Trial duration and every semantic
  gate. Partial long runs remain diagnostic/provisional.

Rows with fewer than two complete runs are provisional unless an immediate
rejection gate applies. The campaign repeats the two strongest one-factor
candidates. Promotion requires at least two successful runs and at least a 3%
reproducible improvement on the relevant heavy score without unacceptable tail
latency, semantic, or rollback failures.

## Confirmed results

| Comparison | Scene | Result | Classification |
| --- | --- | --- | --- |
| `virtio-gpu-asg` vs old `pipe` | Exact stage 1-1 battle | ASG 40.1 FPS / 34.85 ms p95; pipe 29.6 FPS / 49.75 ms p95 | Accepted; ASG selected |
| Selected GPU-scene/RHI/MoltenVK stack | Later stage 1-5 | 36.0–36.8 FPS, p95 near 35 ms | Confirmed range for that scene |
| 2560×1440 vs live 1600×900 | Controlled stage 1-5 | 31.3 vs 30.5 FPS while source pixels increased 2.56× | Accepted narrow A/B; CPU/RHI-bound scene only |
| Three campaign controls | Fresh Trial stages 1-2/1-5/1-8 | Mean 40.60 / 36.03 / 27.83 FPS; heavy score 27.83 | Reproducible control |
| Faster navigation smoke | Fresh Trial stages 1-2/1-5/1-8 | 40.3 / 29.8 / 28.0 FPS; 20.875 s mean preparation, zero rerolls | Harness validation, not a new leaderboard |
| Accelerated navigation | Multiple fresh/replayed Trials | 1–3 s preparation; representative complete runs averaged 1.9–2.1 s with zero rerolls | Accepted harness speedup; roughly 10× less planning time |
| Effects/LOD at 67% | Two complete Trials at stages 1-2/1-5/1-8 | Mean 45.20 / 38.50 / 33.80 FPS; stage-1-8 p95 35.07–35.95 ms | Accepted render profile; retains more resolution than the 50% candidate |
| 16 KiB vs 4 KiB ASG write step | Three complete 16 KiB Trials plus a paired 4 KiB control | 16 KiB 41.3–43.0 / 34.1–35.1 FPS at 1-5/1-8; paired 4 KiB 38.0 / 32.8 | Accepted for Performance Max; wrapper integration reproduced 43.0 / 34.7 |

The selected stack did not meet the 57 FPS heavy-scene objective. It does keep
the reproducible Trial 1-8 proxy above 30 FPS in five complete selected-profile
runs (32.0–35.6 FPS). This does not prove 30 FPS in the user's unreproduced
late-game battle that falls to about 15 FPS; lobby or light-scene observations
near 60 FPS are not substituted for that workload.

## Provisional results

At 3200×1800, an unobscured stage-1-8 sample measured 27.5 FPS / 50.916 ms p95
versus a same-day 2560×1440 control at 28.0 FPS / 49.892 ms p95. The higher
resolution retained 98.2% of FPS while rendering 56.25% more pixels. It remains
provisional because the control recorded battery power while the candidate
recorded AC power, and its p99/frames-over-50-ms were worse. A clean cold A/B is
still required.

Disabling ANGLE `preferSubmitAtFBOBoundary` produced a promising
46.90 / 36.10 / 29.60 FPS first pass. Without the required cold confirmation it
remains provisional and is not the default.

The earlier Performance Max profile used milder effect/LOD limits. Its two cold
runs measured 42.4–44.4 FPS at 1-2, 38.8–50.2 at 1-5, and 29.4–31.5 at 1-8,
with stage-1-8 p95 varying from 34.71 to 48.99 ms. It is superseded by the
confirmed 67% effects/LOD profile and 16 KiB write step above. The
quality-preserving source launcher remains available as a rollback path.

Eighteen additional isolated candidates are boot-compatible with the current
18.1.0-5300314 client and complete the verified launcher rollback path:
`preferCPUForBufferSubData`, aggregate ANGLE barrier calls, disabling image or
buffer barrier events, direct OpenGL UBO writes, a 16 MiB OpenGL UBO pool, a
two-millisecond adaptive global FX budget, the native low-effects emitter rate,
and parallel dynamic
mesh gathering, a stock-low scalability pin set, plus an isolated one-millisecond
animation budget, Riot actor-pool warming, all-task Niagara simulation batches,
early particle scheduling, an eight-instance Niagara task batch, plus Riot's
tickless drag subsystem, the queued RHI command-list path, and a lower GPU Scene
parallel-update threshold. The four ANGLE candidates were screened below and
rejected or left neutral. The fourteen Unreal-side profiles
are queued experiments, not performance results. The Riot login session expired
before a battle A/B could be collected, so none is promoted or credited with an
FPS gain. The FX-budget and emitter candidates additionally require a visual
check that combat spell cues remain legible.

An authentication-independent Android Settings screen verified that guest
ANGLE was mapped and exercised the same Vulkan/ASG transport. Four 12-round
controls spanned 6583.39–6635.68 ms per warm swipe round. Repeated CPU buffer
copy and no-buffer-event candidates averaged 6619.64 and 6622.55 ms versus the
6612.87 ms control mean; the apparent first-run gains disappeared. Aggregate
barriers and no-image-events also remained inside the control range. This is a
useful rejection screen, not a TFT FPS benchmark, so no flag was promoted. The
versioned raw summary is
[`artifacts/android-ui-transport-screen-20260815.json`](../artifacts/android-ui-transport-screen-20260815.json).

A purpose-built Android GLES workload then exercised 16 KiB uniform-buffer
updates, explicit buffer barriers, and periodic finishes inside an attested
guest-ANGLE application process. Each cold run discarded seven ART/ANGLE
warmup rounds and retained 13 rounds of 100,000 updates. Two controls averaged
1410.05 ns/update. `preferCPUForBufferSubData` averaged 1438.96 ns/update
(2.05% slower), so it was rejected. Aggregate barriers averaged 1437.35 versus
1434.53 ns/update in its nearby controls (neutral). Disabling buffer barrier
events averaged 1500.03 ns/update and had worse p95 in both runs, so it was
rejected. Every run reported zero GL errors and completed verified rollback.
This is transport-path evidence, not TFT FPS. The versioned run set, workload,
hashes, exclusions, and comparisons are
[`artifacts/android-gles-buffer-stress-screen-20260815.json`](../artifacts/android-gles-buffer-stress-screen-20260815.json).

A second attested GLES workload added the missing draw-side pressure: 256
per-draw UBO updates and triangle draws per synthetic frame, ping-pong 512²
render targets, explicit buffer/image barriers, and a sampled blit. Eleven
interleaved cold boots retained 13 warm rounds of 30,840 draw calls each.
Against each candidate block's surrounding controls,
`preferCPUForBufferSubData` regressed median time by 3.71% and p95 by 9.15%; it
was rejected. Disabling buffer-barrier events was neutral on median but
regressed p95 by 3.68%, so it was also rejected. Aggregate barriers improved
median/p95 by only 0.79%/0.49%, while disabling image-barrier events improved
median by 1.59% but worsened p95 by 1.01%. Both are below the 3% promotion gate
and remain unpromoted. All 11 runs had zero GL errors and verified rollback.
The complete evidence is
[`artifacts/android-gles-draw-stress-screen-20260815.json`](../artifacts/android-gles-draw-stress-screen-20260815.json).

A third attested GLES workload isolated UBO update strategy under late-combat-
shaped draw pressure: 256 per-draw 32-byte uniform blocks, 120 synthetic frames,
and 30,720 draws per round into a 512² target. Thirteen runs alternated seven
`glBufferSubData` controls around two runs of each candidate, discarding seven
warmup rounds and retaining thirteen. Mapping and filling one aligned UBO pool
once per frame was faster in both brackets, averaging −33.63% median and
−30.54% p95 time per draw. Per-draw map/invalidate was mixed (−2.84% / −3.44%
on average), while subdata into a rebound pool was over 12× slower and rejected
as a synthetic strategy. All runs attested ANGLE→Vulkan, 16-byte UBO alignment,
identical source/APK/profile hashes, and zero GLES errors. This prioritizes the
existing `OpenGL.UBOPoolSize=16777216` candidate, but does not prove that Unreal
implements the exact map-once path and is not a TFT FPS result. Promotion still
requires visual correctness and matched late-PvP frame tails. Evidence is in
[`artifacts/android-gles-ubo-stress-screen-20260815.json`](../artifacts/android-gles-ubo-stress-screen-20260815.json).

Two higher-density repetitions then kept only the winning map-once strategy
and used control-candidate-control-candidate-control brackets. At 512 draws per
frame, both brackets won and averaged −48.99% median / −48.08% p95 time per
draw. A bounded 1024-draw repetition also won both brackets and averaged
−53.13% / −52.44%. All ten retained runs had zero GLES errors and used the
same source, APK, ANGLE→Vulkan runtime, UBO alignment, and 512² target as the
256-draw screen. One longer 1024-draw attempt was interrupted without a
summary and is explicitly excluded. Across the three densities, map-once now
wins six of six brackets; this strengthens the queue order, not the promotion
case. It remains a synthetic microbenchmark rather than TFT FPS or proof of
Unreal path equivalence. The density screen is
[`artifacts/android-gles-ubo-density-screen-20260815.json`](../artifacts/android-gles-ubo-density-screen-20260815.json).

The capacity follow-up prevents that strategy result from silently becoming a
size claim. The attested device reported 16-byte UBO alignment and the probe's
stride was 32 bytes, so the largest measured 1024-draw pool was only 32 KiB.
The proposed 16 MiB Unreal capacity is 512 times larger; even the probe's
unmeasured 2048-draw ceiling would use only 64 KiB. Exact-binary disassembly
confirms a real GL uniform-buffer allocation path and live storage confirms
the one-factor `0 -> 16777216` transition, but neither exposes late-PvP pool
pressure. The profile therefore stays first in the authenticated test queue
because its *strategy* evidence is strongest, while its capacity is explicitly
unsized. A smaller 4/8 MiB ladder is allowed only after 16 MiB first wins TFT
combat tails and correctness gates; prematurely shrinking can introduce pool
exhaustion or reuse stalls. The sizing boundary is recorded in
[`artifacts/unreal-opengl-ubo-capacity-sizing-audit-20260815.json`](../artifacts/unreal-opengl-ubo-capacity-sizing-audit-20260815.json).

A compact machine-readable outcome ledger separates retained product changes,
proxy measurements, synthetic-only findings, rejected settings, the next
authenticated queue, and rollback state in
[`artifacts/fps-experiment-outcome-20260815.json`](../artifacts/fps-experiment-outcome-20260815.json).
Its late-PvP promotion count is deliberately zero: authentication was not
available during this experiment window, so no proxy or microbenchmark result
is relabelled as TFT late-player-combat FPS.

Flat simpleperf attribution was then checked against the exact-binary buffer
corridor instead of assigning the whole RHI thread to UBOs. In the 16 KiB
control, RHIThread represented 31.49% of process samples, but only 1.60% was
reported as stripped Unreal leaf offsets and 16.44% was already attributed to
transport leaves. Across the control, inline, and 32 KiB reports, no exclusive
row landed in the audited `glBufferData`/`glMapBufferRange`/`glBufferSubData`
and UBO-registration corridor. This is not evidence that the path never ran:
the flat reports discard the initiating caller when the sampled leaf is in
transport, ANGLE, kernel, allocator, or libc code. It is an attribution bound:
31.49% is RHI/transport cost, not measured UBO cost. The UBO candidate stays
first on its synthetic strategy evidence, with no new FPS credit. The next
late-PvP observer now retains hash-attested raw `simpleperf.data`, so its call
chains can be analyzed caller-inclusively. See
[`artifacts/simpleperf-rhi-unreal-offset-audit-20260815.json`](../artifacts/simpleperf-rhi-unreal-offset-audit-20260815.json).

A same-workload pipe cross-check then held the OSFT graphics profile, ANGLE
feature overrides, source/APK hashes, 512-draw workload, and bracket design
constant. Pooled map-once again won both blocks, averaging −47.33% median and
−50.18% p95 time per draw. The strategy therefore wins eight of eight retained
brackets across the ASG density screens and pipe cross-check. Absolute ASG/pipe
times are deliberately not compared because the transports were separate cold
launches rather than an interleaved A/B; the transport choice still rests on
TFT battle evidence. This is still synthetic prioritization, not promotion.
Evidence is in
[`artifacts/android-gles-ubo-transport-crosscheck-20260815.json`](../artifacts/android-gles-ubo-transport-crosscheck-20260815.json).

A startup CVar audit of the current `TFT.log` also proved that Riot already sets
`a.Budget.Enabled=1`, disables cloth/AnimDynamics, and disables HZB and
occlusion queries. The no-occlusion candidate was therefore removed as a no-op.
The audit found a real profile interaction: `sg.EffectsQuality=0` selects
`r.EmitterSpawnRateScale=0.125`, but Performance Max later raises it to `0.5`.
The 0.125 value is now an isolated late-PvP candidate, not a promoted default.
Curated evidence is stored in
[`artifacts/unreal-startup-cvar-audit-20260815.json`](../artifacts/unreal-startup-cvar-audit-20260815.json).

The same startup audit found a second profile-ordering issue. Performance Max
selects the stock low scalability sections, but saved quality level 2 is later
reapplied. Explicit DeviceProfile values remain low; unpinned values rise again,
including the animation budget from 1.5 to 1.85 ms, upscaler quality 1 to 2,
foliage density 0.5 to 1.0, translucency volume 24 to 48, and SSS/SSGI and
anisotropic materials. A candidate now pins 14 values to Riot's own stock-low
settings. A cold boot produced exact DeviceProfile push records for all 14;
13 later scalability writes were explicitly rejected as lower priority, while
grass density had no later override record. Rollback was verified, but no FPS
gain is claimed until late-PvP A/B evidence exists. The reproducible delta
audit is
[`artifacts/unreal-startup-profile-audit-scalability-pins-20260815.json`](../artifacts/unreal-startup-profile-audit-scalability-pins-20260815.json).

Epic's Animation Budget Allocator documentation uses 1.0 ms as its example for
low view-distance scalability and explains that the allocator dynamically
reduces skeletal-mesh tick rate and work by significance. Riot already enables
the allocator, so a new candidate changes only `a.Budget.BudgetMs=1.0`.
A cold boot attested the one-line DeviceProfile delta and rejected the later
1.85 ms scalability write. It is not promoted: the same late-PvP fight must show
an FPS/tail win and acceptable animation cadence for important units. Evidence
is in
[`artifacts/unreal-startup-profile-audit-animation-budget-1ms-20260815.json`](../artifacts/unreal-startup-profile-audit-animation-budget-1ms-20260815.json).

A static AArch64 audit of the exact shipped `libUnreal.so` then decoded the
compiled boolean defaults for nine Riot CVars. Actor pooling, both Chrono pools,
tick relevancy filtering, and phase-triggered garbage collection are already
enabled; forced single-thread Chrono sync is already disabled. Those ideas are
therefore no-ops. Actor-pool warming is the one relevant feature compiled off,
so an isolated candidate enables only `tft.ActorPoolWarmingEnabled=1`. It must
pass cold-start and memory gates before any battle test, and it targets spawn
hitches/p95-p99 rather than promising higher steady FPS. Static evidence is in
[`artifacts/tft-runtime-boolean-default-audit-20260815.json`](../artifacts/tft-runtime-boolean-default-audit-20260815.json).

The candidate and control then completed one cold boot each on the expired-login
screen. Candidate/control mean RSS was 969,324/969,381 KiB (−0.006%), mean PSS
was 814,819/815,027 KiB (−0.026%), and
emulator boot was 17.27/17.63 seconds. This passes the directional rejection
gate as memory/startup-neutral; it does not measure whether pools are actually
warmed before combat. Machine-readable samples are in
[`artifacts/actor-pool-warming-cold-screen-20260815.json`](../artifacts/actor-pool-warming-cold-screen-20260815.json),
and exact CVar application is attested in
[`artifacts/unreal-startup-profile-audit-actor-pool-warming-20260815.json`](../artifacts/unreal-startup-profile-audit-actor-pool-warming-20260815.json).

An initial particle audit used a different `libUnreal.so` image than the one
mapped by the running game and therefore assigned valid names to stale
addresses. Repeating the audit against the live library hash found
`FX.AllowAsyncTick=1` and `FX.BatchAsync=32`; direct four-byte reads from the
control process confirmed both values. The isolated `FX.AllowAsyncTick=1`
profile is consequently a no-op and was removed from the campaign queue.
`FX.EarlyScheduleAsync=0` remains a distinct scheduling change rather than
evidence that the already-parallel path needs enabling. Corrected evidence is in
[`artifacts/unreal-particle-async-default-audit-20260815.json`](../artifacts/unreal-particle-async-default-audit-20260815.json).

The earlier cold boot did attest the one-line DeviceProfile push and remained
crash-free at 968,544 KiB RSS, but a push record does not imply a value change.
The startup artifact is retained as negative evidence and now records the no-op
resolution:
[`artifacts/unreal-startup-profile-audit-fx-async-tick-20260815.json`](../artifacts/unreal-startup-profile-audit-fx-async-tick-20260815.json).

A broader hash-correct audit then eliminated more redundant threading toggles.
Niagara system simulation, sim-cache ticks, batched GPU-tick submission, its
world object pool, the Niagara component pool, and the legacy particle-system
pool are all enabled in both the ELF defaults and live storage. Dynamic mesh
instancing and parallel mesh-pass setup are also compiled on. The only bounded
scheduling experiment retained from this group changes
`fx.Niagara.SystemSimulation.TickBatchMode` from 1 (final batch inline) to 0
(all batches scheduled as tasks). It is unpromoted and requires a cold gate plus
matched late-PvP frame-tail and effect-correctness checks. Evidence is in
[`artifacts/unreal-niagara-parallel-pooling-audit-20260815.json`](../artifacts/unreal-niagara-parallel-pooling-audit-20260815.json).
The candidate then cold-booted in 17.65 seconds with an empty crash buffer and
the unchanged 12-file tombstone set. At the expired-login screen it used
970,524 KiB RSS and 815,776 KiB PSS, directionally close to nearby controls.
The startup log attested the sole profile delta, and a live storage read proved
`TickBatchMode=0` while adjacent async/batching values remained one. These are
startup, memory, and isolation gates only; artifacts are
[`artifacts/niagara-all-batches-cold-screen-20260815.json`](../artifacts/niagara-all-batches-cold-screen-20260815.json) and
[`artifacts/unreal-niagara-all-batches-runtime-audit-20260815.json`](../artifacts/unreal-niagara-all-batches-runtime-audit-20260815.json).

A follow-up static audit targeted late-PvP CPU scheduling rather than adding
broad threading switches. Audio command batching is already enabled at 128
commands, animation evaluation/update/interpolation and physics blending are
already parallel, asynchronous component ticks are enabled, and multithreaded
mesh-command caching is enabled. Forcing animation or the disabled core tick
queue/dispatch switches was rejected because it can override project opt-outs,
change ordering, or add task overhead without trace attribution. The two bounded
non-noop candidates left by the shipped binary are `FX.EarlyScheduleAsync=1`
and increasing Niagara system-simulation task batches from four to eight
instances. Static evidence and the explicit decision boundary are in
[`artifacts/unreal-late-pvp-threading-audit-20260815.json`](../artifacts/unreal-late-pvp-threading-audit-20260815.json).

Both candidates then passed an expired-login cold gate. Early scheduling booted
in 17.805 seconds at 971,628 KiB RSS / 816,358 KiB PSS; the Niagara batch-size
candidate booted in 17.785 seconds at 971,168 KiB RSS / 815,823 KiB PSS. Neither
used swap, emitted an Android crash, or changed the 12-file tombstone inventory.
Startup logs attested `0 -> 1` and `4 -> 8`; the hash-checked live read also
returned batch size eight while adjacent async controls stayed enabled. This is
boot, isolation, and memory evidence only: neither login nor the synthetic UBO
workload creates representative particle-system pressure. Both remain
unpromoted pending matched late-PvP frame tails and combat-effect timing and
legibility checks. The joint record is
[`artifacts/particle-scheduling-cold-screen-20260815.json`](../artifacts/particle-scheduling-cold-screen-20260815.json).

The RHI audit found another bounded heavy-draw hypothesis. Performance Max
forces `r.RHICmdBypass=1`, while the shipped default is zero and the same binary
already enables the OpenGL RHI thread, parallel command translation, and cached
mesh draw commands. Parallel translation defaults to 256 commands per task and
parallel command lists require at least 64 draws. A one-factor profile restores
`r.RHICmdBypass=0`. In a cold expired-login A/B, candidate/control mean PSS was
863,716/865,944 KiB (−0.26%), mean RSS was 1,019,339/1,021,153 KiB (−0.18%),
and boot time was 18.191/18.186 seconds. Both runs used no swap and had empty
crash buffers and the same 12 tombstones. This clears only the cold overhead
gate: login has too few representative draws to decide whether queue/parallel
work beats command-list overhead. The candidate is unpromoted and requires
matched late-PvP RHIThread/RenderThread plus FPS-tail evidence. Static and cold
evidence is in
[`artifacts/unreal-rhi-command-list-cold-screen-20260815.json`](../artifacts/unreal-rhi-command-list-cold-screen-20260815.json).

The same exact-binary audit found that GPU Scene parallel updates are supported
but begin only above 2,048 updated primitive/instance items. Niagara dynamic
mesh generation, the visibility task graph, and translucent rendering were
already parallel, so those enablement ideas were rejected as no-ops. A new
one-factor profile lowers only the GPU Scene threshold to 512. Consecutive cold
candidate/control runs attested `2048 -> 512`, used zero swap, produced no crash
or fresh tombstone, and were effectively identical at 930,232/930,231 KiB mean
PSS and 1,075,121/1,075,279 KiB mean RSS. This passes the overhead gate only:
the login screen cannot drive representative GPU Scene counts. The candidate
remains unpromoted pending matched dense late-PvP thread and frame-tail data.
Evidence is in
[`artifacts/unreal-gpu-scene-parallel-cold-screen-20260815.json`](../artifacts/unreal-gpu-scene-parallel-cold-screen-20260815.json).

Riot's binary also exposes `tft.EnableDragSubsystemTicklessMode`; its compiled
storage is zero and its embedded help explicitly describes avoiding drag
subsystem ticks every frame. A one-factor profile enables it. The candidate is
not safe to promote from boot or FPS alone: dragging units between board/bench,
equipping and moving items, selling, and returning to idle must all pass before
and after a late-PvP pacing screen. The static default and help evidence share
[`artifacts/tft-runtime-boolean-default-audit-20260815.json`](../artifacts/tft-runtime-boolean-default-audit-20260815.json).
The same hash-checked live read returned `0` from the control storage, so unlike
the rejected particle profile this remains a genuine setting change; the joint
runtime record is
[`artifacts/unreal-particle-drag-runtime-audit-control-20260815.json`](../artifacts/unreal-particle-drag-runtime-audit-control-20260815.json).

The candidate cold boot then logged the exact transition
`tft.EnableDragSubsystemTicklessMode:false -> 1`, remained alive with an empty
Android crash buffer and no fresh tombstone, and used 968,172 KiB RSS on the
expired-login screen. This confirms the non-no-op setting and boot safety only.
The machine-readable startup delta is
[`artifacts/unreal-startup-profile-audit-drag-tickless-20260815.json`](../artifacts/unreal-startup-profile-audit-drag-tickless-20260815.json).
A hash-checked read after runtime initialization also returned `1` from the
same referenced storage, while the control read returned `0`. This closes the
application/isolation gate but not the interaction or late-PvP gates; evidence
is in
[`artifacts/unreal-drag-runtime-audit-candidate-20260815.json`](../artifacts/unreal-drag-runtime-audit-candidate-20260815.json).

The exact-binary skeletal hot-path audit found no additional enablement
candidate. Local bounds caching, high-priority skinned ticks, asynchronous
skinning-buffer updates, cached skeletal mesh draw commands, the efficient
parallel updater, and the SkeletalMesh render-command pipe are already on; the
dynamic-data pool is enabled at 4096 KiB. Increasing that pool is not queued
without live allocation-pressure evidence. These static defaults remove no-op
hypotheses but are not FPS evidence. The record is
[`artifacts/unreal-skeletal-hot-path-audit-20260815.json`](../artifacts/unreal-skeletal-hot-path-audit-20260815.json).

The final uniform/command-pipeline audit likewise removed enablement no-ops.
Deferred uniform-expression caching, asynchronous cache updates, and material
uniform-expression caching are already on. Unreal selects all declared render
command pipes and the Niagara dynamic-data pipe is enabled. The Vulkan-only
uniform-upload switch is also on, but it does not control TFT's OpenGL RHI path.
The binary exposes only runtime lookups—not a trustworthy registration
default—for `r.UniformBufferPooling`, so no value was inferred. These findings
do not invalidate the isolated OpenGL UBO-pool capacity candidate or the
command-list candidate: Performance Max still explicitly bypasses the latter.
This is static elimination evidence, not TFT FPS evidence; see
[`artifacts/unreal-uniform-command-pipeline-audit-20260815.json`](../artifacts/unreal-uniform-command-pipeline-audit-20260815.json).

A one-CVar cold runtime query subsequently closed the remaining pooling
ambiguity. Setting `r.UniformBufferPooling=1` logged `1 -> 1`, proving that
Unreal's general uniform-buffer pooling is already effective before any
experiment. It must not be added to a profile. Consequently the priority-one
candidate remains isolated to `OpenGL.UBOPoolSize:0 -> 16777216`; the result
strengthens the mechanism match to the synthetic pooled-map win without
turning it into TFT FPS evidence. The query had an empty crash buffer and was
rolled back to a stopped, lock-free, pipe-transport AVD. Evidence is in
[`artifacts/unreal-uniform-buffer-pooling-runtime-audit-20260815.json`](../artifacts/unreal-uniform-buffer-pooling-runtime-audit-20260815.json).

The companion animation-budget audit decoded all 21 policy defaults and kept
the existing 1.0 ms candidate one-factor. The engine default is 1.0 ms, low
view scalability writes 1.5 ms, and saved settings later write 1.85 ms; the
candidate's isolated 1.0 ms write wins startup precedence. Interpolation,
offscreen, tick-rate, quality, and significance knobs remain unchanged because
they would add visible-semantic changes to the same test. The candidate is still
unpromoted pending dense-fight frame tails and animation-cadence correctness.
Evidence is in
[`artifacts/unreal-animation-budget-policy-audit-20260815.json`](../artifacts/unreal-animation-budget-policy-audit-20260815.json).

An earlier apparent 30-to-60 FPS jump is excluded from optimization evidence:
the in-game maximum was manually changed from 30 to 60 immediately before that
observation. Mobile frame-pacing CVars were restored to their stock values and
were not credited for the change.

## Rejected and non-promoted experiments

| Candidate | Evidence | Outcome |
| --- | --- | --- |
| MoltenVK 128 buffers | Strong 40.20/34.50/32.40 run; cold confirmation 39.5/31.6/23.3; two-run mean heavy FPS 27.85 with worse p95 | Failed reproducibility; experimental only |
| MoltenVK 256 buffers | 37.60 at 1-2 and 33.30 at 1-5 with a 133 ms frame; Trial ended before 1-8 | Rejected/incomplete |
| Guest submit thread | 37.40/32.60/25.80 | Rejected regression |
| Shader prewarm / submit+prewarm / upstream ASG | Failed campaign promotion gates | Rejected for default |
| 50% 3D scale | 46.0/36.8 FPS at 1-2/1-5; three attempts ended before 1-8 | No advantage over the 67% effects/LOD profile; incomplete |
| Effects-only / LOD-only split | Particles/effects reached 31.1 FPS at 1-8 with 48.53 ms p95; LOD-only fell to 32.9 FPS at 1-5 with 45.71 ms p95 | Combined profile selected; isolated factors not promoted |
| ASG draw flush 4 ms | Two complete 1-8 runs at 34.2/31.8 FPS; second p95 46.32 ms | Reduced sampled CPU work but hurt reproducibility/tail latency |
| ASG draw flush 2 ms | One 33.4 FPS 1-8 run; confirmation exhausted five attempts before 1-8 | Not promoted |
| ASG write step 8/32 KiB | Both screened at 38.7 FPS on 1-5; 32 KiB included a 62.71 ms frame | Rejected; only 16 KiB passed full confirmation |
| ASG data ring 64/128 KiB | 64 KiB screened at 44.0 but repeated at 41.3/34.6 FPS on 1-5/1-8; 128 KiB screened at 40.5 with 35.86 ms p95 | No reproducible gain over the default 32 KiB ring |
| ASG write buffer 512 KiB | Two boots failed before TFT-ready with `Failed to unbox VkPipeline`; rollback verified | Rejected startup incompatibility; 1 MiB retained |
| Extreme effects/LOD at 67% | 34.9 FPS at 1-5, p99 65.86 ms, max 130.54 ms | Rejected regression; lower quality was not monotonic |
| Emulator audio disabled | 42.1 FPS at 1-5 versus 43.0 for the Performance Max integration run with audio | No FPS benefit; user audio remains enabled |
| VirtioGpuNativeSync | 37.5 FPS at 1-5, p95 35.21 ms, max 53.43 ms | Rejected regression |
| VirtioGpuNext | 42.4 FPS at 1-5, p95 33.72 ms, no frames over 40 ms | Neutral versus the 43.0 FPS integration control; not promoted |
| Forced half-rate skeletal animation with interpolation | 39.4/33.1 FPS at 1-5/1-8; 1-8 p95 37.01 ms and p99 47.11 ms | Rejected; did not scale with unit count and worsened tails |
| Vulkan batched descriptor updates disabled | 40.3 FPS at 1-5 versus 43.0 for the integration control; max 50.58 ms | Rejected regression; batching retained |
| `r.OneFrameThreadLag=0` | 23.6 FPS, -21.9% versus input baseline | Rejected |
| Synchronous MoltenVK submit | 27.1 FPS, -10.3% | Rejected below budget |
| Disable async composition | 27.9 FPS, -7.6%; no proven visible latency reduction | Eligible under original 10% budget, not promoted |
| Explicit native swapchain | 28.9 FPS, -4.3%; feature already enabled in baseline boot log | No-op/not promoted |
| MSAA2 | Black 3D pass with UI still visible | Rejected immediately |
| Material quality 1 | Neutral/noisier | Not selected |
| ASG active-consumer host patch | 11.2 FPS / 334 ms p95 versus 60 FPS / 18.44 ms p95 in same lobby scene | Rejected; explicit forensic opt-in only |
| Native GLES 3.0/3.1 gates | ES 3.0 path crashed before first frame; host native path exposed only GLES 3.0 for the ES 3.1 test | Rejected |

Input captures found approximately 119–120 Hz touch delivery and healthy empty
Android input queues across the tested factors. A separate shop open/close
capture showed about 250 ms between immediate button feedback and panel change
while frames continued normally, consistent with a game-owned UI transition
rather than emulator input backlog.

## Hashes and rollback

External release hashes and active profile hashes are listed in
[Reproducibility](reproducibility.md). The capture scripts record the hashes
actually active for each run instead of trusting a filename.

The ASG wrapper backs up both `config.ini` and generated `hardware-qemu.ini`,
uses a lock with owner verification, and restores both on normal or interrupted
flows. The guest profile/APK mounts and process wrapper are also verified during
cleanup. A sample with failed cleanup is excluded even when its FPS looks good.

## Comparison limits

Do not compare different stages, combat with planning, lobby/login with a match,
obscured and unobscured boards, AC and battery runs, cold and warm results, or
different TFT/emulator versions as if they were controlled. FPS is only one
signal; p95/p99, long frames, semantic validity, stability, and rollback are
part of acceptance.
