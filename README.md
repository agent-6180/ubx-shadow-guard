# UBX Shadow Guard

PowerShell utility for configuring scheduled Windows Volume Shadow Copy Service (VSS) snapshots on fixed local volumes.

**Repository:** [Steve Panovski / ubx-shadow-guard](https://github.com/agent-6180/ubx-shadow-guard)  
**Organization:** [UBX Cloud](https://www.ubxcloud.com)  
**Maintainer:** Steve Panovski (@agent-6180)

     _   _ ____  __  __
    | | | | __ ) \ \/ /
    | | | |  _ \  \  /
    | |_| | |_) | /  \
     \___/|____/ /_/\_\
           C L O U D

**Artwork attribution:** The original UBX ASCII logo is credited by the project owner to **Philip (Phillip) Simjanovski (2026)**. The replacement wordmark above and in the script is **not a verified copy** of his original. See [NOTICE.md](NOTICE.md).

## Capabilities

- Enumerates fixed local volumes with include/exclude policies and skips volumes commonly labeled as backup or repository storage.
- Configures shadow storage (default **10%**) and 24 daily hourly task triggers per volume, running as SYSTEM.
- Attempts VSS creation via CIM, then vssadmin, then WMI.
- Tracks per-volume last outcome in JSON and writes file/event logs.
- Supports install, repair, status, single-run and uninstall operations.

## Requirements and quick start

Windows PowerShell **5.1**, elevated Administrator permissions. The script declares Windows 10/11 and Windows Server 2019+ as targets, but compatibility has **not** been verified in this review. Installs to C:\Source\UBXShadowGuard.

Run from an elevated PowerShell session:

    .\ubxshadow_guard.ps1 -Status
    .\ubxshadow_guard.ps1 -Install -Quota '10%' -ExcludeVolumes 'E:'
    .\ubxshadow_guard.ps1 -RunOnce -Volume 'C:'
    .\ubxshadow_guard.ps1 -Repair
    .\ubxshadow_guard.ps1 -Uninstall

## Important notices

**Do not deploy this untested script directly to production.** VSS snapshots are not a substitute for off-host backups. Adjusting VSS shadow-storage limits can delete existing recovery points. Confirm exclusions and storage quotas before installation.

No open-source license has been explicitly designated. A public repository does **not** itself grant permission for reuse or redistribution. See [NOTICE.md](NOTICE.md).

The static review identified production risks, including a broken vssadmin fallback and unexpected configuration resets during -Repair. See [REVIEW.md](REVIEW.md) before deploying.

**Source:** [ubxshadow_guard.ps1](ubxshadow_guard.ps1)

*Made in Michigan. Building clouds before they were cool.*
