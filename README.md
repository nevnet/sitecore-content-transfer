# Sitecore content transfer

PowerShell 7 utility for transferring selected content and media between SitecoreAI authoring environments using the Content Transfer API and Item Transfer API. Run it locally or through the included manually triggered Azure DevOps pipeline.

The example configuration uses **SiteCollection** and **Site** as placeholders for your site collection and site names. Replace the item paths, environment URLs and credential placeholders with your own values. The module accepts a source and destination; the pipeline example is configured for production-to-development refreshes.

## Contents

- [Prerequisites](#prerequisites)
- [Run locally](#run-locally)
- [Configuration](#configuration)
- [Parameters and connection settings](#parameters-and-connection-settings)
- [Azure DevOps](#azure-devops)
- [How the transfer works](#how-the-transfer-works)
- [Completion and recovery](#completion-and-recovery)
- [Troubleshooting](#troubleshooting)
- [API references](#api-references)

## Repository contents

| File | Purpose |
| --- | --- |
| [README.md](README.md) | Setup instructions, configuration and parameter reference, and troubleshooting guidance. |
| [Invoke-ContentTransfer.ps1](Invoke-ContentTransfer.ps1) | Entry point for local and pipeline executions; loads the module and passes in the selected configuration and parameters. |
| [SitecoreTransfer.psm1](SitecoreTransfer.psm1) | Reusable module that handles authentication, API orchestration, polling, import retries, journaling and cleanup. |
| [prod-to-dev.yml](prod-to-dev.yml) | Manually triggered Azure DevOps pipeline that supplies configuration and credentials, runs the entry script, and retains the execution journal. |
| [config/*.json](config/) | Transfer definitions selecting the database, item roots, scopes and merge strategies, with examples for content and media. |

## Prerequisites

- PowerShell **7**, not Windows PowerShell 5.1.
- Two distinct SitecoreAI authoring environments with access to the transfer APIs.
- Separate environment automation client credentials for the source and destination, created in **SitecoreAI Deploy → Credentials → Environment → Automation**. Do not assume that existing deployment credentials provide transfer access. Sitecore's walkthrough documents the Organization Admin or Organization Owner prerequisite.
- Compatible destination templates, renderings and required parent items with matching IDs. The utility does not inspect the destination parent chain.

No Sitecore CLI, Sitecore PowerShell Extensions, Azure login or application build is required. Standard TLS certificate validation and system proxy behavior apply.

## Run locally

Run these commands from the root of this repository. The example CM URLs and credential strings below are placeholders; replace them before executing a transfer. Keep populated credentials out of source control.

```powershell
$env:SITECORE_TRANSFER_SOURCE_URL = 'https://xmc-mycustomertenant-sitecoreai-prod.sitecorecloud.io/'
$env:SITECORE_TRANSFER_DESTINATION_URL = 'https://xmc-mycustomertenant-sitecoreai-dev.sitecorecloud.io/'
$env:SITECORE_TRANSFER_SOURCE_CLIENT_ID = 'REPLACE_WITH_SOURCE_CLIENT_ID'
$env:SITECORE_TRANSFER_SOURCE_CLIENT_SECRET = 'REPLACE_WITH_SOURCE_CLIENT_SECRET'
$env:SITECORE_TRANSFER_DESTINATION_CLIENT_ID = 'REPLACE_WITH_DESTINATION_CLIENT_ID'
$env:SITECORE_TRANSFER_DESTINATION_CLIENT_SECRET = 'REPLACE_WITH_DESTINATION_CLIENT_SECRET'

.\Invoke-ContentTransfer.ps1 `
    -ConfigPath .\config\example-content.json `
    -MergeStrategyOverride OverrideExistingItem `
    -PollTimeoutSeconds 7200 `
    -StatePath .\journals\content-refresh-001.json `
    -Verbose
```

Use a new journal filename for each execution. Relative paths resolve against the caller's current working directory. If `-StatePath` is omitted, a unique journal is created under the system temporary directory.

The example explicitly overrides the supplied `KeepExistingItem` defaults. Omit `-MergeStrategyOverride` to respect each root's configured strategy. To transfer media, run the script again with `-ConfigPath .\config\example-media.json` and a different journal filename. Start with a narrow scope and validate the destination before expanding the transfer.

Wait for `Outcome=Succeeded` and exit code `0`. The script does not publish content; use your normal destination publishing workflow after validation.

## Configuration

```json
{
  "database": "master",
  "paths": [
    {
      "itemPath": "/sitecore/content/SiteCollection/Site/Home",
      "scope": "ItemAndDescendants",
      "mergeStrategy": "KeepExistingItem"
    }
  ]
}
```

The supplied content example also includes `/sitecore/content/SiteCollection/Site/Data`. The media example selects `/sitecore/media library/Project/SiteCollection/Site`. All example roots use `master`, `ItemAndDescendants` and `KeepExistingItem`.

- `SingleItem` includes only the selected item; `ItemAndDescendants` includes the subtree.
- Roots must be disjoint: duplicates and ancestor/descendant overlaps are rejected.
- Referenced content or media outside the selected roots is not automatically included. Add separate roots for shared assets, dictionaries or other required content.
- Copying `master` can include unpublished authoring changes. This is not a transfer limited to the public website's published content.
- Credentials, URLs and tokens do not belong in the JSON. The script generates transfer IDs and the underlying API request.

| Merge strategy | Destination behavior |
| --- | --- |
| `KeepExistingItem` | Preserves matching items and adds missing items. |
| `OverrideExistingItem` | Updates matching items and adds missing items, retaining destination-only items. |
| `OverrideExistingTree` | Deletes the selected destination root and its descendants before writing the transferred tree, removing destination-only work. |

Strategies can differ by root. A runtime override affects every configured root in memory without modifying the JSON file.

## Parameters and connection settings

| Parameter | Default or behavior |
| --- | --- |
| `ConfigPath` | Required JSON configuration path. |
| `SourceBaseUrl` / `DestinationBaseUrl` | Default to the corresponding URL environment variables. Must be distinct HTTPS origins without paths, queries or embedded credentials. |
| `MergeStrategyOverride` | Unset; optionally overrides all roots with one of the three supported strategies. |
| `PollIntervalSeconds` | `5`; delay between status polls. |
| `PollTimeoutSeconds` | `1800`; timeout per waiting operation, not for the entire execution. |
| `RetryCount` | `0`; optional bounded retries of confirmed failed destination imports. |
| `AutoCleanup` | `$true`; `-AutoCleanup:$false` preserves resources after failure. Successful cleanup remains mandatory. |
| `StatePath` | New journal path; existing files are rejected. |
| `Verbose` | Sanitized request, response and progress diagnostics. |

Source and destination each use their own `SITECORE_TRANSFER_*_CLIENT_ID` and `SITECORE_TRANSFER_*_CLIENT_SECRET`. Alternatively supply `SITECORE_TRANSFER_SOURCE_ACCESS_TOKEN` and/or `SITECORE_TRANSFER_DESTINATION_ACCESS_TOKEN`. A supplied token takes precedence; credentials, if also available, allow proactive refresh near expiry. Token-only sessions fail when their token expires. Tokens and credentials are excluded from journals and redacted from diagnostics.

HTTP operations have a separate five-minute timeout. Increasing `PollTimeoutSeconds` does not increase that request limit. The utility does not automatically replay failed uploads or restart operations after uncertain responses.

## Azure DevOps

Register [prod-to-dev.yml](prod-to-dev.yml) as a YAML pipeline. It has `trigger: none` and `pr: none`, and is intended to be started manually after coordinating the refresh with users of the lower environment.

Create a variable group named `sitecore-transfer`, or update the YAML to use your chosen group. Authorize the pipeline to use it and configure:

| Variable-group value | Script environment variable |
| --- | --- |
| `SOURCE_CM_URL` | `SITECORE_TRANSFER_SOURCE_URL` |
| `DESTINATION_CM_URL` | `SITECORE_TRANSFER_DESTINATION_URL` |
| `SOURCE_CLIENT_ID` | `SITECORE_TRANSFER_SOURCE_CLIENT_ID` |
| `SOURCE_CLIENT_SECRET` — mark secret | `SITECORE_TRANSFER_SOURCE_CLIENT_SECRET` |
| `DESTINATION_CLIENT_ID` | `SITECORE_TRANSFER_DESTINATION_CLIENT_ID` |
| `DESTINATION_CLIENT_SECRET` — mark secret | `SITECORE_TRANSFER_DESTINATION_CLIENT_SECRET` |

Use your production CM as the source and development CM as the destination. To refresh a different lower environment, adapt the variable values and pipeline labels. The pipeline has no runtime destination selector.

At run time, choose `example-content.json` or `example-media.json`, an optional merge override, and verbose logging. `UseConfiguration` respects the JSON defaults. The pipeline checks out the repository, invokes the root-level entry script, and retains `execution.json` in the `sitecore-transfer-journal` artifact. The artifact step uses `condition: always()` so it runs after ordinary failures if the agent remains available; agent loss can still prevent artifact publication.

The pipeline does not build or deploy application code, or publish content. Its job limit is six hours, but an agent's entitlement may impose a lower limit. The script retains its default 30-minute polling window unless the YAML invocation is adjusted. Configure both limits for the expected load.

## How the transfer works

`Invoke-ContentTransfer.ps1` validates arguments, loads the module, creates the runtime, invokes the transfer and disposes the HTTP client. It returns `0` on success and `1` on failure. `SitecoreTransfer.psm1` owns orchestration.

One long-lived `HttpClient` handles sequential requests. Each request specifies its own source or destination bearer token; no default authorization header or base address is shared across environments. Automatic redirects, decompression and cookies are disabled. Source chunk streams are forwarded unchanged, including the source-supplied `IsMedia` value and content length where available. Unknown-length streams remain streamed requests; there is no silent disk fallback or automatic upload replay.

1. Generate and journal a source transfer ID before creation.
2. Create the export and poll for readiness.
3. Stream every chunk in each chunk set to the destination and complete the set.
4. Wait for the resulting `.raif` blob to be uploaded and start consumption.
5. Resolve the import ID from the returned resource or the specific blob's `SourceName`, then monitor both import and blob state.
6. Require `Finished`, no validation errors and `Transferred` before cleaning up the completed blob and source export.

A blob name and an import job ID are distinct values. A not-yet-visible import status is polled without issuing another start request. Confirmed failed imports can be requeued only within the configured retry limit. A retry resolves the import ID again, allowing the server to reuse an ID.

The journal is updated through atomic file replacements as the operation progresses. It records possibly-started operations before their requests are sent, helping distinguish a known failure from an uncertain response.

## Completion and recovery

Success requires a finished import, no validation errors, a terminal transferred blob state, and successful cleanup. Content appearing in the tree is not sufficient evidence of completion. Validation errors, partial imports and cleanup failures result in a nonzero exit.

**A timeout does not cancel an import inside Sitecore.** Inspect the existing import before starting a new execution. The journal records resource identifiers, stages, completed chunks, import states, validation errors and cleanup outcomes. It supports investigation; it is not a resume mechanism. Protect journals as operational records even though they exclude credentials.

Only a confirmed failed destination import is eligible for configured import retries. Source export failures, upload failures, response loss and partial imports are not automatically replayed. Active or uncertain destination imports are preserved for inspection.

**Cleanup is not rollback.** Content already imported remains changed if a later operation fails. There is no dry run, content diff, subtree exclusion, automatic dependency resolution, parent validation, automatic resume or automatic publishing. See [troubleshooting](#troubleshooting) before retrying an ambiguous operation.

## Troubleshooting

For authentication errors, verify environment automation credentials and roles; neither redirects nor certificate bypass are enabled. For missing parent IDs, prepare the destination or select a suitable common ancestor manually. For partial imports inspect the journal's validation errors and the destination transfer details. For timeouts preserve unknown consumption and inspect current state; a fresh execution uses a new source transfer and is not a resume of the previous run.

For a destination chunk PUT failure, inspect the `Uploading chunk` line and the journal's `UploadAttempt.ContentLength`, `LengthMode` and `IsMedia` fields. They are checkpointed before sending the upload, even if its response fails. `UnknownLengthStream` means the source did not supply a length; that is diagnostic evidence, not proof that framing caused the error. `-Verbose` is forwarded by the bootstrap into the module and includes request content headers, response headers and a sanitized textual error body (up to 4096 characters). A JSON `Error`/`Message` or problem-details `title`/`detail`, or a plain-text error, is included in the terminating error and journal up to 1024 characters. Credential responses, cookies and binary error bodies are excluded or redacted. No failed upload is automatically replayed or switched to disk transport.

### Inspect an accepted import

If start returned `202` but the script failed during status lookup, the import may already have finished. Keep its journal and blob. In the same local PowerShell 7 session with the environment credentials loaded, set `$journal` to that run's journal filename and run the following read-only inspection. It requests a destination token and reads API status; it does not create another export/import, retry consumption, delete resources or rewrite the journal. It resolves the import ID from the specific blob's `SourceName`, without listing transfers.

```powershell
$journal = '.\journals\content-refresh-001.json'
Import-Module .\SitecoreTransfer.psm1 -Force
$execution = Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json -AsHashtable
$runtime = New-TransferRuntime `
    -SourceBaseUrl $env:SITECORE_TRANSFER_SOURCE_URL `
    -DestinationBaseUrl $env:SITECORE_TRANSFER_DESTINATION_URL
try {
    & (Get-Module SitecoreTransfer) {
        param($runtime, $execution)
        foreach ($set in $execution.ChunkSets) {
            if (-not $set.BlobName -or $set.BlobDeleted) { continue }
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $id = Resolve-ImportTransferId $runtime $set $execution.Configuration.Database $timer 30 5
            $details = (Invoke-TransferJson $runtime Destination GET "$script:ItemBase/transfers/$([uri]::EscapeDataString($id))").Data
            $blob = (Invoke-TransferJson $runtime Destination GET "$script:ItemBase/sources/blobs/$([uri]::EscapeDataString($set.BlobName))").Data
            [pscustomobject]@{
                ImportId = $id
                TransferState = $details.TransferState
                BlobState = $blob.BlobState
                ValidationErrorCount = @($details.ValidationErrors | Where-Object { $_ }).Count
            }
        }
    } $runtime $execution
}
finally { $runtime.Client.Dispose() }
```

Confirm `Finished`, `Transferred`, and zero validation errors before treating the import as successful. This inspection leaves blob cleanup for a separately authorized action using the documented delete endpoint. A new run is not a resume of the accepted import.

## API references

- [Sitecore migration walkthrough](https://doc.sitecore.com/sai/en/developers/sitecoreai/deploying-sitecoreai/migrating-content-between-sitecoreai-environments/migrate-content-between-sitecoreai-environments.html)
- [Content Transfer API](https://api-docs.sitecore.com/sai/content-transfer-api)
- [Item Transfer API](https://api-docs.sitecore.com/sai/item-transfer-api)
