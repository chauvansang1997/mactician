# Native GLES and graphics-transport experiment

Date: 2026-08-10/11

## Decision

The short native-GLES path is not viable with the guest image and gfxstream
binaries shipped by Emulator 37.1.11. The blocker is API capability across the
whole protocol, not launcher wiring: TFT exercises ES 3.1/3.2 core
functionality before the first frame, while the working Metal-backed path and
the outer gfxstream context expose ES 3.0. Advertising ES 3.2 without
implementing those capabilities only moves the failure into Unreal's renderer.

The supported production path therefore remains:

```text
TFT / Unreal GLES
  -> guest ANGLE (GLES to Vulkan)
  -> guest gfxstream Vulkan encoder
  -> virtio-gpu ASG
  -> host gfxstream Vulkan decoder
  -> MoltenVK
  -> Metal
```

The current bottleneck is more precise than "the chain is long": frame
throughput is limited by serialized RHI/command submission and synchronization
across the guest/host boundary and its downstream Vulkan-to-Metal consumer. An
ASG write can represent packing/copy work, ring backpressure, or a downstream
fence wait; it is an observation point, not proof that byte copying alone is
the root cause.

## Native-path experiment

The proposed path was:

```text
TFT / Unreal GLES
  -> gfxstream GLES encoder
  -> virtio-gpu ASG
  -> host ANGLE
  -> Metal
```

It would remove guest ANGLE, the Vulkan gfxstream protocol, and MoltenVK from
the frame path. The experiment deliberately separated host capability from the
end-to-end guest path.

### Launcher wiring

`run-tft-root-affinity.command` now forwards ANGLE feature overrides into the
packaged emulator host. It also forwards the MoltenVK variables used by the
bounded A/B candidates. This closes a real diagnostic gap: an app-bundled run
now receives the same process-local configuration as a direct emulator run.

### Host ANGLE probe

`artifacts/angle-egl-probe.cpp` is now a self-contained dynamic EGL/GLES probe.
It does not depend on development headers absent from the packaged runtime. It:

- requests ES 3.2, 3.1, and 3.0 contexts independently;
- reports the actual GL and GLSL versions;
- reports selected ES 3.1/3.2 extensions and entrypoints;
- enumerates relevant ANGLE features;
- supports explicit default, Metal, Vulkan, and OpenGL backends;
- applies ANGLE feature overrides at EGL display creation time.

`scripts/run-host-angle-capability-probe.command` builds it against the
currently installed packaged runtime and runs the `default`, `metal`, `opengl`,
or isolated `swiftshader` matrix entry. The last mode intentionally enables
`exposeNonConformantExtensionsAndVersions` and returns nonzero when the nominal
ES 3.2 geometry/tessellation probes expose the expected zero-limit failure.

Observed results:

- the packaged host ANGLE working backend exposes ES 3.0, not ES 3.1/3.2;
- selecting ANGLE Metal advertises the platform extension but fails display
  initialization in this build;
- selecting ANGLE Vulkan reaches MoltenVK but aborts during Vulkan buffer
  allocation, so it is not a usable shortcut around gfxstream;
- selecting ANGLE Vulkan with the packaged SwiftShader ICD creates ES 3.1 and,
  under ANGLE's explicitly non-conformant
  `exposeNonConformantExtensionsAndVersions` override, nominal ES 3.2 contexts.
  Compute, image, indirect-draw, and texture-buffer entrypoints
  are exposed. This isolates part of the limitation: the ANGLE frontend covers
  the ES 3.1 functionality exercised by TFT, but its viable macOS hardware
  backend and the surrounding gfxstream protocol do not provide the complete
  contract;
- version-exposure overrides do not add the missing ES 3.1/3.2 behavior.

The direct SwiftShader EGL/GLES libraries are not an alternative: unlike ANGLE
over SwiftShader Vulkan, they expose only ES 3.0 and lack compute entrypoints.

The positive SwiftShader subset is functional rather than a version-string
check. The probe compiles and runs a GLSL ES 3.10 compute shader, reads the
written SSBO back on the CPU, verifies two-pass `imageStore`/`imageLoad` through
an `r32ui` image, and completes a GLES fence/client-wait. In the nominal ES 3.2
context it also samples a `GL_R32UI` texture buffer from a GLSL ES 3.20 compute
shader. All readbacks match their sentinel values. However, both geometry and
tessellation pipeline probes fail: the reported limits are
`GL_MAX_GEOMETRY_OUTPUT_VERTICES=0`, `GL_MAX_PATCH_VERTICES=0`, and
`GL_MAX_TESS_GEN_LEVEL=0`, and the corresponding extensions are absent. Thus
the override does not make this a conformant or complete ES 3.2 renderer. The
same test cannot start on Metal and cannot request an ES 3.1 context on the
default macOS OpenGL backend.

The direct Vulkan probe crash was isolated to the probe process. Its macOS
diagnostic report is retained outside the repository under the user's
DiagnosticReports directory.

### Guest EGL capability probe

`artifacts/android-egl-capability-probe` is a headerless arm64 Android probe
built by `scripts/build-android-egl-capability-probe.command` with the project's
Go 1.24.3 toolchain. It goes through Android's public `libEGL.so` loader, pins
all EGL calls to one OS thread, creates a pbuffer, reports actual versions and
limits, and resolves all 59 EGL/GLES names found dynamically in `libUnreal.so`.
The no-cgo assembly bridge is diagnostic code, not application runtime code.

On a cold boot with `GuestAngle` enabled, the loader selected guest ANGLE over
gfxstream Vulkan/MoltenVK. A nominal ES 3.2 context was created, but geometry
and tessellation limits were zero even though the relevant proc addresses were
non-null. On an isolated cold boot with `GuestAngle` disabled and no APK or
library overlay, the public loader selected the native gfxstream GLES driver:

```text
EGL 1.4
ES 3.2 request -> EGL_BAD_CONFIG
ES 3.1 request -> EGL_BAD_CONFIG
ES 3.0 request -> OpenGL ES 3.0 (4.1 Metal - 90.5)
renderer       -> Android Emulator OpenGL ES Translator (Apple M1 Max)
```

The native ES 3.0 context still returned non-null proc addresses and non-zero
geometry/tessellation limit values for names outside its advertised version.
They are therefore dispatch-table evidence, not a usable capability contract.
After the probe was reordered to establish ES 3.0 first, a complete clean-boot
run resolved 56 of the 59 Unreal lookup names, including every one of the 11
core-to-EXT/OES/IMG alias candidates. The three null results were
`eglGetFrameTimestampsSupportedANDROID`,
`eglQueryTimestampSupportedANDROID`, and `glDebugMessageLogKHR`. The loader
advertises `EGL_KHR_get_all_proc_addresses`, so static library exports
substantially undercount this runtime surface. Explicit ES 3.1 and 3.2 requests
still returned `EGL_BAD_CONFIG` after that collection. An immediate first
post-boot attempt exited with `SIGSEGV`, while the repeated staged run completed;
the probe now prints unbuffered phase markers so a future readiness race can be
distinguished from a specific EGL call.

The recorded clean-boot output retains the SHA of the exact probe binary used
for that observation. After capture, the source added explicit
`runtime.KeepAlive` barriers for EGL attribute slices passed through the
no-cgo `uintptr` bridge. The hardened source rebuilds reproducibly as an arm64
Android PIE with SHA-256
`9ccd84c8af69f015702ac3e04bcda165eafac6bef5d4b926d423f70cb162a31e`;
its only dynamic dependencies remain `libEGL.so` and `libGLESv2.so`.

### End-to-end guest result

The strict native gfxstream GLES run successfully proved that guest ANGLE was
absent and the native GLES encoder was selected. It then reported ES 3.0, and
TFT correctly rejected the renderer because it requires ES 3.2.

A bounded `-gpu swangle` control was then added for native-GLES experiments.
The host side initialized ANGLE over Vulkan/SwiftShader with ES 3.1 and
texture-buffer extensions, but the outer gfxstream context still exposed ES
3.0. The unmodified game therefore stopped at its ES 3.2 gate.

An isolated `libUnreal.so` gate patch to ES 3.1 progressed into the RHI thread
and then failed before the host could execute the commands. The guest
`libGLESv2_enc.so` validation rejected texture-buffer targets in
`glBindTexture`, `glTexParameteri`, `glTexStorage3D`, and `glTexSubImage3D`, as
well as capability `0x8db9`; the RHI thread then terminated with `SIGTRAP`.
This is the expected failure mode of a capability spoof: the version gate
moves, but the required formats, state, shader behavior, and entrypoints do not
appear. The software control is retained only as a diagnostic and is never a
performance candidate.

Static inspection of the original 194 MB game library found 151 direct EGL/GLES
imports and 210 unique EGL/GLES names in total. The game directly imports ES
3.1 compute, image, memory-barrier, and indirect-draw APIs; dynamically resolved
names include texture buffers, framebuffer texture, indexed blend, and debug
APIs. The requirement is therefore active renderer behavior, not merely a
conservative version check.

`scripts/audit-native-gles-coverage.command` makes that inspection
reproducible and compares the game with the shipped guest EGL/GLES wrappers,
the guest encoder, optional upstream protocol/dispatch source, and optional
host ANGLE exports. For this build all 151 direct imports are present across the
shipped guest ABI. Of the 59 dynamic names, 16 have an exact exported surface,
11 have a core-to-EXT/OES/IMG alias candidate (including texture buffers and
indexed blend), and 32 have no exact guest export. These 32 are optional lookup
names until runtime evidence shows they are consumed; their absence is not
treated as 32 mandatory implementation gaps. Conversely, a present symbol is
only ABI coverage and says nothing about caps or enum validation. The observed
texture-buffer validation failure therefore remains the stronger blocker than
symbol count. The later 56/59 runtime lookup result also demonstrates that this
static matrix is a conservative source audit, not an `eglGetProcAddress`
prediction through Android's full loader stack.

### Source-build boundary

The current upstream gfxstream host backend was built successfully on this Mac
from `emu-main-dev` (revision `a9184fd`) after two local warning-compatibility
adjustments. The generated standalone dylib is not a drop-in replacement for
the emulator's production backend: it exports substantially fewer integration
symbols than the packaged library.

More importantly, current source still contains an incomplete GLES 3.2
capability path. Host version detection is capped at 3.1, the macOS OpenGL path
maps OpenGL 4.1 to ES 3.0, maximum-version handling maps both 3.1 and 3.2 to a
3.1 context, and RenderControl version strings omit 3.2. Generated protocol
code already includes several texture-buffer and indexed-blend extension
opcodes, but that is not the same as coherent context creation, validation,
dispatch, and capability propagation.

`artifacts/gfxstream-gles32-host-capability-prototype.patch` is a concrete
host-capability prototype against that revision. Its 61 added lines probe an
ES 3.2 context before falling back, add the translator's 3.2 interface and
dispatch group, and propagate `ANDROID_EMU_gles_max_version_3_2` plus the 3.2
version string through RenderControl. It applies cleanly to `a9184fd`; a clean
standalone `gfxstream_backend` build completed with SHA-256
`ba86d350b83f7538add45ded2b1cf868a152fb4cc571fc83d55337b71f149c9b`
after the same two AppleClang warning-compatibility allowances. It is retained
as implementation evidence, not as a drop-in binary or a conformance claim.

`artifacts/gfxstream-gles32-guest-proc-alias-prototype.patch` implements the 11
mechanical proc-address candidates reported by the static Unreal audit. It
exposes the promoted GLES 3.2 core spellings (including `glTexBuffer` and
indexed blend) while reusing gfxstream's existing EXT/OES/IMG encoder opcodes.
The patch applies cleanly to `a9184fd` and its modified guest EGL translation
unit passes a standalone Clang syntax check. The later runtime probe showed the
shipped Android loader already resolves these aliases, so the patch is retained
as a rejected source-level prototype and should not be applied to this image.
It also could not create capabilities or shader stages in any case.

The Android guest graphics libraries are also older than the host emulator:
the system image is build 13894323 from 2025-08, while the emulator backend is
build 15917651. The guest encoder's validation decisions depend on per-context
ES-version and extension flags, and those flags remain false in the failed
native run. Building only the macOS host backend cannot repair that side of the
contract. Current upstream guest source already understands the 3.2
RenderControl token and ES 3.2 EGL context requests, which makes upgrading the
whole source-matched guest stack preferable to binary-patching the older image.

Consequently, a real native implementation is not a small GLES wrapper. It
requires a source-matched Android guest encoder/EGL stack and host
ANGLE/gfxstream stack with the complete ES 3.1/3.2 contract, including shader,
texture-buffer, sync, gralloc/AHardwareBuffer, EGL surface, validation, dispatch,
and extension capability propagation. That is a separate renderer project, not
a safe launcher patch.

## Current-path experiments

All frame-pacing samples use semantic before/after gates, fresh Tocker's Trials
stages, active binary/profile hashes, and verified restoration of AVD config,
hardware config, process wrapper, and ASG backups. Screen candidates stop at
1-5; candidates that survived screening were repeated at 1-8.

The nearest earlier paired control recorded 38.0 FPS / 34.01 ms p95 at 1-5 and
34.8 FPS / 34.51 ms p95 at 1-8. A later profiled control, after the autonomous
Trial driver was made deterministic enough to reach 1-8 reliably, recorded
40.4 FPS / 34.00 ms p95 at 1-5 and 29.2 FPS / 48.77 ms p95 at 1-8. Absolute
FPS varies with Trial composition, so promotion requires a repeatable gain in
both throughput and tail latency rather than a single favorable board.

| Candidate | 1-5 result | 1-8 result | Decision |
| --- | --- | --- | --- |
| Large MoltenVK query pools off | 41.2 FPS / 33.54 ms p95 | 33.8 FPS / 35.46 ms p95 | Mixed: early gain, heavy-stage/tail regression |
| `VirtioGpuNext` | 39.2 / 34.72 | 31.8 / 44.74 | Reject |
| Max concurrent compilation | 38.6 / 34.27 | 33.4 / 35.76 | Reject |
| Guest submit inline, first full run | 39.3 / 34.55 | 31.7 / 45.54 | Apparent heavy-stage gain, required repeat |
| Guest submit inline, profiled repeat | 35.6 / 34.76 | 26.4 / 50.62 | Reject: gain did not reproduce; exposes RHI/MMIO latency |
| Forced guest submit thread | 38.4 / 34.91 | not promoted | Reject |
| No async composition | 39.6 / 34.36, 49.46 ms p99 | not promoted | Reject: worse tail |
| Explicitly disable native swapchain | 39.0 / 34.15, 51.20 ms max | not promoted | Neutral/worse tail |
| ASG flush 400 us | 39.5 / 35.02 | not promoted | Reject |
| ASG flush 1200 us | 36.6 / 37.10 | not promoted | Reject; 800 us remains local optimum |
| MoltenVK argument buffers on | 41.3 / 35.44, 48.43 ms p99 | not promoted | Reject: worse tail |
| Metal-event semaphores | 38.3 / 34.60 | not promoted | Reject |
| MoltenVK MTLHeap off | 39.9 / 34.21 | not promoted | Neutral |
| Prefill Metal command buffers | 35.8 / 35.19 | not promoted | Reject |
| ASG data ring 64 KiB | 39.6 / 35.17 | did not reach 1-8 | Reject/incomplete |
| ASG write step 32 KiB, profiled | 39.2 / 34.35 | 31.2 / 46.97 | Reject: no lower write cost, worse 1-5 tail |

Two configuration findings are important even though they are not performance
wins:

- `VulkanQueueSubmitWithCommands` is required. Two real-TFT cold boots with it
  disabled aborted the emulator while decoding
  `VK_STRUCTURE_TYPE_APPLICATION_INFO` before ADB was available.
- several apparent candidates were actual defaults and therefore no-ops:
  MoltenVK argument buffers off and single-queue semaphore style 0.

The fatal queue-submit profile, ignored virtual-queue profile, and both
confirmed MoltenVK no-op controls are excluded from the executable performance
candidate manifest. Their launcher diagnostics and negative findings remain
available for reproduction without allowing an unattended campaign to select
them.

MoltenVK performance tracking/logging reached the host process but emitted no
useful per-frame performance stream in this packaged build; the diagnostic run
also introduced a 106.93 ms outlier. It is unsuitable as benchmark telemetry.

### Paired guest and host profiles

The profiled control (`20260811T002030Z__profile-performance-max-heavy__60232`)
made the residual boundary cost more specific:

- guest `simpleperf` attributed 11.54% of samples to RHI-thread `writew`, 2.31%
  to `ring_buffer_available_read`, and 1.94% to
  `AddressSpaceStream::speculativeRead`;
- the host sample showed most gfxstream render threads sleeping in
  `RingStream::readRaw`, with only sparse active decode stacks;
- several host stacks were waiting in `vkWaitForFences` through MoltenVK;
- the profile semantic gate and all rollback checks passed.

This rules out a continuously saturated host decoder as the main explanation
for the guest ASG hotspot. The more likely cost is guest RHI serialization,
MMIO/kicks and readbacks, plus synchronization boundaries that intermittently
stall an otherwise underfed host consumer.

The inline-submit repeat increased the guest sample share in `writew` to
14.22%, while the 32 KiB ASG step produced 13.07%. Neither reduced the
absolute frame cost repeatably. The on-demand submit thread and the 16 KiB
write step therefore remain the local optima: the thread hides some boundary
latency, while a larger packet step does not remove the relevant work.

A reproducible parser now aggregates all exclusive rows instead of relying on
the single largest stack. On the profiled control, RHIThread represented 31.49%
of samples and transport-class symbols represented 16.44%. Inline submission
raised those shares to 37.50% and 19.78% while FPS fell 9.59%. The 32 KiB run
recorded 33.93%/18.52%; its single 1-8 capture was faster, but the mechanism did
not lower sampled transport work and the broader screen had already failed.
The versioned comparison, raw hashes, and limitations are in
[`artifacts/simpleperf-stage1-8-transport-audit-20260815.json`](../artifacts/simpleperf-stage1-8-transport-audit-20260815.json).

### Auth-independent transport probe

After the Riot session expired, further match A/B runs could not be performed
without credentials. The scoped Keychain helper found no configured item and
stopped before reading or entering anything. To keep transport testing
independent of Riot state, Android Settings was exercised through the same
guest HWUI/ANGLE -> Vulkan -> ASG -> gfxstream -> MoltenVK stack. Each profile
used six steady-state rounds of 30 alternating scroll animations and Android
`gfxinfo` frame statistics.

| Gfxstream gate | Mean series time | Warm p95 / p99 | Decision |
| --- | ---: | ---: | --- |
| OSFT control | 6.629 s | 9-11 / 11-13 ms | Control |
| `VulkanBatchedDescriptorSetUpdate` off | 6.627 s | 10 / 11-12 ms | Neutral; keep current default but claim no speedup |
| `VirtioGpuFenceContexts` off | 6.603 s final round | 10 / 12 ms | No benefit versus paired control 9 / 11 ms; reject |

Emulator startup logs confirmed that the descriptor-batching and fence-context
gates changed the host gfxstream feature set. An earlier run labelled
`VulkanVirtualQueue` off is excluded: the emulator reports that guest use of
that flag is ignored, so it was not a valid feature A/B.

A later narrow flush sweep used 12 rounds per run, discarded three warm-up
rounds, required at least 120 rendered frames per round, and aggregated valid
runs with `scripts/summarize-android-ui-transport.command`:

| ASG draw flush | Valid/rejected runs | Warm rounds | Mean / median series | Worst p95 / p99 | Decision |
| --- | ---: | ---: | ---: | ---: | --- |
| 600 us | 2 / 0 | 18 | 6.668 / 6.656 s | 23 / 29 ms | Reject |
| 700 us | 1 / 0 | 9 | 6.783 / 6.750 s | 22 / 36 ms | Reject |
| 800 us | 3 / 0 | 27 | 6.637 / 6.631 s | 23 / 36 ms | Control |
| 850 us | 1 / 0 | 9 | 6.692 / 6.687 s | 10 / 13 ms | No throughput gain; reject |
| 900 us | 2 / 0 | 18 | 6.614 / 6.602 s | 22 / 31 ms | 0.34% mean shift is below run noise; do not promote |
| 1000 us | 1 / 1 | 9 | 6.967 / 6.700 s | 61 / 150 ms | Reject: severe tail and one non-rendering run |

The rejected 1000 us repeat first stalled for about 98 seconds, then produced
zero new Settings frames even though input commands returned. The probe now
fails fast on such a non-rendering round instead of allowing stale `gfxinfo`
percentiles to look like a fast result. This is direct evidence that extending
the notification interval can cross a sharp pacing boundary rather than
providing monotonic batching gains.

A previously untested 16 KiB ASG data ring was also worse: 6.728 s warm mean
and 6.728 s median, versus 6.637/6.631 s for the pooled 32 KiB control. Together
with the earlier 64/128 KiB results, 32 KiB remains the local data-ring optimum.

A final guest-attested feature-gate sweep superseded the earlier label-only
comparison. It exercised Android Settings through HWUI `skiavk` at 2560x1440.
Each cold-booted profile used 12 rounds and discarded the first three. Before
measurement, the probe required the requested profile to equal
`ro.boot.mactician.graphics_profile`; it also recorded the actual ASG transport
and HWUI renderer. Four OSFT controls were interleaved with the candidates, and
the two signals closest to useful (`no-fence` and `no-batching`) were repeated.

| Vulkan/gfxstream profile | Valid runs / warm rounds | Warm mean / median | Mean delta vs pooled control | Worst p95 / p99 | Janky frames | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| OSFT control | 4 / 36 | 6.728 / 6.706 s | control | 21 / 73 ms | 43 | Keep |
| `AsyncComposeSupport` off | 1 / 9 | 6.837 / 6.846 s | +1.62% | 22 / 61 ms | 10 | Reject: slower |
| `VirtioGpuFenceContexts` off | 2 / 18 | 6.737 / 6.712 s | +0.13% | 23 / 69 ms | 16 | Neutral; no transport win |
| `VulkanBatchedDescriptorSetUpdate` off | 2 / 18 | 6.819 / 6.830 s | +1.35% | 23 / 65 ms | 14 | Reject: repeatable latency regression |
| Native-swapchain profile off | 1 / 9 | 6.795 / 6.754 s | +0.99% | 22 / 57 ms | 10 | Reject: no gain |

The four control means ranged from 6.700 to 6.766 s. The pooled no-fence mean
was only 9 ms slower than control, well inside that 66 ms run-to-run spread;
its first favorable median did not reproduce. Disabling batching produced
fewer counted janky frames per round, but both runs had worse latency and the
worst p95 was not improved. Max-tail comparisons are also biased against the
control because it contains twice to four times as many rounds. No candidate
therefore meets a throughput-plus-tail promotion gate. Every run restored the
known AVD configuration and hardware hashes after shutdown.

The exact per-run and pooled values are retained in
`artifacts/android-ui-transport-attested-20260811.json`; the larger raw
`gfxinfo` captures remain local runtime evidence.

The measurement directory labelled
`feature-vulkan-no-queue-submit-commands-a` is excluded from the table. A
subsequent exact cold-boot repeat confirmed the earlier fatal failure before
ADB, so the Settings probe could not have run on that candidate AVD. It most
likely attached to a still-running control instance; its timing is invalid
evidence rather than a neutral feature result.

The last row is a profile-level result: disabling native swapchain also made
the emulator disable Vulkan composition and `GuestVulkanOnly`, and enabled the
host GLES translator. It therefore proves that the current combined profile is
valuable, but does not isolate one implementation mechanism. The emulator also
reported that `VulkanVirtualQueue` is ignored on every boot, so it was not
misrepresented as a live A/B candidate.

The probe's earlier `transport: pipe` field is the boot transport property, not
proof that HWUI used GLES. Host logs created Vulkan instances for `android
framework` in these runs. Schema 4 records `debug.hwui.renderer` explicitly as
`hwui_renderer` and requires the requested launcher graphics profile to match
the boot-attested `ro.boot.mactician.graphics_profile`. The attested sweep above
also fixed density at 320 dpi in its launch orchestrator and retained that
invariant in the result artifact. Schema 5 additionally reads `wm density`
inside the guest. The aggregator partitions otherwise identical label groups
by attested profile, active display and density, transport, and HWUI renderer;
legacy summaries without density are marked `legacy-unknown` rather than
silently pooled with new evidence.
Fail-fast Settings-launch, `gfxinfo` parse, and non-rendering failures also
write a schema-5 summary with `rejected_reason`, so failed candidates remain
visible in aggregate valid/rejected counts instead of disappearing as partial
directories.

Both schema-5 paths were cold-boot validated after implementation. A one-round
OSFT control recorded `display_density: 320` and aggregated as 1 valid / 0
rejected. A deliberately impossible 999999-frame minimum stopped after its
first rendered round, recorded `non_rendering_round_1`, and aggregated as 0
valid / 1 rejected with null performance metrics. Both runs stopped QEMU and
restored the exact baseline AVD hashes.

### AEMU extension-policy control

The packaged emulator contains an
`androidboot.hardware.aemu_feature_overrides_disabled` list covering several
GLES extensions, including texture buffers, indexed draw buffers, geometry,
tessellation, shader I/O blocks, and base-vertex draws. Two reversible cold-boot
controls tested whether that policy was suppressing capabilities which guest
ANGLE could otherwise use: one removed only `textureBufferEXT`, and one supplied
an empty list.

The standalone guest EGL probe was not a valid endpoint for this comparison: it
crashed during `eglInitialize` on the normal control as well as both modified
boots. The real TFT process was therefore used as the functional endpoint. All
three profiles reached the running game process, created the main ANGLE/Vulkan
context and four PSO-service contexts, and remained alive without a validation
or renderer crash. Their one-sample cold-start times were 1219 ms for the normal
policy, 1317 ms with only `textureBufferEXT` removed, and 1468 ms with the whole
list cleared. These samples are too few for a performance claim, but neither
modified profile produced a candidate-sized improvement.

More importantly, `dumpsys gpu` reported the same TFT contract for the normal
and fully cleared profiles: Vulkan API `0x401000`, device-feature mask
`0x400b3fbeff3eef`, and identical instance- and device-extension hash lists.
Both created GLES, Vulkan-device, and Vulkan-swapchain state through ANGLE. This
policy is therefore not a hidden shortcut around guest ANGLE or the Vulkan
transport, and no change is promoted. A future test would need an in-package
capability probe plus a full authenticated-match A/B before revisiting it.

The remaining hidden features are not useful macOS transport shortcuts in this
binary. Upstream and bundled-backend inspection show that `ExternalBlob`
explicitly aborts with MoltenVK/external-memory-metal; `SystemBlob` depends on
it and is marked Windows-only; host-visible udmabuf requires Linux kernel
support; and the coherent-memory gates add flushes for compatibility.
`VulkanExternalSync` exports FD/Win32 fence handles and does not provide a
Metal-native synchronization path here.

## Bottleneck assessment

The evidence supports the following confidence levels:

- **High:** the limiting class is graphics command generation/submission,
  guest-host transport, and downstream synchronization/consumption.
- **Medium:** repeated fence/queue boundaries and scene-dependent RHI work are
  more important than raw ASG byte bandwidth alone.
- **Low:** any one currently exposed ANGLE, gfxstream, or MoltenVK flag can
  deliver the roughly 2x improvement needed for 57 FPS in the heavy scene.

The reasons are:

1. ASG versus pipe remains the largest accepted transport improvement, proving
   that the boundary matters.
2. A 16 KiB ASG write step and fewer FBO-boundary submits help, proving that
   packetization/submission frequency matters.
3. Larger rings, shorter/longer flushes, queue/semaphore modes, and multiple
   MoltenVK scheduling flags are neutral or worse, so the residual bottleneck
   is not a single exposed buffer-size knob.
4. FPS drops materially as the board becomes more complex while resolution
   scaling is comparatively weak, which implicates command/RHI and
   synchronization work more than fill rate.
5. Guest profiles contain `AddressSpaceStream` reads/writes and gfxstream
   descriptor work on the RHI thread, while the matching host render threads
   are predominantly waiting for input rather than saturated by decode.
6. Disabling fence contexts, virtual queues, or descriptor batching does not
   improve an auth-independent steady-state render probe, so the residual cost
   is not one exposed gfxstream bookkeeping switch.

## Implementation alternatives

### 1. Keep and instrument the current path

This is the only low-risk near-term choice. Keep the verified Performance Max
stack and instrument both sides of gfxstream before source patches. Required
measurements are writes and bytes per frame, write-size distribution, ring wait
time, kicks, Vulkan submits/fences, host decoder queue/decode time, MoltenVK
submit/completion time, and Metal GPU busy/idle time.

Only then choose between command coalescing, adaptive kicks, descriptor/state
reduction, or host decoder changes. Removing notifications blindly is already
known to destroy pacing.

### 2. Build a source-matched GLES 3.2 host renderer

This remains the highest-upside Android architecture, but its minimum scope is:

- build current ANGLE Metal with verified ES 3.2 contexts on macOS;
- integrate that ANGLE revision with a source-matched gfxstream host backend;
- build and ship the matching Android guest EGL/GLES encoder libraries or a
  matching system image;
- propagate RenderControl caps and guest-advertised ES 3.2 capabilities;
- validate texture buffers, compute, geometry/tessellation, sync, surfaces,
  AHardwareBuffer/gralloc, WebView, login, and a full match;
- measure GLES protocol call volume and ASG backpressure against Vulkan.

This should be a separate R&D branch with conformance-style probes. It is not
appropriate to advertise ES 3.2 in the current binary stack.

### 3. Direct Unreal Vulkan

This removes guest ANGLE but retains Vulkan gfxstream, ASG, MoltenVK, and Metal.
The current Shipping APK disables Vulkan RHI and may lack cooked Vulkan shaders
or PSO data. It is viable only with a Riot build that officially enables the
Vulkan renderer; patching a runtime check is insufficient.

### 4. Native iOS/iPadOS PBE on Apple Silicon

This removes the entire Android VM graphics boundary and has the highest
performance ceiling. It depends on Riot/TestFlight availability and permission
to run that build on Apple Silicon macOS, so it is strategically attractive but
not controlled by this project.

### 5. Physical mobile renderer plus streaming

Run TFT on a phone/tablet, use hardware video encode, and forward input from the
Mac. This trades a separate device and video/input latency for a much simpler
performance model. Unlike scrcpy inside the emulator, encoding does not compete
with TFT in the same VM.

### 6. Replace the VM shell

Moving to Virtualization.framework, crosvm, or another VM shell does not by
itself supply Android-to-Metal GPU passthrough. A virtio-gpu/gfxstream-like
protocol, guest driver, gralloc/HWC integration, and host renderer are still
required. This is high cost with low confidence of removing the measured
bottleneck and is not a priority.

## Recommendation

Do not promote a spoofed native GLES mode. Keep the current supported stack and
promote only full 1-5/1-8 A/B wins with tail-latency and rollback gates. In
parallel, scope the source-matched GLES 3.2 renderer as an independent project;
its first milestone is an ES 3.2 host ANGLE probe that passes real texture-buffer,
compute, sync, and surface tests before any TFT launch attempt.

## Upstream references

- gfxstream source: <https://android.googlesource.com/platform/hardware/google/gfxstream/>
- ANGLE platform and feature EGL extensions:
  <https://chromium.googlesource.com/angle/angle/+/master/include/EGL/eglext_angle.h>
- MoltenVK runtime configuration:
  <https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Configuration_Parameters.md>
