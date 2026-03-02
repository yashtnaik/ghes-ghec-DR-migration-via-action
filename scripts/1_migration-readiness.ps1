<#
.SYNOPSIS
Pre-migration readiness checks for GHES repos listed in repos.csv (comma-delimited).

.PARAMETER GH_PAT
(Not used in current logic but kept for parity with bash script.)

.PARAMETER GH_SOURCE_PAT
Token used to call GHES API.

.PARAMETER GHES_API_URL
Base API URL, e.g. https://ghe.example.com/api/v3
#>

param(
    [string]$GH_PAT        = $env:GH_PAT,
    [string]$GH_SOURCE_PAT = $env:GH_SOURCE_PAT,
    [string]$GHES_API_URL  = $env:GHES_API_URL
)

# Allow positional args like the bash script:
#   ./migration-readiness.ps1 <GH_PAT> <GH_SOURCE_PAT> <GHES_API_URL>
if (-not $GH_PAT -and $args.Count -ge 1)        { $GH_PAT        = $args[0] }
if (-not $GH_SOURCE_PAT -and $args.Count -ge 2) { $GH_SOURCE_PAT = $args[1] }
if (-not $GHES_API_URL -and $args.Count -ge 3)  { $GHES_API_URL  = $args[2] }

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function UrlEncode([string]$s) {
    # Safe for path segments.
    return [System.Uri]::EscapeDataString($s)
}

# Validate required inputs (parity with bash)
if ([string]::IsNullOrWhiteSpace($GH_PAT)) {
    Write-Err "GH_PAT environment variable is not set. Please set your GitHub Personal Access Token."
    exit 1
}
if ([string]::IsNullOrWhiteSpace($GH_SOURCE_PAT)) {
    Write-Err "GH_SOURCE_PAT environment variable is not set. Please set your GitHub Source Personal Access Token."
    exit 1
}
if ([string]::IsNullOrWhiteSpace($GHES_API_URL)) {
    Write-Err "GHES_API_URL environment variable is not set. Please set your GitHub Enterprise Server API URL."
    exit 1
}

# Normalize URL (remove trailing slash)
$GHES_API_URL = $GHES_API_URL.TrimEnd('/')

# Totals (same counters)
[int]$total_repos = 0
[int]$repos_with_active_prs = 0
[int]$repos_with_workflows = 0
[int]$repos_with_open_issues = 0

# Repo results map: repoName => "Active PR, Workflow..., Open Issues" / "No Active/Open Items"
$repo_results = @{}

# Locate repos.csv in the same directory as this script
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$csvPath = Join-Path $scriptDir "repos.csv"

if (-not (Test-Path $csvPath)) {
    Write-Host "CSV file $csvPath not found. Exiting..."
    exit 1
} else {
    Write-Host "`nReading input from file: '$csvPath'"
}

# Shared headers for GHES API calls
$headers = @{
    Authorization = "token $GH_SOURCE_PAT"
    Accept        = "application/vnd.github+json"
}

function Invoke-GhesGet {
    param([string]$Uri)

    # Return a small object: StatusCode + Json (or $null)
    try {
        $resp = Invoke-WebRequest -Method GET -Uri $Uri -Headers $headers -ErrorAction Stop
        $json = $null
        if (-not [string]::IsNullOrWhiteSpace($resp.Content)) {
            $json = $resp.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        }
        return [pscustomobject]@{
            StatusCode = [int]$resp.StatusCode
            Json       = $json
        }
    }
    catch {
        # Try to capture HTTP status and JSON body (e.g., 404 Not Found)
        $status = $null
        $json = $null

        try {
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                    if (-not [string]::IsNullOrWhiteSpace($body)) {
                        $json = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                    }
                }
            }
        } catch { }

        return [pscustomobject]@{
            StatusCode = $status
            Json       = $json
        }
    }
}

# --- Read CSV using schema; use only first 2 columns: ghes_org, ghes_repo; ignore rest ---
# repos.csv schema: ghes_org, ghes_repo, repo_url, repo_size_MB, github_org, github_repo, gh_repo_visibility
$rows = Import-Csv -Path $csvPath

foreach ($row in $rows) {
    # Use only the first two columns from schema
    $ghes_org = ($row.ghes_org  | ForEach-Object { "$_".Trim().Trim('"') })
    $ghes_repo = ($row.ghes_repo | ForEach-Object { "$_".Trim().Trim('"') })

    if ([string]::IsNullOrWhiteSpace($ghes_org) -or [string]::IsNullOrWhiteSpace($ghes_repo)) {
        Write-Host "[ERROR] Organization or repository name is empty. Skipping..." -ForegroundColor Red
        continue
    }

    Write-Host "Processing Organization: '$ghes_org', Repository: '$ghes_repo'"

    $enc_org  = UrlEncode $ghes_org
    $enc_repo = UrlEncode $ghes_repo

    # Initialize result
    $repo_results[$ghes_repo] = ""

    # --- PRs ---
    $prUri = "$GHES_API_URL/repos/$enc_org/$enc_repo/pulls?state=open"
    $prResp = Invoke-GhesGet -Uri $prUri

    if (-not $prResp.StatusCode) {
        Write-Host "[ERROR] Failed to process PRs for repository '$ghes_repo'." -ForegroundColor Red
        continue
    }
    if ($prResp.StatusCode -ge 400 -and $prResp.StatusCode -ne 404) {
        Write-Host "[ERROR] Failed to process PRs for repository '$ghes_repo' (HTTP $($prResp.StatusCode))." -ForegroundColor Red
        continue
    }

    # PR endpoint returns array; on 404 treat as 0
    $prCount = 0
    if ($prResp.StatusCode -ne 404 -and $null -ne $prResp.Json) {
        $prCount = @($prResp.Json).Count
    }

    $total_repos++

    if ($prCount -gt 0) {
        $repos_with_active_prs++
        $repo_results[$ghes_repo] = "Active PR"
    }

    # --- Workflows (running/queued) ---
    $workflowsUri = "$GHES_API_URL/repos/$enc_org/$enc_repo/actions/runs"
    $wfResp = Invoke-GhesGet -Uri $workflowsUri

    # If endpoint not available (404) or error, treat as 0
    if ($wfResp.StatusCode -and $wfResp.StatusCode -lt 400 -and $wfResp.Json -and $wfResp.Json.workflow_runs) {
        $runningOrQueuedCount = @(
            $wfResp.Json.workflow_runs |
                Where-Object { $_.status -eq "in_progress" -or $_.status -eq "queued" }
        ).Count

        if ($runningOrQueuedCount -gt 0) {
            $repos_with_workflows++
            if ([string]::IsNullOrWhiteSpace($repo_results[$ghes_repo])) {
                $repo_results[$ghes_repo] = "Workflow (Running or Queued)"
            } else {
                $repo_results[$ghes_repo] += ", Workflow (Running or Queued)"
            }
        }
    }

    # --- Open issues excluding PRs ---
    $openIssuesUri = "$GHES_API_URL/repos/$enc_org/$enc_repo/issues?state=open"
    $issuesResp = Invoke-GhesGet -Uri $openIssuesUri

    # If endpoint not available (404) or error, treat as 0
    if ($issuesResp.StatusCode -and $issuesResp.StatusCode -lt 400 -and $issuesResp.Json) {
        # Exclude items that are PRs (they have pull_request property)
        $openIssuesCount = @(
            @($issuesResp.Json) | Where-Object { $null -eq $_.pull_request }
        ).Count

        if ($openIssuesCount -gt 0) {
            $repos_with_open_issues++
            if ([string]::IsNullOrWhiteSpace($repo_results[$ghes_repo])) {
                $repo_results[$ghes_repo] = "Open Issues"
            } else {
                $repo_results[$ghes_repo] += ", Open Issues"
            }
        }
    }

    # If nothing found
    if ([string]::IsNullOrWhiteSpace($repo_results[$ghes_repo])) {
        $repo_results[$ghes_repo] = "No Active/Open Items"
    }
}

# --- Final Consolidated Summary ---
Write-Host "`nPre-Migration Consolidated Summary"
Write-Host "====================================="
Write-Host "Total Repositories Processed: $total_repos"
Write-Host "Repositories with Active Pull Requests: $repos_with_active_prs"
Write-Host "Repositories with Workflows (Running or Queued): $repos_with_workflows"
Write-Host "Repositories with Open Issues: $repos_with_open_issues"

if ($repos_with_active_prs -gt 0) {
    Write-Host "Warning: Some repositories have active pull requests. Please review them before proceeding." -ForegroundColor Yellow
}
if ($repos_with_open_issues -gt 0) {
    Write-Host "Warning: Some repositories have open issues. Please review them before proceeding." -ForegroundColor Yellow
}
if ($total_repos -eq 0) {
    Write-Host "[ERROR] No repositories were processed. Please check your CSV file." -ForegroundColor Red
    exit 1
}

# --- Repo-specific results ---
Write-Host "`nRepository-Specific Results:"
Write-Host "============================="

foreach ($repo in $repo_results.Keys) {
    $val = $repo_results[$repo]
    if ($val -eq "No Active/Open Items") {
        Write-Host "${repo}: $val" -ForegroundColor Green
    } else {
        Write-Host "${repo}: $val"
    }
}

Write-Host "============================="
Write-Host "`nMigration validation complete. You can now proceed with migration if the necessary checks are met."