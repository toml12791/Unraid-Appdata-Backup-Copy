          __________________________
         /_________________________/|
        |  _____________________  | |
        | |                     | | |
        | |   UNRAID APPDATA    | | |
        | |    BACKUP COPY      | | |
        | |_____________________| | |
        |    O               O    | /
        |_________________________|/

**Version 1.0.0**

A Windows PowerShell utility that copies the newest completed Unraid appdata backup to a Windows-attached drive, verifies the copied files, applies local retention, writes detailed logs, and can send Discord notifications.

> This utility does **not** create the original Unraid backup. It adds a second Windows-side copy and verification layer for backups Unraid has already created.

## Highlights

- Finds the newest backup matching `ab_YYYYMMDD_HHMMSS`
- Checks backup age before copying
- Waits until the source folder is stable
- Estimates the remaining copy size and required free space
- Uses restart-friendly Robocopy transfers
- Verifies every source file by relative path and exact byte size
- Retains only the newest configured local backup folders
- Supports manual, scheduled, and Discord-test modes
- Runs on Windows PowerShell 5.1 or PowerShell 7
- Treats the Unraid source as read-only
- Never uses Robocopy `/MIR` or `/PURGE`

## Safety model

The utility is deliberately conservative:

- The Unraid source is never deleted from or modified.
- Retention applies only to matching backup folders beneath the local destination.
- Retention runs only after copy verification succeeds.
- Nonmatching destination folders are ignored.
- Extra destination files are reported but are not automatically deleted.
- A failed verification prevents retention.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7
- Robocopy, included with Windows
- Read access to the Unraid backup share
- Write and delete access to the Windows destination
- A destination path beginning with a drive letter, such as `E:\`

PowerShell 7 is recommended but not required. `RUN.cmd` uses PowerShell 7 when available and otherwise falls back to Windows PowerShell 5.1.

## Quick start

1. Download or clone the repository.
2. Run:

```bat
RUN.cmd
```

3. Complete the built-in setup when prompted. This will create a working config file.
4. Run a successful manual backup before creating a scheduled task.

A typical configuration looks like this:

```ini
[Backup]
Source=\\tower\share\APPDATA Backup
Destination=E:\APPDATA Backup

[Discord]
Webhook=https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN
```

Discord is optional. Leave `Webhook=` blank to disable notifications.

> **Keep the webhook URL private.** Anyone who obtains it may be able to send messages through that webhook. Do not publish or share a populated `Config.ini`.

<a name="configuration-and-execution"></a>
<details>
<summary><h2>Configuration and execution</h2></summary>

<a name="manual-configuration"></a>
### Manual configuration

#### Backup section

The `[Backup]` section requires:

```ini
[Backup]
Source=\\SERVER\Share\Backup
Destination=E:\Backup Destination
```

Rules:

- `Source` may be a UNC path or an absolute drive path.
- `Destination` must begin with a drive letter and backslash.
- Source and destination cannot be the same path.
- Values containing spaces do not need quotation marks.
- Blank lines are allowed.
- Comment lines may begin with `;` or `#`.
- Duplicate keys in the same section are rejected.
- Settings before a section header are rejected.
- Inline comments are not removed automatically.

#### Discord section

> **To create or retrieve a webhook:** Open the destination channel in Discord, select **Edit Channel** → **Integrations** → **Webhooks**, then choose an existing webhook or select **New Webhook**. Use **Copy Webhook URL** and paste the complete URL after `Webhook=`.

Enable notifications with:

```ini
[Discord]
Webhook=https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN
```

Disable notifications with:

```ini
[Discord]
Webhook=
```

The entire `[Discord]` section may also be omitted.

#### Configuration recovery

When first-run recovery replaces a custom or malformed `Config.ini`, the previous file is preserved as:

```text
Config.ini.bak-YYYYMMDD_HHMMSS
```

<a name="run-modes"></a>
### Run modes

#### Manual backup

```bat
RUN.cmd
```

Manual mode:

- Runs first-time setup when needed
- Shows confirmation and review pauses
- Allows a stale backup to continue with a warning
- Keeps the final result on screen

#### Scheduled backup

```bat
RUN.cmd /scheduled
```

Scheduled mode:

- Never prompts for input
- Rejects stale source backups
- Exits automatically
- Returns a process exit code to Task Scheduler
- Stops with exit code `22` when configuration is missing, invalid, incomplete, or still uses placeholders

Complete the first-run setup manually before using scheduled mode.

#### Discord test

```bat
RUN.cmd /testdiscord
```

Discord-test mode:

- Loads the webhook from `Config.ini`
- Sends a blue test embed
- Does not access the backup source or destination
- Exits `0` when delivery succeeds
- Exits `19` when Discord is disabled
- Exits `1` when delivery fails

#### Direct PowerShell usage

> Run these commands from the folder containing `Unraid_Appdata_Backup_Copy.ps1`. They use whichever PowerShell version is currently open.
> For normal use, `RUN.cmd` is recommended because it selects PowerShell 7 when available and handles the execution-policy arguments automatically.

**Manual**

```powershell
& ".\Unraid_Appdata_Backup_Copy.ps1"
```

**Scheduled**

```powershell
& ".\Unraid_Appdata_Backup_Copy.ps1" -Scheduled
```

**Discord test**

```powershell
& ".\Unraid_Appdata_Backup_Copy.ps1" -TestDiscord
```

<a name="windows-task-scheduler"></a>
### Windows Task Scheduler

Complete one successful manual run first.

Recommended action:

> **Example installation path:** Replace both instances of `C:\Scripts\Unraid-Appdata-Backup-Copy-v1.0.0` below with the actual folder containing the utility.

**Program/script**

```text
"C:\Scripts\Unraid-Appdata-Backup-Copy-v1.0.0\RUN.cmd"
```
> **Task Scheduler may automatically add quotation marks when the path is selected using `Browse`. Leave them in place.**

**Arguments**

```text
/scheduled
```
> **The `/scheduled` argument runs the utility in scheduled mode. This prevents interactive prompts that could leave an unattended task waiting for input. See [Run modes](#run-modes) for details.**

**Start in**

```text
C:\Scripts\Unraid-Appdata-Backup-Copy-v1.0.0
```

Recommended task settings:

- Run under a Windows account with access to the Unraid share
- Run whether the user is logged on or not, when desired
- Wake the computer to run the task, when desired
- Run as soon as possible after a missed start, when desired
- When the task is already running, choose **Do not start a new instance**

The utility does not currently include an internal single-instance lock. Prevent overlapping runs through Task Scheduler.

</details>

<a name="how-the-backup-process-works"></a>
<details>
<summary><h2>How the backup process works</h2></summary>

<a name="backup-folder-naming"></a>
### Backup-folder naming

> **This utility is designed to work with backups created by the Unraid plugin `Appdata Backup`, or another process that uses the same `ab_YYYYMMDD_HHMMSS` folder-naming convention.**

The source folder must directly contain at least one backup directory whose name exactly matches:

```text
ab_YYYYMMDD_HHMMSS
```

Example:

```text
ab_20260727_050002
```

These would be ignored:

```text
ab_20260727_050002-failed
ab_latest
20260727_050002
ab_20260727
```

Matching folder names are sorted newest first.

<a name="how-a-normal-run-works"></a>
### How a normal run works

1. Validate the source and destination.
2. Locate the newest correctly named backup folder.
3. Parse and validate its timestamp.
4. Check whether it is stale.
5. Wait for the source folder to remain unchanged.
6. Estimate which files still need copying.
7. Confirm sufficient destination free space.
8. Copy with Robocopy.
9. Parse and classify the Robocopy result.
10. Verify source files against the destination.
11. Apply local retention.
12. Write the final log and send a Discord result when enabled.

<a name="backup-age"></a>
### Backup age

Default maximum age:

```text
48 hours
```

The timestamp is taken from the backup-folder name.

- **Manual mode:** a stale backup produces a warning and may continue.
- **Scheduled mode:** a stale backup stops with exit code `20`.

Setting the maximum age to `0` does not disable freshness checking. It creates an extremely strict limit and will normally mark every existing backup as stale.

<a name="source-stability-check"></a>
### Source stability check

The newest backup is not copied immediately. The utility repeatedly checks:

- Recursive file count
- Total file size
- Newest file modification time

The source must remain unchanged for `3` consecutive one-minute comparisons. Any detected change resets the stability count.

Default maximum wait:

```text
6 hours
```

Passing the stability check provides reasonable evidence that Unraid has finished writing the backup, but it does not verify archive, database, or application integrity.

<a name="free-space-check"></a>
### Free-space check

Before copying, the utility estimates which files still need to be transferred.

A destination file is considered already matching when:

- The same relative path exists
- The byte size matches
- The modification time differs by no more than two seconds

Required free space is calculated as:

```text
estimated remaining copy data + configured reserve
```

Default reserve:

```text
50 GB
```

When no data appears to require copying, the reserve is not required for that run.

Robocopy remains the final authority on which files are copied.

<a name="robocopy-behavior"></a>
### Robocopy behavior

The transfer uses:

```text
/E
/COPY:DAT
/DCOPY:DAT
/J
/FFT
/R:2
/W:5
/ETA
/TEE
```

In practical terms:

- All subfolders are copied, including empty folders.
- File and folder data, attributes, and timestamps are preserved.
- Unbuffered I/O is used.
- File timestamps are compared using two-second precision, improving
  compatibility between the Unraid SMB source and the Windows destination.
- Failed copies are retried twice.
- Each retry waits five seconds.
- Progress and ETA information are displayed.
- Robocopy output is also written to the current-run log.

The utility deliberately does **not** use:

```text
/MIR
/PURGE
```

Robocopy return codes are interpreted as:

| Code | Result |
|---:|---|
| `0-3` | Successful |
| `4-7` | Completed with warning |
| `8+` | Fatal failure |

Codes `4-7` are accepted only when post-copy verification passes and retention succeeds.

<a name="post-copy-verification"></a>
### Post-copy verification

For every source file, the utility checks:

1. The same relative path exists at the destination.
2. The destination file has exactly the same byte size.

Verification succeeds only when:

- No source file is missing
- No source file has the wrong size
- All source bytes are represented by matching destination files

Extra destination files are logged but do not independently fail verification.

The log may list up to the first 20 missing, wrong-size, or extra paths.

> Verification does not use cryptographic hashes. Equal-size files with different contents would not be detected.

<a name="local-retention"></a>
### Local retention

Default retention:

```text
10 local backups
```

Retention considers only direct child folders beneath `Destination` whose names exactly match:

```text
ab_YYYYMMDD_HHMMSS
```

The newest matching folders are kept and older matching local folders are removed.

Retention:

- Never targets the Unraid source
- Ignores nonmatching local folders
- Runs only after verification passes
- Logs each folder before deletion

</details>

<a name="notifications-logs-and-results"></a>
<details>
<summary><h2>Notifications, logs, and results</h2></summary>

<a name="discord-notifications"></a>
### Discord notifications

Notification colors:

| Color | Meaning |
|---|---|
| 🔵 Blue | Webhook test |
| 🟢 Green | Clean completion |
| 🟡 Yellow | Manual stale-backup warning or completed-with-warning result |
| 🔴 Red | Fatal failure |

Completion notifications may include:

- Backup name
- Verification status
- Files and data copied
- Failure count
- Total time
- Average speed
- Remaining destination space
- Robocopy result and code
- Freshness details
- Utility version

A Discord delivery problem does not turn an otherwise successful backup into a failed backup.

The configured webhook is redacted from Discord-delivery diagnostic text.

<a name="logs"></a>
### Logs

If the destination is:

```text
E:\APPDATA Backup
```

the log folder is:

```text
E:\APPDATA Backup LOGS
```

Example log:

```text
Unraid-Appdata-Copy-20260728_205751_631.log
```

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

Temporary Robocopy logs are normally removed after successful parsing. They may be retained when Robocopy fails, parsing fails, or diagnostics are needed.

Permanent logs are not automatically pruned.

<a name="result-types"></a>
### Result types

#### 🟢 Clean success

A clean success means configuration, source checks, stability, space checks, Robocopy, verification, and retention all completed successfully.

Result:

- Green Discord embed when enabled
- Checkmark completion screen
- Exit code `0`

#### 🟡 Completed with warning

Common causes:

- A stale backup was accepted in manual mode
- Robocopy returned code `4-7`

Verification and retention must still succeed.

Result:

- Yellow Discord embed when enabled
- Warning completion screen
- Exit code `0`

#### 🔴 Failure

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

<a name="exit-codes"></a>
### Exit codes

| Code | Meaning |
|---:|---|
| `0` | Success or completed with warning |
| `1` | Unexpected failure, missing Robocopy, or Discord-test delivery failure |
| `10` | Destination drive unavailable |
| `11` | Source unavailable |
| `12` | No valid `ab_YYYYMMDD_HHMMSS` source folder found |
| `13` | Log directory or log file could not be created |
| `14` | Local destination folder could not be created |
| `15` | Retention cleanup failed |
| `16` | Stability wait timed out |
| `17` | Robocopy temporary log missing or could not be appended |
| `18` | Robocopy summary parsing failed |
| `19` | Discord test could not run because Discord was disabled |
| `20` | Scheduled run rejected a stale backup |
| `21` | Backup timestamp could not be validated |
| `22` | Configuration or internal policy is invalid |
| `23` | Free-space calculation failed |
| `24` | Insufficient destination free space |
| `25` | Verification process could not complete |
| `26` | Destination failed path-and-size verification |
| `27` | Invalid or conflicting command-line arguments |
| `8+` | Fatal Robocopy codes may be returned directly |

When diagnosing a failure, use the logged stage, reason, details, and log path rather than relying on the number alone.

</details>

<a name="troubleshooting"></a>
<details>
<summary><h2>Troubleshooting</h2></summary>

### First-run setup appeared unexpectedly

Setup appears when `Config.ini` is missing, malformed, incomplete, still uses a packaged placeholder, or contains a malformed nonblank webhook.

Confirm that `Config.ini` is beside the PowerShell script and is not accidentally named `Config.ini.txt`.

### Scheduled mode says setup is incomplete

Scheduled mode never prompts. Run `RUN.cmd`, complete setup manually, and then retry the scheduled task.

### Discord delivery fails

Check that the webhook still exists, Windows can reach Discord over HTTPS, security software is not blocking PowerShell, and the system date and time are correct.

Then run:

```bat
RUN.cmd /testdiscord
```

### Source unavailable

- Open the exact UNC path in File Explorer.
- Confirm Unraid and SMB are online.
- Confirm the current or scheduled Windows account has share access.
- Prefer UNC paths over mapped drive letters for network sources.

### Destination drive unavailable

- Confirm the external drive is connected.
- Confirm the configured drive letter is correct.
- Confirm the drive mounted before the run began.

### No valid source backup found

Confirm that `Source` directly contains a folder named like:

```text
ab_20260727_050002
```

### Stability never reaches 3/3

Possible causes include an active Unraid backup, a file that continues changing, an empty source folder, or intermittent SMB enumeration failures.

Review the stability entries in the permanent log.

### Verification failed

Review the log for missing files, wrong-size files, source and destination counts, source and destination sizes, and the first affected paths.

Do not manually delete older backups until the cause is understood.

### Manual runs work but scheduled runs fail

Check the task account, stored password, network-share permissions, destination-drive availability, working directory, `/scheduled` spelling, Task Scheduler history, and the utility log.

</details>

<a name="reference-and-limitations"></a>
<details>
<summary><h2>Reference and limitations</h2></summary>

<a name="default-settings"></a>
### Default settings

| Setting | Default |
|---|---:|
| Local backups retained | `10` |
| Maximum source age | `48 hours` |
| Free-space reserve | `50 GB` |
| Stability requirement | `3` unchanged one-minute comparisons |
| Maximum stability wait | `6 hours` |

These policies are defined near the beginning of the PowerShell script.

<a name="known-limitations"></a>
### Known limitations

- Verification uses relative path and file size, not file hashes.
- Source completion is inferred from stability.
- Backup folders must use the exact `ab_YYYYMMDD_HHMMSS` naming pattern.
- Robocopy summary parsing expects English output.
- There is no internal single-instance lock.
- Destination identity is based on drive letter, not volume serial number.
- Extra destination files are allowed by design.
- Empty directories are copied but not independently verified.
- Discord webhooks are stored as plain text in `Config.ini`.
- Permanent logs are not automatically pruned.
- There is no rollback if retention partially succeeds before an error.
- Archive contents and application databases are not internally validated.

<a name="what-this-utility-does-not-replace"></a>
### What this utility does not replace

This project does not replace:

- The original Unraid appdata backup
- Unraid parity
- Snapshots
- An offsite backup
- Archive-integrity testing
- Application-level database checks

It is an additional copy, verification, retention, logging, and notification layer.

</details>

## License

Released under the [MIT License](LICENSE).

Copyright (c) 2026 toml12791
