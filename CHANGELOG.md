# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog and semantic versioning.

## [0.0.8] - 2026-02-27

### Changed
- Made field editing UI more compact: removed repeated per-row `Field key`/`Field value` labels and switched to shared `Key`/`Value` column headers.

### Fixed
- Added explicit top-left close control for `Import Kubeconfig as New Entries` sheet.
- Added explicit top-left close control for `Quick Add AWS EKS` sheet and removed duplicate right-side close action.

## [0.0.7] - 2026-02-27

### Added
- Added a dedicated `Quick Add AWS EKS` flow in the UI to create AWS EKS context/cluster/user from structured fields.

### Changed
- AWS EKS quick-add now generates `exec` configuration with required arguments and optional `env` (`AWS_PROFILE`) automatically.
- Test fixtures were sanitized to use mock AWS identifiers/profiles (`mock-eks`, `mock-aws-profile`).

## [0.0.6] - 2026-02-26

### Changed
- Increased default app window size on launch and widened the left sidebar using content-aware ideal width.
- Added right-click context menu actions (`Delete`) for contexts, clusters, and users in the sidebar.
- Workspace storage flow was redesigned: for each opened kubeconfig, the app now uses a sidecar workspace file next to it (`.<filename>.kce.yaml`) and keeps per-file git history in a local sidecar repository.
- YAML background validation is now enabled by default.

### Fixed
- Update install flow now force-terminates the app if graceful termination hangs after scheduling updater.
- Update actions are now consistently disabled across updates sheet and toast as soon as install starts.
- Version history now records the initial loaded state for a file (baseline snapshot) and can restore workspace state if the sidecar file is missing.

### Added
- Unit tests for sidecar workspace behavior: metadata comments persistence, hidden/export state restoration on reload, and workspace recovery from git history.

## [0.0.5] - 2026-02-26

### Fixed
- Made update availability checks deterministic to avoid stale same-version update prompts.

## [0.0.4] - 2026-02-26

### Fixed
- Update toast and install guard now ignore same-version releases and show updates only when a newer version exists.

## [0.0.3] - 2026-02-26

### Changed
- In-app update flow now asks for confirmation before install and automatically saves unsaved changes before starting update.
- Update button styling/state was adjusted for installation flow: while update is in progress, it is no longer highlighted and remains disabled.

## [0.0.2] - 2026-02-26

### Changed
- Release pipeline now triggers on `main` only when `VERSION` changes (manual trigger kept).
- Release workflow updated for modern macOS runner and explicit Xcode setup to ensure Swift 6.2+ toolchain.
- Local/release build flow switched to isolated relative build/cache paths to avoid absolute-path module cache conflicts across machines.
- README updated with quarantine removal command and refreshed build paths/examples.
- Update checker UI now shows latest known release version and explicit "up to date" status instead of ambiguous "not available".

### Fixed
- GitHub Actions `release.yml` YAML syntax issues in embedded Python steps.
- Kubeconfig serialization now normalizes `exec.provideClusterInfo` to boolean (`true/false`) to prevent kubectl/Lens parsing failures when numeric values (`0/1`) appear.

## [0.0.1] - 2026-02-24

### Added
- Native macOS SwiftUI app for kubeconfig editing.
- Tabbed workspace for `Contexts`, `Clusters`, and `Users`.
- Create, edit, rename, and remove contexts/clusters/users.
- Multi-selection in sidebar and bulk delete operations.
- Export selected contexts into standalone kubeconfig file.
- Context visibility toggle (`eye`): include/exclude in final kubeconfig export.
- Full-text kubeconfig import and merge workflows.
- Merge preview for context import with selective apply.
- Safety model: in-memory/draft editing, write to target only on explicit save.
- Save/Save As and backup actions.
- "Set as current + save" flow for default context updates.
- YAML validation before save and optional background auto-validation.
- Optional kubectl validation integration before save.
- Built-in diagnostics and warnings for broken references between entities.
- Embedded git history (libgit2 via SwiftGitX) with:
  - snapshot commit on save,
  - version history view,
  - rollback to chosen version.
- Undo/redo stack for local step-by-step changes.
- Session/file-scoped history isolation.
- Legacy history compatibility: reads versions from old and new repository key formats.
- In-app update checker (GitHub Releases):
  - background check on launch,
  - bottom-right update toast,
  - one-click auto-update for installed `.app`.
- DMG packaging script with icon generation and optional code signing.

### Changed
- Improved top action layout and clearer action labels.
- Version history sheet got explicit close controls and keyboard shortcuts.
- Sidebar got search and A-Z / Z-A sorting.

### Fixed
- File picker and content-type handling issues on macOS.
- Selection behavior in list rows and multi-select edge cases.
- Context panel stale-field rendering bugs when switching between items.
- Current-context consistency when hiding/export-filtering contexts.
- Missing history after migration to per-file session keys.
