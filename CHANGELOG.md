# Changelog

The current application metadata is version 1.0.7, build 43.

## Unreleased

No changes yet.

## 1.0.7 — 2026-08-22

### Fixed

- Restore the branded active-game Dock icon instead of showing the generic
  `qemu-system-aarch64` executable icon.

## 1.0.6 — 2026-08-20

### Changed

- Sign the launcher and bundled game host with Apple Developer ID, enable the
  hardened runtime, and notarize the release for standard Gatekeeper approval.

## 1.0.5 — 2026-08-15

### Added

- Add a reversible **Maximum FPS** graphics-detail preset that selects the
  audited 67% 3D-scale Performance Max profile from the app.

## 1.0.4 — 2026-08-14

### Fixed

- Restore four asynchronous OpenGL PSO compiler services when a TFT update
  disables them in its inherited Android device profile, avoiding first-use
  shader compilation stalls on the gameplay render path.

## 1.0.3 — 2026-08-14

### Changed

- Check the signed TFT PBE feed when the launcher becomes ready.
- Show **Update game** in place of **Play** only when a newer verified game
  version is available.
- Prevent starting a known-outdated game build until its update completes.

## 1.0.2 — 2026-08-13

### Fixed

- Check for Mactician updates on every launch instead of waiting only for the
  daily Sparkle schedule.
- Show an explicit localized result after a game update check, including the
  installed TFT PBE version when no newer hosted build is available.
- Record completed game update checks in the launcher log.

## 1.0.1 — 2026-08-13

### Added

- Added a separately signed TFT PBE update channel hosted on
  `sergeinaumov.dev`.
- Added in-place split APK updates that preserve Riot sign-in and local game
  data.

## 1.0.0 — 2026-08-10

### Added

- Initial public version of Mactician.

### Changed

- Restyled the active game Dock icon as a distinct Mactician play variant and
  replaced the Android Emulator title with `Mactician: TFT PBE`.
- Reduced Trial benchmark preparation from roughly 20 seconds to 1–3 seconds
  by overlapping one shop decision with combat and batching reward, XP, item,
  and replay actions.
- Preserved valid measurements across same-emulator Trial retries, added a
  bounded same-combat capture retry, and repaired early-exit cleanup after a
  launcher crash.
- Updated Performance Max with the confirmed 67% effects/LOD profile and a
  16 KiB ASG write step; repeated Trial 1-8 proxies remained above 30 FPS.
