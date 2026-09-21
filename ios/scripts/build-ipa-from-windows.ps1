# Build an unsigned iOS .ipa from Windows via GitHub Actions.
#
# iOS binaries can only be produced by Apple's toolchain, so this script does not
# compile anything locally. It pushes your working tree to GitHub, triggers the
# "iOS Unsigned IPA" workflow on a macOS runner, waits for it, and downloads the
# resulting .ipa into .\build\ios\.
#
# Prerequisites (one time):
#   winget install --id GitHub.cli
#   gh auth login
#   -> the repo must have a GitHub remote, and the workflow file must be pushed
#
# Usage:
#   .\ios\scripts\build-ipa-from-windows.ps1
#   .\ios\scripts\build-ipa-from-windows.ps1 -Version 2.0.1 -BuildNumber 8
#   .\ios\scripts\build-ipa-from-windows.ps1 -Configuration Debug
#   .\ios\scripts\build-ipa-from-windows.ps1 -SkipPush      # build current remote HEAD
#
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [string]$Version = '',
    [string]$BuildNumber = '',

    [string]$WorkflowFile = 'ios-unsigned-ipa.yml',
    [string]$OutputDir = '',

    [switch]$SkipPush,
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "OK  $msg" -ForegroundColor Green }
function Fail($msg)       { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# --------------------------------------------------------------- repo layout
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'build\ios' }

Write-Step "Repository: $repoRoot"

# ------------------------------------------------------------- prerequisites
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "git not found. Install Git for Windows."
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Fail @"
GitHub CLI (gh) not found. Install and authenticate it first:

    winget install --id GitHub.cli
    gh auth login
"@
}

Push-Location $repoRoot
try {
    # ------------------------------------------------------------ git remote
    $remoteUrl = (git remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $remoteUrl) {
        Fail "No 'origin' remote configured. Create a GitHub repo and run: git remote add origin <url>"
    }
    $repoSlug = if ($remoteUrl -match 'github\.com[:/](?<slug>[^/]+/[^/]+?)(\.git)?$') {
        $Matches['slug']
    } else {
        Fail "Could not parse a GitHub repo from remote '$remoteUrl'. Only github.com is supported."
    }
    Write-Ok "GitHub repo: $repoSlug"

    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "gh is not authenticated. Run: gh auth login" }

    # --------------------------------------------------------------- workflow
    $workflowPath = Join-Path $repoRoot ".github\workflows\$WorkflowFile"
    if (-not (Test-Path $workflowPath)) {
        Fail "Workflow not found: $workflowPath"
    }

    # ------------------------------------------------------------ push commit
    if (-not $SkipPush) {
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        if ($branch -eq 'HEAD') { Fail "Detached HEAD; check out a branch before building." }

        $dirty = (git status --porcelain)
        if ($dirty) {
            Write-Step "Committing local changes on '$branch' so the runner can see them..."
            git add -A
            git commit -m "chore(ios): build unsigned ipa ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))" | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail "git commit failed." }
            Write-Ok "Committed working tree."
        } else {
            Write-Step "Working tree clean; using existing commit."
        }

        Write-Step "Pushing '$branch' to origin..."
        git push origin $branch
        if ($LASTEXITCODE -ne 0) { Fail "git push failed." }
        Write-Ok "Pushed."
    } else {
        Write-Step "Skipping push (-SkipPush); building the current remote HEAD."
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    }

    if ($branch -eq 'HEAD') {
        $branch = (gh repo view $repoSlug --json defaultBranchRef --jq '.defaultBranchRef.name')
    }

    # ------------------------------------------------------- dispatch workflow
    Write-Step "Triggering workflow '$WorkflowFile' on branch '$branch'..."

    $ghArgs = @(
        'workflow', 'run', $WorkflowFile,
        '--repo', $repoSlug,
        '--ref', $branch,
        '-f', "configuration=$Configuration"
    )
    if ($Version)     { $ghArgs += @('-f', "version=$Version") }
    if ($BuildNumber) { $ghArgs += @('-f', "build_number=$BuildNumber") }

    # Capture the run id created by this dispatch so we watch the right one.
    $beforeIds = @(gh run list --repo $repoSlug --workflow $WorkflowFile --limit 20 --json databaseId --jq '.[].databaseId' 2>$null)

    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) {
        Fail @"
Failed to trigger the workflow. Common causes:
  - The workflow file is not on '$branch' yet (push it first).
  - Actions are disabled for this repository.
  - The repo has no 'workflow' scope on your token (re-run: gh auth login).
"@
    }

    # -------------------------------------------------------------- find run
    Write-Step "Locating the queued run..."
    $runId = $null
    $deadline = (Get-Date).AddMinutes(2)
    while (-not $runId -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $afterIds = @(gh run list --repo $repoSlug --workflow $WorkflowFile --limit 20 --json databaseId --jq '.[].databaseId' 2>$null)
        $new = $afterIds | Where-Object { $_ -and ($beforeIds -notcontains $_) }
        if ($new) { $runId = ($new | Select-Object -First 1) }
    }
    if (-not $runId) {
        # Fall back to the most recent run for this workflow.
        $runId = (gh run list --repo $repoSlug --workflow $WorkflowFile --limit 1 --json databaseId --jq '.[0].databaseId')
    }
    if (-not $runId) { Fail "Could not determine the run id. Check the Actions tab manually." }

    $runUrl = "https://github.com/$repoSlug/actions/runs/$runId"
    Write-Ok "Run: $runUrl"

    # ---------------------------------------------------------------- monitor
    Write-Step "Waiting for the macOS runner (this typically takes 5-15 minutes)..."
    Write-Host "     Live log: gh run watch $runId --repo $repoSlug" -ForegroundColor DarkGray

    $watchTimeoutSec = $TimeoutMinutes * 60
    $elapsed = 0
    $pollEvery = 15

    while ($true) {
        if ($elapsed -ge $watchTimeoutSec) {
            Fail "Timed out after $TimeoutMinutes minutes. Check: $runUrl"
        }
        Start-Sleep -Seconds $pollEvery
        $elapsed += $pollEvery

        $status = (gh run view $runId --repo $repoSlug --json status,conclusion --jq '.status')
        $conclusion = (gh run view $runId --repo $repoSlug --json status,conclusion --jq '.conclusion')

        if ($status -eq 'completed') { break }

        # Print a compact progress hint.
        $mins = [math]::Floor($elapsed / 60)
        $secs = $elapsed % 60
        Write-Host ("`r     status: {0}  elapsed: {1:00}:{2:00}   " -f $status, $mins, $secs) -NoNewline
    }
    Write-Host ''

    if ($conclusion -ne 'success') {
        Write-Host ''
        Write-Host "Build finished with conclusion: $conclusion" -ForegroundColor Red
        Write-Host ''
        Write-Step "Failed step log:"
        gh run view $runId --repo $repoSlug --log-failed
        Fail "Build did not succeed. Full run: $runUrl"
    }

    Write-Ok "Build succeeded."

    # -------------------------------------------------------------- download
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    Write-Step "Downloading artifact to $OutputDir ..."

    gh run download $runId --repo $repoSlug --name 'ios-unsigned-ipa' --dir $OutputDir
    if ($LASTEXITCODE -ne 0) { Fail "Artifact download failed. Get it manually: $runUrl" }

    $ipa = Get-ChildItem -Path $OutputDir -Filter '*.ipa' -Recurse -File | Select-Object -First 1
    if (-not $ipa) { Fail "Downloaded artifact contained no .ipa. See: $runUrl" }

    # ---------------------------------------------------------------- report
    $hash = (Get-FileHash -Algorithm SHA256 -Path $ipa.FullName).Hash.ToLower()
    $sizeMb = [math]::Round($ipa.Length / 1MB, 1)

    Write-Host ''
    Write-Host '======================================================================' -ForegroundColor Green
    Write-Host ' Unsigned IPA downloaded' -ForegroundColor Green
    Write-Host '======================================================================' -ForegroundColor Green
    Write-Host " Path:    $($ipa.FullName)"
    Write-Host " Size:    $sizeMb MB"
    Write-Host " SHA-256: $hash"
    Write-Host " Run:     $runUrl"
    Write-Host ''
    Write-Host ' This IPA is NOT signed and will not install on a device as-is.' -ForegroundColor Yellow
    Write-Host ' Install it with Sideloadly, AltStore/SideStore, or zsign.' -ForegroundColor Yellow
    Write-Host '======================================================================' -ForegroundColor Green
}
finally {
    Pop-Location
}
