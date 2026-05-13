# Checks prerequisites for the Entra Device Hygiene project.
# - Verifies PowerShell version
# - Checks required modules; reports missing, installed, and out-of-date
# - Never installs duplicates; only suggests Install-Module / Update-Module commands
# - Optional -Install switch installs missing modules (CurrentUser scope)
# - Optional -Upgrade switch updates outdated modules

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Upgrade
)

$ErrorActionPreference = 'Stop'

$RequiredModules = @(
    @{ Name = 'Microsoft.Graph.Authentication'; MinVersion = '2.15.0' }
    @{ Name = 'Microsoft.Graph.Groups';         MinVersion = '2.15.0' }
    @{ Name = 'Microsoft.Graph.Applications';   MinVersion = '2.15.0' }
    @{ Name = 'Microsoft.Graph.Identity.DirectoryManagement'; MinVersion = '2.15.0' }
)

function Write-Status {
    param([string]$Symbol, [ConsoleColor]$Color, [string]$Message)
    Write-Host ("  {0} {1}" -f $Symbol, $Message) -ForegroundColor $Color
}

Write-Host ""
Write-Host "== Entra Device Hygiene - Prerequisite Check ==" -ForegroundColor Cyan
Write-Host ""

# ---- PowerShell version ----
Write-Host "PowerShell" -ForegroundColor White
$psv = $PSVersionTable.PSVersion
if ($psv.Major -ge 7) {
    Write-Status '✓' Green "PowerShell $psv (>= 7.0)"
} elseif ($psv.Major -eq 5 -and $psv.Minor -ge 1) {
    Write-Status '!' Yellow "PowerShell $psv (5.1 works, but 7.x recommended)"
} else {
    Write-Status '✗' Red "PowerShell $psv is too old. Install 7.x: https://aka.ms/powershell"
}
Write-Host ""

# ---- Azure CLI ----
Write-Host "Azure CLI" -ForegroundColor White
$az = Get-Command az -ErrorAction SilentlyContinue
if ($az) {
    try {
        $azv = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
        Write-Status '✓' Green "az $azv at $($az.Source)"
    } catch {
        Write-Status '✓' Green "az present at $($az.Source) (version unreadable)"
    }
} else {
    Write-Status '✗' Red "Azure CLI not found. Install: https://aka.ms/InstallAzureCli"
}
Write-Host ""

# ---- Modules ----
Write-Host "PowerShell Modules" -ForegroundColor White

$missing  = @()
$outdated = @()
$ok       = @()
$duplicates = @()

foreach ($req in $RequiredModules) {
    $name = $req.Name
    $min  = [version]$req.MinVersion

    $installed = Get-Module -ListAvailable -Name $name |
                 Sort-Object Version -Descending

    if (-not $installed) {
        Write-Status '✗' Red "$name (not installed; need >= $min)"
        $missing += $req
        continue
    }

    $newest = $installed[0]

    if ($installed.Count -gt 1) {
        $versions = ($installed | ForEach-Object { $_.Version.ToString() }) -join ', '
        Write-Status '!' Yellow "$name has multiple versions installed: $versions"
        $duplicates += [pscustomobject]@{ Name = $name; Versions = $installed.Version }
    }

    if ($newest.Version -lt $min) {
        Write-Status '!' Yellow "$name $($newest.Version) installed; need >= $min"
        $outdated += $req
    } else {
        Write-Status '✓' Green "$name $($newest.Version) (>= $min)"
        $ok += $req
    }
}

# ---- Online check for newer versions (best-effort) ----
Write-Host ""
Write-Host "Checking PSGallery for newer versions..." -ForegroundColor White
foreach ($req in ($ok + $outdated)) {
    try {
        $gallery = Find-Module -Name $req.Name -ErrorAction Stop
        $localNewest = (Get-Module -ListAvailable -Name $req.Name | Sort-Object Version -Descending)[0].Version
        if ([version]$gallery.Version -gt $localNewest) {
            Write-Status '↑' Cyan "$($req.Name): $localNewest installed, $($gallery.Version) available"
            if ($req -notin $outdated) { $outdated += $req }
        }
    } catch {
        Write-Status '?' DarkGray "$($req.Name): could not query gallery ($($_.Exception.Message))"
    }
}

# ---- Summary & actions ----
Write-Host ""
Write-Host "== Summary ==" -ForegroundColor Cyan
Write-Host ("  OK:        {0}" -f $ok.Count)        -ForegroundColor Green
Write-Host ("  Outdated:  {0}" -f $outdated.Count)  -ForegroundColor Yellow
Write-Host ("  Missing:   {0}" -f $missing.Count)   -ForegroundColor Red
Write-Host ("  Duplicates:{0}" -f $duplicates.Count) -ForegroundColor Yellow

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "To install missing modules:" -ForegroundColor Cyan
    foreach ($m in $missing) {
        Write-Host "  Install-Module -Name $($m.Name) -MinimumVersion $($m.MinVersion) -Scope CurrentUser -Repository PSGallery"
    }
}

if ($outdated.Count -gt 0) {
    Write-Host ""
    Write-Host "To upgrade outdated modules:" -ForegroundColor Cyan
    foreach ($m in $outdated) {
        Write-Host "  Update-Module -Name $($m.Name) -Scope CurrentUser"
    }
}

if ($duplicates.Count -gt 0) {
    Write-Host ""
    Write-Host "Duplicate versions detected. To clean up older copies:" -ForegroundColor Yellow
    foreach ($d in $duplicates) {
        $old = $d.Versions | Sort-Object -Descending | Select-Object -Skip 1
        foreach ($v in $old) {
            Write-Host "  Uninstall-Module -Name $($d.Name) -RequiredVersion $v"
        }
    }
}

# ---- Optional auto-actions ----
if ($Install -and $missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Installing missing modules..." -ForegroundColor Cyan
    foreach ($m in $missing) {
        if (Get-Module -ListAvailable -Name $m.Name) {
            Write-Status '!' Yellow "$($m.Name) appeared since check; skipping to avoid duplicate."
            continue
        }
        Install-Module -Name $m.Name -MinimumVersion $m.MinVersion -Scope CurrentUser -Repository PSGallery -Force
        Write-Status '✓' Green "Installed $($m.Name)"
    }
}

if ($Upgrade -and $outdated.Count -gt 0) {
    Write-Host ""
    Write-Host "Upgrading outdated modules..." -ForegroundColor Cyan
    foreach ($m in $outdated) {
        Update-Module -Name $m.Name -Scope CurrentUser -ErrorAction Continue
        Write-Status '✓' Green "Updated $($m.Name)"
    }
}

if ($missing.Count -eq 0 -and $outdated.Count -eq 0 -and $duplicates.Count -eq 0) {
    Write-Host ""
    Write-Host "All prerequisites satisfied. You're good to go." -ForegroundColor Green
}

# Exit code: 0 only when nothing actionable remains
if ($missing.Count -gt 0) { exit 2 }
if ($outdated.Count -gt 0) { exit 1 }
exit 0
