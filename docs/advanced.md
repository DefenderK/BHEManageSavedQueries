# Advanced usage and troubleshooting

For interactive setup, backup/transfer instructions, and the complete [API endpoints and request flow](../README.md#api-endpoints-and-request-flow), start with the main README.

## Command-line modes

Explicit operation options skip the startup menu. These examples all read credentials from an env file; they do not depend on a previously defined `$options` variable.

```powershell
# Preview the authenticated user's owned queries.
.\Manage-BHESavedQueries.ps1 -EnvFile .\.env.user1 -Scope Owned

# Save a standalone backup; omit BackupPath to generate a timestamped filename.
.\Manage-BHESavedQueries.ps1 -EnvFile .\.env.user1 -Scope Owned -BackupOnly -BackupPath .\user1-queries.json

# Preview deletion, then delete with a NEW backup path.
.\Manage-BHESavedQueries.ps1 -EnvFile .\.env.user1 -Scope Owned -Delete -WhatIf
.\Manage-BHESavedQueries.ps1 -EnvFile .\.env.user1 -Scope Owned -Delete -BackupPath .\user1-pre-delete.json

# Preview import as the destination user, then import.
.\Manage-BHESavedQueries.ps1 -EnvFile .\.env.user2 -ImportPath .\user1-queries.json -WhatIf
.\Manage-BHESavedQueries.ps1 -EnvFile .\.env.user2 -ImportPath .\user1-queries.json

# Verify the destination.
.\Manage-BHESavedQueries.ps1 -EnvFile .\.env.user2 -Scope Owned

# Preview public queries owned by a specific application user.
.\Manage-BHESavedQueries.ps1 -EnvFile .\.env -OwnerUserId '11111111-1111-1111-1111-111111111111'
```

`-Scope Public` without `-OwnerUserId` goes straight to interactive user selection. With an owner UUID, the default public mode filters locally to that owner's public queries. `-BackupOnly` saves all matches, and `-Delete` deletes all matches after backing them up. Command-line `-Delete` requires `-BackupPath`, except under `-WhatIf`.

`-Scope Owned` includes the authenticated user's public and private queries. An explicitly supplied owner UUID must match the authenticated account. It does not include other users' queries that are merely shared with you. The API also defines `shared` and `all`, but this tool exposes only `Public` and `Owned`.

`-ImportPath` accepts schema-version-1 JSON envelopes produced by this tool, including older public-query backups. Do not combine it with `-Scope`, `-OwnerUserId`, `-BackupOnly`, `-Delete`, or `-BackupPath`. `-ResultsPath` applies only to import and must name a new file. Import validates all source records and checks the destination for name collisions case-insensitively before sending any POST.

PowerShell asks before command-line mutations and backup writes. After reviewing a preview, `-Confirm:$false` can suppress those built-in prompts. Interactive deletion/import still requires typing `DELETE`/`IMPORT`. `-Confirm` can add per-query prompts to interactive actions. R applies only to the tool's custom prompts, not PowerShell's built-in dialogs.

## Configuration and authentication

Settings resolve per field in this order:

1. Explicit command-line parameter.
2. The explicit `-EnvFile`, or `.env` in the current directory when no file is specified.
3. Process environment variable.

No other folders or filenames are searched. An empty file value also overrides the environment; `BHE_BEARER_TOKEN=` clears an inherited bearer value when using API token authentication. Loading a file does not modify the process environment.

Supported file keys are `BHE_URL`, `BHE_TOKEN_ID`, `BHE_TOKEN_KEY`, and `BHE_BEARER_TOKEN`. The parser accepts `NAME=value`, blank lines, full-line `#` comments, and matching single/double quotes. It splits at the first `=`. Values are literal: variables, commands, and escape sequences are not evaluated. Inline comments, `export` syntax, duplicate keys, and unknown settings are not supported. Invalid entries stop the run before HTTP requests, without printing setting values.

To use process environment values instead of a file, run from a folder without `.env`, or supply explicit parameters to override file values:

```powershell
$env:BHE_URL = 'https://your-tenant.bloodhoundenterprise.io'
$env:BHE_TOKEN_ID = Read-Host 'User API token ID'
$secret = Read-Host 'User API token key' -AsSecureString
$env:BHE_TOKEN_KEY = (New-Object System.Net.NetworkCredential('', $secret)).Password
$env:BHE_BEARER_TOKEN = ''
.\Manage-BHESavedQueries.ps1
```

API tokens use chained HMAC-SHA256 `bhesignature` authentication. POST signatures cover the exact UTF-8 JSON bytes sent. An existing bearer JWT is also supported: clear token ID/key values and supply `BHE_BEARER_TOKEN` or `-BearerToken`. Token keys are not bearer tokens. The tool does not call a login/token-generation endpoint, and it does not write credentials to backups or results.

HTTPS certificates remain validated and redirects are disabled. HTTP is allowed only on loopback addresses such as `localhost`, `127.0.0.1`, and `[::1]`. URLs must be absolute origins with no path beyond `/`, query string, fragment, or embedded credentials. A trailing slash is accepted.

## Limits and result logs

| Setting | Default / behavior |
| --- | --- |
| `-PageSize` | 100 records per page; allowed range 1-1,000. |
| `-MaxQueries` | 10,000; allowed range 1-100,000. Public mode counts every public record scanned, not only the selected owner's matches. Owned mode counts owned records; import also limits source record count and destination records scanned. |
| `-TimeoutSeconds` | 30 seconds per request; allowed range 1-300. |
| Import file size | At most 32 MiB. |

Pagination completes before deletion. Incomplete pages, duplicate IDs, changed counts, exceeded bounds, malformed records, or a mismatched owned-query owner stop the operation. Before deleting, the tool rechecks ID, owner, name, Cypher text, description, modification time, and permissions. Requests are separate, so concurrent changes can still cause failures; the operation is not atomic.

| Result | Meaning |
| --- | --- |
| `Preview` | No mutation attempted. |
| `BackedUp` | Query saved to a standalone backup. |
| `Deleted` | DELETE returned HTTP 204. |
| `Imported` | Import returned HTTP 201 and the expected acknowledgement. |
| `Declined` | PowerShell confirmation was declined. |
| `Skipped` | A deletion recheck failed before a DELETE was attempted. |
| `DeleteUnconfirmed` | DELETE was attempted without confirmed success; inspect the destination before retrying. |
| `ImportUnconfirmed` | Import request failed or returned an unexpected response; inspect the destination before retrying. Remaining imports were not attempted. |

Deletion continues through the selected batch after individual failures, records each result, and raises a terminating error if any deletion was skipped or unconfirmed. Import stops after its first unconfirmed result. Neither POST nor DELETE is automatically retried.

For a custom backup filename, the deletion log is `queries-deletion-results-<backup stem>.jsonl`, with a leading `queries-backup-` removed. For example, `admin.json` creates `queries-deletion-results-admin.jsonl`. Import can use `-ResultsPath` to choose a log location. Output folders must already exist, and existing files are never overwritten.

## Troubleshooting

**Option 1 returns HTTP 403:** the authenticated account cannot list BloodHound users. The tool displays the endpoint and request ID and returns to the main menu. Use an account with user-list permission, typically Administrator, or options 2-5 for the authenticated user's own queries. Selecting an owner UUID does not impersonate that user.

**Owned backup receives `no query permissions exist for saved query`:** unshared queries may have no sharing-permission row. Only for HTTP 404 with that exact message, owned mode re-reads the query and verifies its owner against the authenticated UUID. It records empty sharing metadata with `permissions_source: "not_returned_404"`, preserving the missing-record evidence. Query content remains usable for import. Public mode still requires a successful public-sharing response. Other 404 messages, 403 responses, and ownership mismatches remain errors.

**Saved-query owner filter causes a server error:** some server versions rewrite `user_id` incorrectly in the SQL filter. The tool avoids that filter, requests public queries, and matches the owner UUID exactly locally. Increasing `-MaxQueries` may be necessary for tenants with many public queries.

**URL rejected despite a valid `.env`:** check for an explicit `-BaseUrl` value, which takes precedence over the file. Use the tenant origin, not a browser page URL or API path.

**Import name conflict:** existing names are never overwritten, even if the query text is identical. Inspect the destination and resolve the collision explicitly. A partial previous import may be the cause; do not blindly rerun an uncertain batch.

## Offline verification

```powershell
powershell.exe -NoProfile -File .\tests\Test-ManageBHESavedQueries.ps1
powershell.exe -NoProfile -File .\tests\Test-TransferQueries.ps1
```

Tests mock HTTP completely and use dummy credentials. They make no tenant requests and leave backups/results in `tests/artifacts` for inspection. Validation during development was offline; these checks do not establish live compatibility with every BloodHound version.

## API references

The endpoint table and detailed flows remain in the [main README](../README.md#api-endpoints-and-request-flow).

- [Signed API authentication](https://bloodhound.specterops.io/reference/overview)
- [Authenticated user details](https://bloodhound.specterops.io/reference/auth/get-self)
- [List application users](https://bloodhound.specterops.io/reference/bloodhound-users/list-users)
- [List saved queries](https://bloodhound.specterops.io/reference/cypher/list-saved-queries)
- [Read a saved query](https://bloodhound.specterops.io/reference/cypher/return-a-saved-query)
- [Delete a saved query](https://bloodhound.specterops.io/reference/cypher/delete-a-saved-query)
- [Saved query permissions](https://bloodhound.specterops.io/reference/cypher/retrieves-saved-query-permissions-for-provided-query-id)
- [Saved-query implementation](https://github.com/SpecterOps/BloodHound/blob/main/cmd/api/src/api/v2/saved_queries.go)
