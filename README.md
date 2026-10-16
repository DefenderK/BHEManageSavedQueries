# BHE-ManageSavedQueries

> **Example tool:** This is a vibe-coded example showing how to manage saved queries in BloodHound through the API. It is not supported by SpecterOps and should be reviewed before use in a production environment.

List, back up, delete, and re-import BloodHound Enterprise saved queries using an interactive PowerShell menu.

Requires Windows PowerShell 5.1 or PowerShell 7 and a BloodHound user API token with permission for the selected operation.

## Quick start: interactive mode

> **Credential security:** The `.env` file stores your API credentials in plaintext. Anyone who can read it can use those credentials with the permissions of that account. Restrict file access, keep it out of shared or synced folders, and never commit or share it. Git ignores the file, but that does not protect its contents. Remove it when no longer needed, and revoke or rotate the API token if it is exposed.

1. Copy [`.env.example`](.env.example) to `.env` in your working folder.
2. Enter the URL and API credentials for the user you want to connect as:

```dotenv
BHE_URL=https://your-tenant.bloodhoundenterprise.io
BHE_TOKEN_ID=your-token-id
BHE_TOKEN_KEY=your-token-key
BHE_BEARER_TOKEN=
```

3. Run the script from that folder:

```powershell
.\Manage-BHESavedQueries.ps1
```

The script automatically loads `.env` and shows:

```text
     ____  _   _ _____
    | __ )| | | | ____|
    |  _ \| |_| |  _|
    | |_) |  _  | |___
    |____/|_| |_|_____|

    +----------------------------------+
    |      BHE-ManageSavedQueries       |
    +----------------------------------+

BloodHound saved queries
1. Manage public queries (select a user, then preview/delete)
2. List my owned queries
3. Back up my owned queries (including private queries)
4. Delete my owned queries (backup first, including private queries)
5. Import a backup as the authenticated user
Choose 1-5, or Q/Enter to quit:
```

| Option | What it does |
| --- | --- |
| 1 | Select another user and preview their public queries, then delete one or all matches. Requires user-list permission, typically Administrator. |
| 2 | List your owned queries, including private queries, with full text and a total. Creates no files. |
| 3 | Save all your owned queries to a backup without deleting them. |
| 4 | Back up and delete all your currently listed owned queries. Requires `DELETE` confirmation. |
| 5 | Import saved queries from a backup created by this script, as the authenticated user. Requires `IMPORT` confirmation. |

Check the displayed account before proceeding. Selecting a user in option 1 filters public queries; it does not log in as that user.

At custom prompts, **R** returns to the main menu and **Q** quits/cancels. At the backup path prompt, **Enter** accepts a timestamped filename in the current folder. PowerShell's built-in confirmation dialogs use their standard choices. A completed operation ends the run.

To use another user's settings, rerun with a different env file:

```powershell
.\Manage-BHESavedQueries.ps1 -EnvFile .\.env.user2
```

To explore the menu without writing files or changing queries:

```powershell
.\Manage-BHESavedQueries.ps1 -WhatIf
```

### Command-line parameters

With no operation options, the script shows the interactive menu. Connection options such as `-EnvFile` still allow interactive use; specifying `-Scope`, `-OwnerUserId`, `-BackupOnly`, `-Delete`, or `-ImportPath` selects an explicit operation.

| Parameter | Description |
| --- | --- |
| `-BaseUrl` | BloodHound tenant origin, such as `https://your-tenant.bloodhoundenterprise.io`. Overrides `BHE_URL` from the env file or process environment. |
| `-EnvFile` | Path to a credentials/configuration file. If omitted, the script loads `.env` from the current folder when present. |
| `-TokenId` | API token ID. Overrides `BHE_TOKEN_ID` from the file/environment. Use with `-TokenKey`. |
| `-TokenKey` | API token secret key. Overrides `BHE_TOKEN_KEY` from the file/environment. Use with `-TokenId`. |
| `-BearerToken` | Existing bearer JWT, as an alternative to token ID/key authentication. Overrides `BHE_BEARER_TOKEN`; token ID/key settings must be empty. |
| `-Scope` | `Public` or `Owned`. Default: `Public`. `Owned` includes the authenticated user's private queries; `Public` selects public queries. |
| `-OwnerUserId` | BloodHound application user UUID to filter public queries by owner. In owned mode, it must match the authenticated user's UUID. |
| `-BackupOnly` | Save all matching queries to a backup without deleting them. |
| `-BackupPath` | New backup JSON file path in an existing folder. Backup-only mode generates a timestamped filename if omitted. |
| `-Delete` | Delete matching queries after backing them up. Command-line deletion requires `-BackupPath`, except with `-WhatIf`. |
| `-ImportPath` | Path to a JSON backup created by this script. Imports copies as the authenticated user. |
| `-ResultsPath` | New import-results JSONL file path. Only used with `-ImportPath`; defaults to a timestamped filename in the current folder. |
| `-PageSize` | Records requested per API page. Default: `100`; range: `1-1000`. |
| `-MaxQueries` | Maximum records to scan/import. Default: `10000`; range: `1-100000`. Public mode counts all public records scanned, including other owners' queries. |
| `-TimeoutSeconds` | Timeout per API request. Default: `30` seconds; range: `1-300`. |
| `-WhatIf` | Preview without creating backups/logs or changing queries. API GET requests still run. |
| `-Confirm` | Add PowerShell confirmation prompts. `-Confirm:$false` suppresses those built-in prompts; interactive `DELETE`/`IMPORT` confirmations still apply. |

Use either token ID/key or a bearer JWT. `-BackupOnly` and `-Delete` cannot be combined. `-ImportPath` cannot be combined with `-Scope`, `-OwnerUserId`, `-BackupOnly`, `-Delete`, or `-BackupPath`. See the [advanced command-line examples](docs/advanced.md#command-line-modes) for complete commands.

Use only the tenant origin in `BHE_URL`, without `/ui`, `/api/v2`, or other paths. HTTPS is required except on loopback; for a local instance, `BHE_URL='http://127.0.0.1:8080/'` is supported. Keep the plaintext `.env` file private; it is ignored by Git.

## Back up and transfer between users

Create `.env.user1` and `.env.user2` using the example above, with each user's own API token.

1. Run with `-EnvFile .\.env.user1` and choose **3** to back up user 1's owned queries. Note the saved filename.
2. Run with `-EnvFile .\.env.user2` and choose **5**. Enter that backup path, check the destination account, and type `IMPORT`.
3. Run again as user 2 and choose **2** to verify the copied queries.
4. If you also want to remove the originals, run again as user 1 and choose **4**. This creates a fresh backup before deleting.

Imports preserve names, descriptions, and Cypher text. They create **new private queries owned by the destination user**, with new IDs; original sharing and timestamps are not restored. Existing query names are not overwritten: a conflict stops import before creation begins.

Deletion targets the current query list, not an earlier backup's IDs. If the source changed after your first backup, keep the fresh pre-delete backup for those newer contents.

## Backups and results

| File | Contents |
| --- | --- |
| `queries-backup-<UUID>-<timestamp>.json` | Query records, source owner, tenant, export time, and sharing metadata. |
| `queries-deletion-results-<UUID>-<timestamp>.jsonl` | The outcome of each selected deletion. |
| `queries-import-results-<UUID>-<timestamp>.jsonl` | The outcome of each attempted import. |

Timestamps are UTC. Backups and logs use separate files; backup-only runs create just the backup. Custom paths must use an existing folder and a new filename. Existing files are never overwritten, and deletion cannot begin unless the backup and results log were created successfully.

**Restore backups through option 5 or `-ImportPath`.** The file is valid JSON containing a tool backup envelope; it is not a file to upload directly to BloodHound's import endpoint. The tool converts each saved query into the API's expected JSON format.

Deletion and import requests are not automatically retried. If a result is unconfirmed, inspect the log and list the account's queries before trying again. See the [advanced guide](docs/advanced.md) for result statuses, command-line modes, limits, and troubleshooting.

## API endpoints and request flow

All paths below are appended to the configured `BHE_URL` / `BaseUrl`. Every request uses the same authenticated account. Selecting a user records their UUID for filtering; it does not impersonate that user.

| Method | Endpoint | How the tool uses it |
| --- | --- | --- |
| GET | `/api/v2/bloodhound-users` | Public interactive mode: reads `data.users` and displays a numbered list of application users. Skipped when `-OwnerUserId` is supplied, in owned mode, and for import. |
| GET | `/api/v2/saved-queries?scope=public&sort_by=id&skip=<offset>&limit=<page-size>` | Fetches public saved queries in pages. Reads the `data` array and `count`, then locally matches each query's `user_id` to the selected UUID. |
| GET | `/api/v2/self` | Owned mode and import: identifies the authenticated application user and displays their principal and UUID. |
| GET | `/api/v2/saved-queries?scope=owned&sort_by=id&skip=<offset>&limit=<page-size>` | Fetches the authenticated user's owned queries, including private queries. Also used before import to detect destination name collisions. |
| GET | `/api/v2/saved-queries/<query-ID>/permissions` | Fetches `data.public` and sharing metadata for the backup and before deletion. Public mode requires public sharing; owned mode records permissions without requiring public sharing. |
| GET | `/api/v2/saved-queries/<query-ID>` | Immediately before deletion, reads `data` to recheck the ID, owner, name, query text, description, and modification time against the backed-up record. |
| DELETE | `/api/v2/saved-queries/<query-ID>` | Deletes one selected query after all checks pass. HTTP `204 No Content` is required to record a confirmed deletion. |
| POST | `/api/v2/saved-queries/import` | Import mode: creates one saved query per request from JSON containing name, query text, and description, under the authenticated user. Requires HTTP 201 and the expected import acknowledgement. |

### Public-query interactive flow

1. **Load configuration and authentication.** Read parameters, the optional env file, and environment variables. This is local work; the script does not call a login or token-generation endpoint.
2. **List users.** Call `GET /api/v2/bloodhound-users`. The operator selects a displayed user; the script retains that account's UUID.
3. **Fetch public queries.** Call the paginated saved-query list endpoint, starting with `skip=0` and advancing by the number of records returned. The default `limit` is 100. Collect only exact owner UUID matches. Fetching completes before any deletion begins. The script deliberately omits the server-side `user_id` filter to avoid a server filter compatibility issue; see [Troubleshooting](docs/advanced.md#troubleshooting).
4. **Preview and select.** Display the matching queries locally. The operator chooses one query, all matching queries, or quit. There are no API calls for these menu choices. “All” means the matching public queries from this preview, not all users' queries or queries created later.
5. **Choose the backup path and confirm.** Enter accepts the timestamped default path; Q cancels. Typing `DELETE` confirms the selection. `-WhatIf` ends with simulated actions instead of backup or deletion.
6. **Gather backup metadata.** For every selected query, call `GET /api/v2/saved-queries/<query-ID>/permissions`. Require public sharing and collect sharing metadata. If any request/check fails, stop before deleting anything.
7. **Save local files.** Write the selected records and their permissions to the JSON backup, then create the separate deletion results log. The query text comes from the list response; the script does not use the query export endpoint. Failure to create either file prevents deletion.
8. **Recheck and delete each query.** After any PowerShell confirmation prompt is accepted, call `GET /api/v2/saved-queries/<query-ID>`, then `GET /api/v2/saved-queries/<query-ID>/permissions`. Require unchanged content, the selected owner UUID, and public sharing. Only then call `DELETE /api/v2/saved-queries/<query-ID>`. A failed recheck skips that query. A deletion without a confirmed 204 response is recorded as `DeleteUnconfirmed`; destructive requests are not automatically retried.
9. **Record results.** Flush one local JSONL result per selected query and display its outcome. Verification is a separate preview run, which calls the list endpoint again; the script does not automatically perform a final verification request.

The GET checks and DELETE are separate requests, so the sequence is not an atomic transaction. Private queries are outside the public workflow's scope, even where an individual GET endpoint might permit an administrator to read a known private query ID. In owned mode the same backup and content/ownership rechecks apply, but public sharing is not required for queries owned by the authenticated user.

### Owned-query flow (menu options 2-4)

1. Call `GET /api/v2/self` to identify the authenticated account. Selecting a different user is not supported in owned mode.
2. Page through `GET /api/v2/saved-queries?scope=owned&sort_by=id&skip=<offset>&limit=<page-size>`. Verify every record belongs to that account and display the complete preview and total. **Option 2 ends here**, without writing files.
3. For backup or deletion, choose a backup path. Deletion additionally requires typing `DELETE`. A `-WhatIf` run ends with a preview and writes nothing.
4. Fetch each query's permissions and save the records and sharing metadata to the local JSON backup. For the specific missing-permissions 404, verify the query's ownership again and record that sharing metadata was not returned. Other errors stop the backup; details are in [Troubleshooting](docs/advanced.md#troubleshooting). **Option 3 ends after saving the backup.**
5. For option 4, create the deletion results log. Re-read each query and its permissions, check ownership and unchanged content, then issue `DELETE /api/v2/saved-queries/<query-ID>`. Owned queries do not need to be public.
6. Flush each result to the log and report the outcome. List the user's queries again with option 2 to verify separately.

### Import flow (menu option 5)

1. Select an existing tool backup and call `GET /api/v2/self` to display the destination account.
2. Validate the backup locally, including its format, source ownership, duplicate names/IDs, query content, and size/count limits.
3. Page through the destination's owned queries and reject any conflicting names before creating anything.
4. Confirm with `IMPORT`. Extract only `name`, `query`, and `description` from each saved record and send one JSON request per query to `POST /api/v2/saved-queries/import`.
5. Require HTTP 201 and the expected acknowledgement to record `Imported`. Flush each result to a separate local JSONL log. An unconfirmed import stops the batch; remaining queries are not attempted, and POSTs are not automatically retried.
6. Use option 2 under the destination account to verify the imported copies. Import does not call permissions, sharing-update, or DELETE endpoints.


## Further reference

- [Advanced usage and troubleshooting](docs/advanced.md)
- [BloodHound API authentication](https://bloodhound.specterops.io/reference/overview)
- [Saved-query API reference](https://bloodhound.specterops.io/reference/cypher/list-saved-queries)
