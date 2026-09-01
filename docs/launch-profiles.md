# Launch profiles

The root entrypoints remain in place because they share relative paths with the
runtime, reversible AVD wrapper, experiment profiles, and benchmark harness.
Only the first row is the canonical recommendation.

| Entrypoint | Status | Purpose | Differences | Safe default |
| --- | --- | --- | --- | --- |
| `run-tft-best-verified.command` | Recommended | Canonical audited source launch | Pins ASG, ANGLE/OpenGL, MoltenVK async/64, control profile, 1440p default, and clears inherited experiment flags | Yes |
| `run-tft-fast-quality.command` | Stable fallback | Customizable stable stack | Same base stack without the canonical argument parser/override reset | No |
| `run-tft-performance-max.command` | App Maximum FPS preset / source entrypoint | Reduce CPU/RHI and guest-host transport work while retaining full-resolution UI | Riot Performance Mode, 67% 3D scale, confirmed low-cost effects/LOD, four asynchronous OpenGL PSO compilers, 16 KiB ASG writes, and disabled ANGLE FBO-boundary submit; Trial 1-8 remained 34.1–35.1 FPS in two full transport confirmations | No |
| `run-tft-angle-opengl.command` | Required lower-level profile | Apply verified ANGLE/OpenGL overlay | Renderer delegate used by the stable stack; not a complete safety wrapper by itself | No |
| `run-tft-root-affinity.command` | Diagnostic/lower-level | Direct emulator and guest orchestration | Owns rootable AVD, overlay, PSO scheduling, HWUI repair, and cleanup | No |
| `run-tft-gles32.command` | Legacy stable fallback | Non-root external AVD launch | Older pipe-era AVD, 1600×900, 6 GiB, no root scheduling or selected ASG stack | No |
| `run-tft-mvk128-experimental.command` | Experimental, not promoted | Reproduce MoltenVK 128-buffer candidate | One strong run failed cold and sustained reproducibility | No |
| `run-tft-fast-quality-angle-no-fbo-submit.command` | Provisional experiment | Disable ANGLE FBO-boundary deferred submit | Strong first run; lacks the required cold reproducibility confirmation | No |
| `run-tft-fast-quality-shader-prewarm.command` | Rejected for default | Preload a narrow shader set | Neutral lobby, rejected by fixed-stage campaign; retained for comparison | No |
| `run-tft-fast-quality-submit-thread.command` | Rejected | Move guest Vulkan submission/marshalling | Regressed to 37.40/32.60/25.80 FPS in fixed stages | No |
| `run-tft-fast-quality-submit-thread-control.command` | Diagnostic control | Validate submit wrapper without enabling the candidate | Mesa on-demand behavior through the same wrapper | No |
| `run-tft-fast-quality-upstream-asg.command` | Rejected campaign candidate | Force upstream ASG-related features | Did not pass the campaign gates | No |
| `run-tft-fast-quality-asg-active-consumer.command` | Rejected/historical | Reproduce isolated four-byte host patch | 11.2 FPS / 334 ms p95 versus stable lobby control; requires explicit override | No |
| `run-tft-fast-quality-native-gles.command` | High-risk diagnostic | Disable guest ANGLE | Tests native gfxstream GLES path; no accepted result | No |
| `run-tft-fast-quality-native-gles30.command` | Rejected/historical | Relax the native gate to ES 3.0 | TFT crashes before first frame because required GLES APIs are absent | No |
| `run-tft-fast-quality-native-gles31.command` | Rejected/historical | Relax the native gate to ES 3.1 | Host exposes only native GLES 3.0, so the strict gate fails correctly | No |
| `run-tft-fast-quality-ubo-direct-write.command` | Experimental | Test direct uniform-buffer writes | Live CVar isolation and cold boot are verified; a synthetic per-draw map path was mixed, and exact Unreal Buffer Storage behavior still needs late-PvP validation | No |
| `run-tft-fast-quality-ubo-pool.command` | Prioritized experiment | Test a 16 MiB uniform-buffer pool | Live CVar isolation and cold boot are verified; map-once pooled updates won 8/8 synthetic brackets across 256/512/1024 draws and ASG/pipe, but the measured working set reached only 32 KiB and this is neither TFT FPS nor proof of the identical Unreal path | No |
| `performance-max-fx-budget-2ms-screen` campaign candidate | Experimental, not promoted | Adaptively cull Niagara systems only when the global FX workload exceeds a 2 ms budget | Current Riot binary contains the budget hooks and the profile cold-boots with verified rollback; late-PvP FPS and spell-cue legibility are unmeasured | No |
| `performance-max-fx-early-schedule-screen` campaign candidate | Experimental, not promoted | Schedule eligible particle-system work earlier in the frame | The shipped default is zero and startup attests the isolated `0 -> 1` change; login-screen crash/memory gates passed, but late-PvP frame tails and effect timing are unmeasured | No |
| `performance-max-rhi-command-list-screen` campaign candidate | Experimental, not promoted | Restore queued/parallel RHI command-list processing instead of bypassing it | The shipped OpenGL RHI and parallel-translate facilities are enabled; isolated `RHICmdBypass 1 -> 0` passed cold memory/crash gates, but heavy-fight queue overhead and FPS tails are unmeasured | No |
| `performance-max-gpu-scene-parallel-512-screen` campaign candidate | Experimental, not promoted | Start supported GPU Scene parallel updates at 512 rather than 2,048 updated items | The isolated `2048 -> 512` transition and a consecutive cold memory/crash-neutral pair are verified; dense late-PvP update counts and frame tails are unmeasured | No |
| `performance-max-animation-budget-1ms-screen` campaign candidate | Experimental, not promoted | Constrain significance-aware skeletal animation to 1 ms | Riot enables the allocator and Epic documents 1 ms as a low-scalability example; startup application is attested, but late-PvP FPS and animation cadence are unmeasured | No |
| `performance-max-niagara-all-batches-async-screen` campaign candidate | Experimental, not promoted | Schedule every Niagara simulation batch as a task | Startup and live storage prove the isolated `TickBatchMode 1→0` change; login-screen safety passed, but task overhead and combat-effect timing are unmeasured | No |
| `performance-max-niagara-batch-size-8-screen` campaign candidate | Experimental, not promoted | Halve Niagara system-simulation task count when enough instances are active | Startup and live storage prove the isolated batch-size `4 -> 8` change; login-screen crash/memory gates passed, but heavy-fight task overhead and effect timing are unmeasured | No |
| `performance-max-drag-tickless-screen` campaign candidate | Experimental, not promoted | Avoid Riot drag-subsystem ticks while idle | Startup and live storage prove the isolated `0→1` change; board, bench, item, and sell interactions plus late-PvP pacing remain unverified | No |
| `run-tft-direct-vulkan.command` | Rejected/historical diagnostic | Test direct Unreal Vulkan | The selected Shipping device profile disables direct Vulkan RHI; Vulkan remains below ANGLE | No |

Resolution status in the canonical launcher is independent of graphics profile:
1440p is verified, 1620p has a verified full-size SurfaceView but no accepted
battle result, 1800p is provisional, and 2160p is experimental.

The packaged launcher displays a click-through 62×20 FPS HUD at the right edge
of the active Emulator title bar. It samples existing SurfaceFlinger presentation
timestamps once per second, hides when the Emulator loses focus, and stops with
the game session. A paired 20-round transport test with and without the HUD plus
activity-monitor polling differed by only 0.22% with mixed tails, so the HUD was
retained.

Rejected profiles are retained to make negative results reproducible. Do not
infer recommendation from file naming, and never compare login/lobby FPS with
an active-match result.
