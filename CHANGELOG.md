# Changelog

All notable changes to UBX Shadow Guard are documented here. Versions refer to the PowerShell utility, not Microsoft VSS.

## [0.5.0] - 2026-11-22

### Fixed
- Removed the unreliable `vssadmin create shadow` path (not available on all Windows editions). Shadow creation now uses `Win32_ShadowCopy.Create` via CIM, then legacy WMI as fallback; old `MethodOrder` settings are migrated.
- `-Repair` now **preserves** saved `Quota`, `IncludeVolumes`, `ExcludeVolumes`, `ForceProtectLikelyBackupVolumes`, and `PreferCachedMethod` unless applicable policy options are explicitly supplied.
- Malformed/empty existing `config.json` now fails closed instead of silently resetting volume protection settings.
- `-Install` / `-Repair` no longer copy the script over itself when already executed from the installation path.
- Excluded-label filtering no longer relies on a numeric `continue 2` statement.
- External command stdout/stderr are read concurrently to prevent pipe-buffer deadlocks.

### Hardened
- `-RunOnce` and scheduled snapshot jobs validate the requested volume against saved include/exclude and label policy, fixed-disk type, supported NTFS/ReFS filesystem, minimum 10-GB volume size, and 1-GB available-space floor.
- Scheduled `-RunOnce` no longer adjusts VSS shadow-storage quota or changes services. VSS failures log an instruction to run `-Repair` manually, rather than automatically changing service configuration.
- Service repair preserves non-disabled service startup policies.
- `-Install` / `-Repair` stop if configuring a selected volume's VSS quota fails.
- `-Install` / `-Repair` remove obsolete Shadow Guard scheduled tasks after registering the currently selected volumes.

### Documentation and quality
- Clarified interactive UBX ASCII wordmark attribution and repository notices.
- Updated README and review findings.
- Added a Windows PowerShell 5.1 syntax/static check designed to run on GitHub Actions (CI availability/configuration not guaranteed).

### Compatibility / migration notes
- Previously saved method preferences containing `VSSADMIN` are migrated to `CIM, WMI` during `-Install` or `-Repair`.
- The 1-GB free-space safety threshold may newly exclude nearly full volumes.
- `-Repair` now retains existing policy by default. To change policy, explicitly specify the desired option. To clear an inclusion/exclusion list, pass an explicit empty array (e.g. `-ExcludeVolumes @()`) from PowerShell.
- Quota resizing can evict existing snapshots. Verify off-host backups before installing or repairing.

### Validation status
- Static review and source invariants completed; Windows PowerShell 5.1 CI parser check added.
- **No live Windows Server/Windows 11 runtime, VSS provider, or scheduled-task integration test has been performed here.** Lab validation remains required before production use.

## [0.4.0] - Earlier 2026 (date not established)

- Initial Windows PowerShell 5.1 compatible process runner and CIM-based adaptive VSS scheduling implementation, as identified by the uploaded source.
- A later branding update added a UBX ASCII replacement wordmark and notices. See [NOTICE.md](NOTICE.md) for original logo attribution.

> Earlier version history is reconstructed only from the uploaded script's version comments and prior repository commits.
