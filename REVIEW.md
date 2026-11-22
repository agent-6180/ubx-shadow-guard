# Static review of uploaded ubxshadow_guard(2).ps1

**Review scope:** Read-only inspection of the supplied 1,032-line script. No Windows execution, VSS operation, or PowerShell parser/runtime validation was possible in this environment. The published ubxshadow_guard.ps1 contains **branding and notice changes only**; VSS and scheduling logic remains the same.

## Findings to address before production deployment

1. **High — invalid VSSADMIN fallback.** New-ShadowViaVssAdmin invokes vssadmin.exe create shadow /for=..., a command not supported on the Windows build seen in earlier Shadow Guardian logs. The attempted fallback fails before WMI is tried.
2. **High — -Repair resets persisted configuration.** Invoke-InstallOrRepair overwrites Quota, IncludeVolumes, ExcludeVolumes and ForceProtectLikelyBackupVolumes with parameter defaults even when those arguments were omitted. A plain -Repair may erase intentional policy.
3. **High — installed-script self-copy may fail.** Install-Self always copies $PSCommandPath to C:\Source\UBXShadowGuard\ubxshadow_guard.ps1, even when that is the same file.
4. **Medium — loose volume selection.** Get-ProtectableVolumes selects fixed volumes >=10GB but has no free-space threshold or explicit filesystem validation. -RunOnce -Volume does not enforce configured exclusions.
5. **Medium — service startup changes are intrusive.** Repair-CoreServices may change winmgmt and other service start types and is also invoked by hourly execution.
6. **Medium — versions disagree.** Synopsis identifies v0.3; description says v0.4.
7. **Medium — external process deadlock risk.** Invoke-ExternalCommand reads stdout to completion before stderr; a large stderr pipe can block the child.

## Positive aspects

- CIM-first VSS creation; no WMIC executable dependency.
- Structured JSON configuration and per-volume state.
- Default exclusions for backup/repository-labeled volumes.
- Structured file/event logging and dedicated SYSTEM scheduled tasks.

## Publishing boundaries

New branding displays on -Install, -Repair, -Status and -Uninstall only, not on scheduled -RunOnce jobs. No service, quota, volume-selection or scheduling code was intentionally changed.
