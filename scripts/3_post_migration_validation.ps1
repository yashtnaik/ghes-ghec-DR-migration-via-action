# GHES -> GitHub post-migration validation (PowerShell)
# repos.csv schema:
#   ghes_org,ghes_repo,repo_url,repo_size_MB,github_org,github_repo,gh_repo_visibility
# Uses only: ghes_org, ghes_repo, github_org, github_repo

Add-Type -AssemblyName System.Web

$LOG_FILE = "validation-log-$(Get-Date -Format 'yyyyMMdd').txt"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date), $Message
    $line | Tee-Object -FilePath $LOG_FILE -Append
}

# Validate env vars
if ([string]::IsNullOrWhiteSpace($env:GH_SOURCE_PAT)) { throw "GH_SOURCE_PAT environment variable is not set" }
if ([string]::IsNullOrWhiteSpace($env:GH_PAT))        { throw "GH_PAT environment variable is not set" }
if ([string]::IsNullOrWhiteSpace($env:GHES_API_URL))  { throw "GHES_API_URL environment variable is not set (e.g. https://ghe.example.com/api/v3)" }

$GHES_API_URL = $env:GHES_API_URL.TrimEnd('/')

function Get-NextLink {
    param([hashtable]$Headers)
    $link = $Headers["Link"]
    if ([string]::IsNullOrWhiteSpace($link)) { return $null }
    $m = [regex]::Match($link, '<([^>]+)>\s*;\s*rel="next"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Invoke-GhesPagedGet {
    param(
        [Parameter(Mandatory)] [string]$Url
    )
    $headers = @{
        "Accept"        = "application/vnd.github+json"
        "Authorization" = "token $($env:GH_SOURCE_PAT)"
    }

    $items = @()
    $next = $Url

    while ($next) {
        try {
            $resp = Invoke-WebRequest -Method GET -Uri $next -Headers $headers -ErrorAction Stop
            $json = $resp.Content | ConvertFrom-Json
            # Some endpoints return array
            if ($json -is [System.Collections.IEnumerable]) {
                $items += @($json)
            } else {
                $items += $json
            }
            $next = Get-NextLink -Headers $resp.Headers
        } catch {
            return $null
        }
    }
    return $items
}

function Get-GhesBranches {
    param([string]$Org,[string]$Repo)

    $o = [System.Uri]::EscapeDataString($Org)
    $r = [System.Uri]::EscapeDataString($Repo)
    $url = "$GHES_API_URL/repos/$o/$r/branches?per_page=100"

    $branches = Invoke-GhesPagedGet -Url $url
    if ($null -eq $branches) { return $null }
    return $branches | ForEach-Object { $_.name }
}

function Get-GhesCommitCountAndLatest {
    param([string]$Org,[string]$Repo,[string]$Branch)

    $o = [System.Uri]::EscapeDataString($Org)
    $r = [System.Uri]::EscapeDataString($Repo)
    $b = [System.Uri]::EscapeDataString($Branch)

    $headers = @{
        "Accept"        = "application/vnd.github+json"
        "Authorization" = "token $($env:GH_SOURCE_PAT)"
    }

    $count = 0
    $latest = ""
    $page = 1
    $per = 100

    while ($true) {
        $url = "$GHES_API_URL/repos/$o/$r/commits?sha=$b&per_page=$per&page=$page"
        try {
            $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -ErrorAction Stop
        } catch {
            break
        }

        $batch = @($resp)
        if ($page -eq 1 -and $batch.Count -gt 0) { $latest = $batch[0].sha }
        $count += $batch.Count
        if ($batch.Count -lt $per) { break }
        $page++
    }

    return [pscustomobject]@{ Count = $count; Latest = $latest }
}

function Get-GitHubBranches {
    param([string]$Org,[string]$Repo)
    $json = gh api "/repos/$Org/$Repo/branches" --paginate | ConvertFrom-Json
    return $json | ForEach-Object { $_.name }
}

function Get-GitHubCommitCountAndLatest {
    param([string]$Org,[string]$Repo,[string]$Branch)

    $count = 0
    $latest = ""
    $page = 1
    $per = 100
    $b = [System.Web.HttpUtility]::UrlEncode($Branch)

    do {
        $resp = gh api "/repos/$Org/$Repo/commits?sha=$b&page=$page&per_page=$per" | ConvertFrom-Json
        $batch = @($resp)
        if ($page -eq 1 -and $batch.Count -gt 0) { $latest = $batch[0].sha }
        $count += $batch.Count
        $page++
    } while ($batch.Count -eq $per)

    return [pscustomobject]@{ Count = $count; Latest = $latest }
}

function Validate-Migration {
    param(
        [string]$ghesOrg,
        [string]$ghesRepo,
        [string]$githubOrg,
        [string]$githubRepo
    )

    Write-Log "Validating migration: $ghesOrg/$ghesRepo -> $githubOrg/$githubRepo"

    # GitHub repo info
    gh repo view "$githubOrg/$githubRepo" --json createdAt,diskUsage,defaultBranchRef,isPrivate |
        Out-File -FilePath "validation-$githubRepo.json"

    # Target branches (GitHub)
    $ghBranchNames = Get-GitHubBranches -Org $githubOrg -Repo $githubRepo
    if ($null -eq $ghBranchNames) {
        Write-Log "ERROR: Failed to fetch GitHub branches for $githubOrg/$githubRepo"
        return
    }

    # Source branches (GHES)
    $srcBranchNames = Get-GhesBranches -Org $ghesOrg -Repo $ghesRepo
    if ($null -eq $srcBranchNames) {
        Write-Log "ERROR: Failed to fetch GHES branches for $ghesOrg/$ghesRepo"
        return
    }

    # Compare branch counts
    $ghCount  = @($ghBranchNames).Count
    $srcCount = @($srcBranchNames).Count
    $status = if ($ghCount -eq $srcCount) { "✅ Matching" } else { "❌ Not Matching" }
    Write-Log "Branch Count: GHES=$srcCount | GitHub=$ghCount | $status"

    # Compare branch names
    $missingInGitHub = $srcBranchNames | Where-Object { $_ -notin $ghBranchNames }
    $missingInGhes   = $ghBranchNames | Where-Object { $_ -notin $srcBranchNames }

    if (@($missingInGitHub).Count -gt 0) { Write-Log "Branches missing in GitHub: $($missingInGitHub -join ', ')" }
    if (@($missingInGhes).Count -gt 0)   { Write-Log "Branches missing in GHES: $($missingInGhes -join ', ')" }

    # Validate commit counts + latest SHA for common branches
    $common = $ghBranchNames | Where-Object { $_ -in $srcBranchNames }

    foreach ($branchName in $common) {
        $ghInfo  = Get-GitHubCommitCountAndLatest -Org $githubOrg -Repo $githubRepo -Branch $branchName
        $srcInfo = Get-GhesCommitCountAndLatest   -Org $ghesOrg   -Repo $ghesRepo   -Branch $branchName

        $countMatch = ($ghInfo.Count -eq $srcInfo.Count)
        $shaMatch   = ($ghInfo.Latest -eq $srcInfo.Latest)

        $commitCountStatus = if ($countMatch) { "✅ Matching" } else { "❌ Not Matching" }
        $shaStatus         = if ($shaMatch)   { "✅ Matching" } else { "❌ Not Matching" }

        Write-Log "Branch '$branchName': GHES Commits=$($srcInfo.Count) | GitHub Commits=$($ghInfo.Count) | $commitCountStatus"
        Write-Log "Branch '$branchName': GHES SHA=$($srcInfo.Latest) | GitHub SHA=$($ghInfo.Latest) | $shaStatus"
    }

    Write-Log "Validation complete for $githubOrg/$githubRepo"
}

function Validate-FromCSV {
    param([string]$csvPath = "repos.csv")

    if (-not (Test-Path $csvPath)) {
        Write-Log "ERROR: CSV file not found: $csvPath"
        return
    }

    $repos = Import-Csv -Path $csvPath

    # Ensure required columns exist
    $required = @('ghes_org','ghes_repo','github_org','github_repo')
    $missing = $required | Where-Object { $_ -notin $repos[0].PSObject.Properties.Name }
    if ($missing) {
        Write-Log "ERROR: CSV missing required columns: $($missing -join ', ')"
        return
    }

    foreach ($repo in $repos) {
        Write-Log ("Processing: {0}/{1} -> {2}/{3}" -f $repo.ghes_org, $repo.ghes_repo, $repo.github_org, $repo.github_repo)

        Validate-Migration -ghesOrg $repo.ghes_org `
                          -ghesRepo $repo.ghes_repo `
                          -githubOrg $repo.github_org `
                          -githubRepo $repo.github_repo
    }

    Write-Log "All validations from CSV completed"
}

# Run batch mode
Validate-FromCSV -csvPath "repos.csv"