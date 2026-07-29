===============================================================================
CHANGELOG - UNRAID APPDATA BACKUP COPY
===============================================================================

Version 1.0.0
-------------

Initial public release.

Highlights:

- Native Windows PowerShell 5.1 and PowerShell 7 support
- Built-in first-run setup for missing, incomplete, invalid, or untouched
  placeholder configuration
- Manual, scheduled, and Discord-test run modes
- Exact newest-backup discovery using the ab_YYYYMMDD_HHMMSS naming format
- Backup-age validation with manual warning and scheduled failure behavior
- Three consecutive source-stability checks before transfer
- Remaining-copy estimation with configurable free-space reserve
- Restart-friendly Robocopy transfer with retries, ETA, and current-run logging
- Robocopy return-code parsing and success, warning, or failure classification
- Independent post-copy verification by relative path and exact file size
- Verification-gated local retention of the newest matching backup folders
- Read-only treatment of the Unraid source
- Permanent per-run logs with retained diagnostic Robocopy logs when needed
- Structured Discord test, success, warning, and failure embeds
- Webhook redaction in Discord delivery diagnostics
- Centralized handling of expected operational failures and unexpected
  PowerShell exceptions
- Current-stage tracking and detailed failure screens
- Unified Config.ini for backup paths and optional Discord configuration
- Automatic Config.ini writing, re-import, and validation before continuing
- Scheduled-mode refusal to display interactive configuration prompts
- Invalid and conflicting command-line argument rejection
- Released under the MIT License
