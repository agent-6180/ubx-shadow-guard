# UBX Shadow Guard

**Version: 0.5.0** — PowerShell utility for configuring scheduled Windows Volume Shadow Copy Service (VSS) snapshots on fixed local volumes.

**Repository:** [Steve Panovski / ubx-shadow-guard](https://github.com/agent-6180/ubx-shadow-guard)  
**Organization:** [UBX Cloud](https://www.ubxcloud.com)  
**Maintainer:** Steve Panovski (@agent-6180)

```text
 _   _ ____  __  __
| | | | __ ) \ \/ /
| | | |  _ \  \  /
| |_| | |_) | /  \
 \___/|____/ /_/\_\
       C L O U D
```

**Artwork attribution:** The original UBX ASCII logo is credited by the project owner to **Philip (Phillip) Simjanovski (2026)**. The replacement wordmark above and in the script is **not a verified copy** of his original. See [NOTICE.md](NOTICE.md).

## Capabilities

- Creates client-accessible VSS shadow copies using CIM (`Win32_ShadowCopy.Create`), with WMI as a fallback; does not depend on `vssadmin create shadow`.
- Registers 24 daily hourly triggers per selected volume, running as SYSTEM.
- Enforces saved include/exclude and volume-label policy for scheduled and manual snapshots.
- Accepts fixed NTFS/ReFS volumes at least 10 GB in size with at least 1 GB free.
- Supports configurable VSS quota (default **10%**) and JSON configuration/state.
- Records per-volume outcomes in state and file/event logs.
- Supports installation, non-destructive configuration repair, status, on-demand snapshots and uninstall.

## Requirements and examples

- Windows PowerShell **5.1** and Administrator permissions; Windows 10/11 or Windows Server 2019+ are the intended targets, **not yet runtime validated**.
- Installation and state files default to `C:\Source\UBXShadowGuard`.
- Save `ubxshadow_guard.ps1` to disk and run from an elevated Windows PowerShell session.

```powershell
.\ubxshadow_guard.ps1 -Status
.\ubxshadow_guard.ps1 -Install -Quota '10%' -ExcludeVolumes 'E:'
.\ubxshadow_guard.ps1 -RunOnce -Volume 'C:'
.\ubxshadow_guard.ps1 -Repair
.\ubxshadow_guard.ps1 -Repair -Quota '15%'
.\ubxshadow_guard.ps1 -Uninstall
```

**Policy and operational behavior (v0.5.0):**

- `-Repair` retains the existing quota, include/exclude lists, and backup-volume override unless you explicitly supply new values.
- Existing invalid or unreadable saved configuration causes an error rather than silent reset.
- During scheduled `-RunOnce`, the script **does not** change service startup types or shadow-storage quotas; it checks current policy and creates the shadow copy.
- Install/repair updates the schedule and removes obsolete Shadow Guard scheduled tasks for volumes that are no longer selected.
- Use `-ExcludeVolumes @()` (from a PowerShell call, not a shortcut alias) if you intentionally need to clear an exclusion list.
- Changes to VSS shadow-storage quotas **can evict existing shadow copies**. Use explicit maintenance windows when possible.

## Documentation and tests

- [Changelog](CHANGELOG.md) — fixes and migration notes for v0.5.0
- [Review](REVIEW.md) — addressed defects and outstanding validation requirements
- [Notices and attribution](NOTICE.md) — provenance, ownership, usage cautions
- [Static PowerShell checks](tests/Check-Static.ps1) — syntax and safety invariants; [Windows CI workflow](.github/workflows/windows-powershell-static.yml)
- [PowerShell source](ubxshadow_guard.ps1)

**Production warning:** Shadow copies are not substitutes for independently verified, off-host backups. The code has undergone static review, but **Windows/VSS/runtime integration tests have not yet been completed here**. Validate in a lab prior to production use.

No open-source license has been designated. Repository visibility does not grant reuse or distribution rights.

*Made in Michigan. Building clouds before they were cool.*
