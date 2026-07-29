
                    UNRAID APPDATA BACKUP COPY
                        POWERSHELL EDITION

Version:
    1.0.0

Unraid Appdata Backup Copy copies the newest completed Unraid appdata backup to
a Windows-attached drive.

It is designed for users who already create appdata backups on Unraid and want
an additional Windows-side copy with verification, retention, logs, and optional
Discord notifications.


===============================================================================
1. WHAT THIS UTILITY DOES
===============================================================================

During a normal run, the utility:

1. Checks that the Windows destination drive and Unraid source are available.
2. Finds the newest backup folder named:

       ab_YYYYMMDD_HHMMSS

3. Checks the age of that backup.
4. Waits until the source folder stops changing.
5. Estimates how much data still needs to be copied.
6. Confirms that the destination has enough free space.
7. Copies the backup with Robocopy.
8. Verifies every source file by relative path and exact file size.
9. Keeps the newest configured number of local backups.
10. Writes a permanent log.
11. Sends a Discord result when Discord is enabled.

The Unraid source is treated as read only.


===============================================================================
2. WHAT THIS UTILITY DOES NOT DO
===============================================================================

This utility does not:

- Create the original Unraid appdata backup
- Replace Unraid parity
- Replace snapshots
- Replace an offsite backup
- Modify or delete the Unraid source
- Mirror source deletions
- Use Robocopy /MIR or /PURGE
- Validate the contents of compressed archives
- Check application databases internally
- Hash every copied file

It is an additional copy, verification, retention, logging, and notification
layer for backups that Unraid has already created.


===============================================================================
3. REQUIREMENTS
===============================================================================

Required:

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7
- Robocopy, included with Windows
- Read access to the Unraid backup share
- Write and delete access to the Windows destination
- A destination path beginning with a drive letter, such as E:\

Recommended:

- PowerShell 7
- Windows Task Scheduler for unattended runs
- A Discord webhook for notifications

RUN.cmd automatically uses PowerShell 7 when it is installed and otherwise
falls back to Windows PowerShell 5.1.


===============================================================================
4. FILES IN THE PACKAGE
===============================================================================

Keep these files together in the same folder:

    Unraid_Appdata_Backup_Copy.ps1
    RUN.cmd
    Config.ini
    README.txt
    CHANGELOG.txt

RUN.cmd expects the PowerShell script to be named exactly:

    Unraid_Appdata_Backup_Copy.ps1

Do not rename the .ps1 unless RUN.cmd is also updated.


===============================================================================
5. FIRST-RUN SETUP
===============================================================================

The packaged Config.ini contains placeholder values:

    [Backup]
    Source=\\SERVER\SHARE\BACKUP-FOLDER
    Destination=E:\DESTINATION-FOLDER

    [Discord]
    Webhook=https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN

On the first interactive launch, the utility recognizes those exact
placeholders and opens its built-in setup.

Run:

    RUN.cmd

The setup asks for:

- The source backup path
- The Windows destination path
- An optional Discord webhook

For the source, enter the parent folder containing the Unraid appdata backup
folders.

Example:

    \\tower\share\APPDATA Backup

For the destination, enter the Windows folder where local copies should be
stored.

Example:

    E:\APPDATA Backup

After an accepted path, setup displays a brief confirmation before moving to
the next prompt.

Examples:

    [OK] Source path confirmed and reachable.

    [OK] Destination path accepted; drive E:\ is available.

If a path cannot currently be reached, setup warns you and asks whether to save
it anyway. This allows setup while Unraid or the external drive is temporarily
offline.

Discord is optional.

At the Discord prompt:

- Paste a valid Discord webhook to enable notifications.
- Press Enter to leave Discord disabled.

Webhook entry is hidden and the full credential is not repeated on the summary
screen.

After you confirm the summary, setup writes Config.ini, validates it, and
continues the command you originally launched.

Future runs skip setup as long as Config.ini remains valid and the packaged
placeholders are not restored.


===============================================================================
6. CONFIG.INI
===============================================================================

Config.ini is stored beside the PowerShell script.

Normal example:

    [Backup]
    Source=\\tower\share\APPDATA Backup
    Destination=E:\APPDATA Backup

    [Discord]
    Webhook=https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN

To disable Discord:

    [Discord]
    Webhook=

The entire [Discord] section may also be omitted.

Backup settings
---------------

The [Backup] section requires:

- One Source or Target setting
- One Destination setting

Source may be a UNC path or absolute drive path:

    Source=\\SERVER\Share\Backup

    Source=D:\Test Source

Target may be used instead of Source:

    Target=\\SERVER\Share\Backup

Do not include both Source and Target.

Destination must begin with a drive letter and backslash:

    Destination=E:\APPDATA Backup

Source and Destination cannot be the same path.

Configuration-file rules
------------------------

- Use Section headers such as [Backup] and [Discord].
- Use Key=Value settings.
- Blank lines are allowed.
- Comment lines may begin with ; or #.
- Values containing spaces do not require quotation marks.
- Optional quotation marks are accepted.
- Duplicate keys in the same section are rejected.
- Settings placed before a section header are rejected.
- Inline comments are not removed automatically.

Existing-file protection
------------------------

If first-run recovery replaces a custom or malformed Config.ini, the previous
file is saved as:

    Config.ini.bak-YYYYMMDD_HHMMSS

The untouched packaged placeholder file may be replaced without creating a
placeholder backup.


===============================================================================
7. RUN MODES
===============================================================================

Manual backup
-------------

Run:

    RUN.cmd

Manual mode:

- Runs first-time setup when needed
- Shows interactive confirmation and review pauses
- Allows a stale backup to continue with a warning
- Keeps the final result on screen until a key is pressed

Scheduled backup
----------------

Using Task Scheduler, run:

    RUN.cmd /scheduled

Scheduled mode:

- Never prompts for input
- Does not show interactive pauses
- Rejects stale source backups
- Exits automatically
- Returns a process exit code to Task Scheduler

Complete first-run setup manually before using scheduled mode.

When configuration is missing, invalid, incomplete, or still contains a known
placeholder, scheduled mode stops with exit code 22 instead of waiting for
input.

Discord test
------------

Run:

    RUN.cmd /testdiscord

Discord-test mode:

- Runs first-time setup when needed
- Loads the Discord setting from Config.ini
- Sends a blue test embed
- Does not access the backup source or destination
- Exits 0 when the message is delivered
- Exits 19 when Discord is disabled
- Exits 1 when delivery fails

Direct PowerShell switches
--------------------------

Manual:

    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ".\Unraid_Appdata_Backup_Copy.ps1"

Scheduled:

    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ".\Unraid_Appdata_Backup_Copy.ps1" -Scheduled

Discord test:

    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ".\Unraid_Appdata_Backup_Copy.ps1" -TestDiscord


===============================================================================
8. REQUIRED BACKUP-FOLDER NAME
===============================================================================

The source folder must directly contain at least one backup directory whose
name exactly matches:

    ab_YYYYMMDD_HHMMSS

Example:

    ab_20260727_050002

Ignored examples:

    ab_20260727_050002-failed
    ab_latest
    20260727_050002
    ab_20260727

Matching folder names are sorted newest first.


===============================================================================
9. BACKUP AGE
===============================================================================

Default maximum age:

    48 hours

The timestamp is read from the selected backup-folder name.

Manual mode:

    A stale backup produces a warning and may continue.

Scheduled mode:

    A stale backup stops the run with exit code 20.

Important:

Setting the maximum age to zero does not disable freshness checking. It creates
an extremely strict limit and normally marks every existing backup as stale.


===============================================================================
10. SOURCE STABILITY CHECK
===============================================================================

The utility does not immediately copy the newest backup folder.

It repeatedly checks:

- Recursive file count
- Total file size
- Newest file modification time

The source must remain unchanged for three consecutive one-minute comparisons.

Any detected change resets the stability count.

A source that is already stable normally passes after approximately three
minutes.

The maximum default wait is six hours.

This check strongly suggests that Unraid has finished writing the folder, but it
does not prove archive, database, or application integrity.


===============================================================================
11. FREE-SPACE CHECK
===============================================================================

Before copying, the utility estimates which source files still need to be
transferred.

A destination file is treated as already matching when:

- The same relative path exists
- The byte size matches
- The modification time differs by no more than two seconds

The utility then requires enough free space for:

    estimated remaining copy data + configured reserve

Default reserve:

    50 GB

When no data appears to need copying, the reserve is not required for that run.

Robocopy remains the final authority on which files are copied.


===============================================================================
12. ROBOCOPY TRANSFER
===============================================================================

The copy uses Robocopy with:

    /E
    /COPY:DAT
    /DCOPY:DAT
    /J
    /FFT
    /R:2
    /W:5
    /ETA
    /TEE

In practical terms, this means:

- All subfolders are copied, including empty folders.
- File and folder data, attributes, and timestamps are preserved.
- Unbuffered I/O is used.
- Two-second timestamp precision is allowed.
- Failed copies are retried twice.
- Each retry waits five seconds.
- Progress and estimated completion information are displayed.
- Robocopy output is also written to the current-run log.

The utility deliberately does not use:

    /MIR
    /PURGE

Extra files are not automatically deleted during the transfer.


===============================================================================
13. ROBOCOPY RESULTS
===============================================================================

Robocopy uses return codes that differ from many ordinary programs.

The utility interprets them as:

    0-3    Successful
    4-7    Completed with warning
    8+     Fatal failure

Codes 4 through 7 may still produce a completed result, but only when
post-copy verification passes and retention succeeds.

Codes 8 and above stop the run before retention.


===============================================================================
14. POST-COPY VERIFICATION
===============================================================================

After Robocopy, the utility independently compares the source and destination.

For every source file it checks:

1. The same relative path exists at the destination.
2. The destination file has exactly the same byte size.

Verification passes only when:

- No source file is missing
- No source file has the wrong size
- All source bytes are represented by matching destination files

Extra destination files are logged but do not independently fail verification.

The log may list up to the first 20:

- Missing paths
- Wrong-size paths
- Extra paths

This verification does not use cryptographic hashes. Equal-size files with
different contents would not be detected.


===============================================================================
15. LOCAL RETENTION
===============================================================================

Default number of local backups kept:

    10

Retention considers only direct child folders beneath Destination whose names
exactly match:

    ab_YYYYMMDD_HHMMSS

The newest matching folders are kept and older matching local folders are
removed.

Retention:

- Never targets the Unraid source
- Ignores nonmatching local folders
- Runs only after verification passes
- Logs each folder before deletion

A failed verification prevents retention.


===============================================================================
16. DISCORD NOTIFICATIONS
===============================================================================

Discord notification types:

Blue:
    Webhook test

Green:
    Clean completion

Yellow:
    Manual stale-backup warning
    Completed-with-warning result

Red:
    Fatal failure

Completion notifications may include:

- Backup name
- Verification status
- Files copied
- Data copied
- Failure count
- Total time
- Average speed
- Remaining destination space
- Robocopy result and code
- Freshness details
- Utility version

Failure notifications may include:

- Stage
- Reason
- Backup name
- Exit code
- Robocopy code
- Technical details
- Log path
- Utility version

A Discord delivery problem does not turn an otherwise successful backup into a
failed backup.

The configured webhook is redacted from Discord-delivery diagnostic text.


===============================================================================
17. LOGS
===============================================================================

If Destination is:

    E:\APPDATA Backup

the log folder is:

    E:\APPDATA Backup LOGS

Example permanent log:

    Unraid-Appdata-Copy-20260728_205751_631.log

Logs may contain:

- Start and completion information
- Selected source and destination
- Backup age
- Stability results
- Free-space estimate
- Robocopy output and return code
- Verification summary
- Verification problem paths
- Retention deletions
- Discord-delivery diagnostics
- Failure details

Temporary Robocopy logs are normally removed after successful parsing.

They may be retained when:

- Robocopy fails fatally
- Summary parsing fails
- Diagnostic output is needed

Permanent logs are not automatically pruned.


===============================================================================
18. RESULT TYPES
===============================================================================

Clean success
-------------

A clean success means:

- Setup and configuration passed
- Source checks passed
- Stability passed
- Space check passed
- Robocopy returned 0 through 3
- Verification passed
- Retention succeeded

Result:

- Green Discord embed when enabled
- Checkmark completion screen
- Exit code 0

Completed with warning
----------------------

Common causes:

- A stale backup was accepted in manual mode
- Robocopy returned code 4 through 7

Verification and retention must still succeed.

Result:

- Yellow Discord embed when enabled
- Warning completion screen
- Exit code 0

Failure
-------

Examples:

- Missing or invalid configuration
- Destination drive unavailable
- Source unavailable
- No correctly named backup folder
- Scheduled stale backup
- Stability timeout
- Insufficient free space
- Fatal Robocopy result
- Verification failure
- Retention failure

Result:

- Red Discord embed when available
- Failure screen
- Nonzero exit code


===============================================================================
19. WINDOWS TASK SCHEDULER
===============================================================================

Complete one successful manual run before creating the scheduled task.

Recommended action:

Program/script:

    C:\Windows\System32\cmd.exe

Arguments:

    /c ""C:\Scripts\Unraid Appdata Backup\RUN.cmd" /scheduled"

Start in:

    C:\Scripts\Unraid Appdata Backup

Recommended task settings:

- Run under a Windows account with access to the Unraid share
- Run whether the user is logged on or not, if desired
- Wake the computer to run the task, if desired
- Run as soon as possible after a missed start, if desired
- If the task is already running:
      Do not start a new instance

The utility does not currently include an internal single-instance lock.
Prevent overlapping runs through Task Scheduler.

Schedule the Windows copy after the Unraid backup is expected to begin or
finish. The stability check protects against a changing source, but a sensible
start time reduces unnecessary waiting.


===============================================================================
20. TROUBLESHOOTING
===============================================================================

First-run setup appeared unexpectedly
-------------------------------------

Setup appears when Config.ini is:

- Missing
- Malformed
- Incomplete
- Using one of the exact packaged placeholders
- Using a malformed nonblank webhook

Check that Config.ini is beside the PowerShell script and is not accidentally
named Config.ini.txt.

Scheduled mode says setup is incomplete
---------------------------------------

Scheduled mode never pauses or prompts the user.

Run:

    RUN.cmd

Complete setup manually, then try the scheduled task again.

Config.ini could not be saved
-----------------------------

Check:

- The package was extracted from the ZIP
- The package folder is writable
- Config.ini is not read only
- Another program is not locking Config.ini
- Security software is not blocking PowerShell

Discord notifications are disabled
----------------------------------

Check:

- Config.ini contains [Discord]
- Webhook is present and not blank
- The URL begins with:

      https://discord.com/api/webhooks/

Discord delivery fails
----------------------

Check:

- The webhook still exists
- It has not been deleted, regenerated, or revoked
- Windows can reach Discord over HTTPS
- Security software is not blocking PowerShell
- System date and time are correct

Run:

    RUN.cmd /testdiscord

Source unavailable
------------------

Check:

- Open the exact UNC path in File Explorer
- Confirm Unraid and SMB are online
- Confirm the current or scheduled Windows account has share access
- Prefer UNC paths over mapped drive letters for network sources

Destination drive unavailable
-----------------------------

Check:

- The external drive is connected
- The configured drive letter is correct
- The drive mounted before the run began

No valid source backup found
----------------------------

Confirm that Source directly contains a folder named like:

    ab_20260727_050002

Backup unexpectedly reported stale
----------------------------------

Check:

- Timestamp in the backup-folder name
- Windows system clock
- MaximumBackupAgeHours
- Whether the Unraid backup actually ran

Stability never reaches 3/3
---------------------------

Possible causes:

- Unraid is still writing the backup
- A file continues to change
- The source folder is empty
- SMB enumeration is intermittently failing

Review the stability entries in the permanent log.

Insufficient free space
-----------------------

The destination must have room for the estimated remaining copy data plus the
configured reserve.

Robocopy summary parsing failed
-------------------------------

Review the retained temporary Robocopy log.

The parser expects English Robocopy summary labels.

Verification failed
-------------------

Review the log for:

- Missing files
- Wrong-size files
- Source and destination counts
- Source and destination sizes
- First affected paths

Do not manually delete older backups until the cause is understood.

An unexpected error occurred
----------------------------

Read:

- Stage
- Details
- Permanent log, when one was created
- Discord failure embed, when delivered

Details contains PowerShell's original exception message and often identifies
the cause directly.

Manual runs work but scheduled runs fail
----------------------------------------

Check:

- Task account
- Stored password
- Network-share permissions
- Destination-drive availability
- Start-in directory
- /scheduled spelling
- Task history
- Utility log


===============================================================================
21. EXIT CODES
===============================================================================

    0    Success or completed with warning

    1    Unexpected failure, missing Robocopy, or Discord-test delivery failure

    10   Destination drive unavailable
    11   Source unavailable
    12   No valid ab_YYYYMMDD_HHMMSS source folder found
    13   Log directory or log file could not be created
    14   Local destination folder could not be created
    15   Retention cleanup failed
    16   Stability wait timed out
    17   Robocopy temporary log missing or could not be appended
    18   Robocopy summary parsing failed
    19   Discord test could not run because Discord was disabled
    20   Scheduled run rejected a stale backup
    21   Backup timestamp could not be validated
    22   Configuration is missing, invalid, incomplete, placeholder-based,
         unable to be saved, or an internal policy is invalid
    23   Free-space calculation failed
    24   Insufficient destination free space
    25   Verification process could not complete
    26   Destination failed path-and-size verification
    27   Invalid or conflicting command-line arguments

    8+   Fatal Robocopy return codes may be returned directly

When diagnosing a failure, read the Stage, Reason, Details, and log rather than
relying on the number alone.


===============================================================================
22. DEFAULT SETTINGS
===============================================================================

The default internal policies are:

    Local backups retained:    10
    Maximum source age:        48 hours
    Free-space reserve:        50 GB
    Stability requirement:     3 unchanged one-minute comparisons
    Maximum stability wait:    6 hours

These settings are defined near the beginning of the PowerShell script.


===============================================================================
23. KNOWN LIMITATIONS
===============================================================================

- Verification is based on relative path and file size, not file hashes.
- Source completion is inferred from stability.
- Backup folders must use the exact ab_YYYYMMDD_HHMMSS naming pattern.
- Robocopy summary parsing expects English output.
- There is no internal single-instance lock.
- Destination identity is based on drive letter, not volume serial number.
- Extra destination files are allowed by design.
- Empty directories are copied but not independently verified.
- Discord webhooks are stored as plain text in Config.ini.
- Permanent logs are not automatically pruned.
- There is no rollback if retention partially succeeds before an error.
- Archive contents and application databases are not internally validated.


===============================================================================
24. QUICK REFERENCE
===============================================================================

First/manual run:

    RUN.cmd

Scheduled run:

    RUN.cmd /scheduled

Discord test:

    RUN.cmd /testdiscord

Configuration file:

    Config.ini

Required source-folder format:

    ab_YYYYMMDD_HHMMSS

Default retention:

    10 local backups

Normal result:

    Green embed
    Checkmark screen
    Exit code 0

Warning result:

    Yellow embed
    Warning screen
    Exit code 0

Failure result:

    Red embed when available
    Failure screen
    Nonzero exit code

Safety summary:

    Unraid source is read only
    Robocopy does not use /MIR or /PURGE
    Retention affects matching local backup folders only
    Retention runs only after verification passes

===============================================================================
LICENSE
===============================================================================

This project is released under the MIT License.

Copyright (c) 2026 toml12791

See LICENSE for the complete license terms.

===============================================================================
END OF README
===============================================================================
