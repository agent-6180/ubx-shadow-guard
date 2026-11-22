# UBX Shadow Guard — technical review (v0.5.0)

**Scope:** Source-level review of the uploaded `ubxshadow_guard(2).ps1` and subsequent changes committed to `ubxshadow_guard.ps1` on 2026-11-22. These are code fixes **not yet validated by a live Windows/VSS integration test**. See [CHANGELOG.md](CHANGELOG.md).

## Addressed in v0.5.0

| Original finding | Remediation | Status |
| --- | --- | --- |
| Unsupported `vssadmin create shadow` fallback | Removed. Shadow creation now uses CIM and then WMI; existing method orders are migrated. | Code fixed |
| `-Repair` overwrites quota and exclusions | Only explicitly supplied overrides replace existing values; all other saved policy stays intact. | Code fixed |
| Invalid saved configuration can silently reset protection | Invalid/empty saved `config.json` now raises an error instead of using defaults. | Code fixed |
| Repair or snapshot may run without installed policy | `-Repair` requires existing config, validates prior to service or installation mutations; `-RunOnce` requires a saved config. | Code fixed |
| Installing from the installed path copies script onto itself | Compare canonical paths and skip the copy when identical. | Code fixed |
| Numeric `continue 2` in excluded-label scanning | Replaced with explicit match-then-skip outer volume iteration. | Code fixed |
| Volumes lacking sufficient free space or suitable filesystems | NTFS/ReFS and 1-GB free-space guard added; volume still must be fixed and >=10 GB. | Code fixed |
| `-RunOnce` bypasses exclusion policy | Requested volume must match current policy and protective eligibility checks. | Code fixed |
| Scheduled snapshots mutate service configuration and VSS quota | Removed these actions from scheduled `-RunOnce`; VSS health failures log an interactive repair recommendation. | Code fixed |
| Changes to service startup types during repair | Existing non-disabled service startup types are now retained. | Code fixed |
| Stale tasks persist for excluded volumes | Install/repair prunes obsolete Shadow Guard tasks after current task registration. | Code fixed |
| Failed shadow-storage quota adjustment is ignored | Install/repair now stops rather than silently proceeding with task registration. | Code fixed |
| Sequential stdout/stderr reads can deadlock | Drains both redirected streams asynchronously and disposes the process. | Code fixed |
| Inconsistent source version comments | Both identify v0.5.0. | Code fixed |

## Remaining risks / verification

- **Windows runtime testing is required.** Validate `-Install`, `-Status`, `-Repair`, `-RunOnce`, `-Uninstall`, scheduled SYSTEM execution, CIM and WMI, on each intended Windows desktop/server version.
- **Snapshot retention is not guaranteed.** Quota changes can evict existing snapshots; VSS may decline creation due to provider behavior, limits, or free-space pressure. The 1-GB guard is a floor, not a VSS capacity guarantee.
- **Uninstall and repair remain privileged operations.** In explicit repair, disabled services may be enabled and started; `-ResetShadowStorage` adjusts quota to 10% if requested.
- **Testing scope remains static.** The repo includes a Windows PowerShell 5.1 parser/invariant GitHub Actions workflow, but a passing check does not prove correct VSS operation. Workflow status should be checked separately on GitHub.
- **Configuration backup is recommended.** Preserve `config.json` and `state.json` before testing upgrades on live systems. Per-volume state is informational and does not prove recoverability.

## Suggested lab acceptance test

1. Run `-Status` and save current volumes/VSS state and quota information.
2. Install with an explicit include list and `-NoInitialSnapshot`; verify tasks and quotas.
3. Create a manual `-RunOnce` snapshot and verify it appears in Windows VSS inventory.
4. Add an exclusion; run `-Repair` with no other overrides and verify quota/policy are preserved.
5. Confirm `-RunOnce` rejects excluded volumes and repair removes their scheduled tasks.
6. Run scheduled tasks as SYSTEM; confirm snapshot creation and unchanged service startup policies.
7. Exercise fallback behavior on a disposable lab VM, and verify uninstall and preexisting snapshot retention.

Do not treat shadow copies as substitutes for verified off-host backups.
