<#
.SYNOPSIS
Installs the Cutefish applications into a WSL distribution, to run as
Windows windows through WSLg.

.DESCRIPTION
Builds the Cutefish applications from source inside a WSL distribution, with
the patches that let them run under WSLg, and installs them as Debian
packages. The distribution is an existing Debian 13 or Ubuntu 26.04 (or
newer) one, or a new Debian 13 one this script creates.

It also sets the WSLg options in %USERPROFILE%\.wslgconfig that give Linux
windows the Windows display scale, rounded to a whole number, and the
applications' own icons.

Every choice can be passed as a parameter, or as a CUTEFISH_WSLG_*
environment variable when the script is piped into Invoke-Expression.

.PARAMETER Distro
Existing WSL distribution to install into. Environment: CUTEFISH_WSLG_DISTRO.

.PARAMETER NewDistro
Create a new Debian 13 distribution instead. Environment:
CUTEFISH_WSLG_NEW_DISTRO=1.

.PARAMETER NewDistroName
Name of the new distribution. Default: Cutefish. Environment:
CUTEFISH_WSLG_NEW_DISTRO_NAME.

.PARAMETER UserName
User to create in the new distribution. Default: the Windows user name.
Environment: CUTEFISH_WSLG_USER.

.PARAMETER Channel
stable builds the upstream commits this repository pins and tests; nightly
builds the newest upstream commits. Default: stable. Environment:
CUTEFISH_WSLG_CHANNEL.

.PARAMETER NonInteractive
Never prompt; choices not given take their defaults, and a distribution must
be named with -Distro or -NewDistro. Environment: CUTEFISH_WSLG_NONINTERACTIVE=1.

.PARAMETER SkipWslgConfig
Leave %USERPROFILE%\.wslgconfig unchanged.

.PARAMETER NoRestart
Do not restart the distribution at the end. WSLg picks up the icons and its
options only when it restarts.

.PARAMETER Repository
Git repository to install from. Default: https://github.com/trojaner/cutefish-wslg.git.
A local path installs from a local clone.

.PARAMETER Ref
Branch or tag of the repository. Default: main.

.EXAMPLE
irm https://raw.githubusercontent.com/trojaner/cutefish-wslg/main/install.ps1 | iex

Asks which distribution and channel to use.

.EXAMPLE
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/trojaner/cutefish-wslg/main/install.ps1))) -Distro Ubuntu -Channel stable -NonInteractive

Installs into the existing Ubuntu distribution without prompting.

.EXAMPLE
$env:CUTEFISH_WSLG_NEW_DISTRO = 1; $env:CUTEFISH_WSLG_NONINTERACTIVE = 1
irm https://raw.githubusercontent.com/trojaner/cutefish-wslg/main/install.ps1 | iex

Creates a new Debian 13 distribution named Cutefish without prompting.
#>
[CmdletBinding()]
param(
    [string] $Distro = $env:CUTEFISH_WSLG_DISTRO,
    [switch] $NewDistro = ($env:CUTEFISH_WSLG_NEW_DISTRO -eq '1'),
    [string] $NewDistroName = $(if ($env:CUTEFISH_WSLG_NEW_DISTRO_NAME) { $env:CUTEFISH_WSLG_NEW_DISTRO_NAME } else { 'Cutefish' }),
    [string] $UserName = $env:CUTEFISH_WSLG_USER,
    [string] $Channel = $env:CUTEFISH_WSLG_CHANNEL,
    [switch] $NonInteractive = ($env:CUTEFISH_WSLG_NONINTERACTIVE -eq '1'),
    [switch] $SkipWslgConfig,
    [switch] $NoRestart,
    [string] $Repository = 'https://github.com/trojaner/cutefish-wslg.git',
    [string] $Ref = 'main'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The WSLg options cutefish-wslg needs; see README.md.
$WslgOptions = [ordered]@{
    # Integer HiDPI scale per monitor, rounded: 175% renders at 2x.
    'WESTON_RDP_FRACTIONAL_HI_DPI_SCALING_ROUNDUP'      = 'true'
    # No "[WARN:COPY MODE]" in front of window titles.
    'WESTON_RDP_COPY_WARNING_TITLE'                     = 'false'
    # No penguin badge over the applications' icons.
    'WESTON_RDPRAIL_SHELL_BLEND_OVERLAY_ICON_APPLIST'   = 'false'
    'WESTON_RDPRAIL_SHELL_BLEND_OVERLAY_ICON_TASKBAR'   = 'false'
}
$WslgSection = 'system-distro-env'

function Write-Step([string] $Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# Runs wsl.exe with UTF-8 output; returns its output lines, or throws. A plain
# function on purpose: it hands every argument, -d included, to wsl.exe as is.
function Invoke-Wsl {
    $Arguments = @($args | ForEach-Object { $_ })
    $previousEncoding = [Console]::OutputEncoding
    $previousUtf8 = $env:WSL_UTF8
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $env:WSL_UTF8 = '1'
        $output = & wsl.exe @Arguments 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) {
            throw "wsl $($Arguments -join ' ') failed ($LASTEXITCODE): $($output -join "`n")"
        }
        return $output
    } finally {
        [Console]::OutputEncoding = $previousEncoding
        $env:WSL_UTF8 = $previousUtf8
    }
}

# Runs a command in a distribution with its output on the console; throws on failure.
function Invoke-WslLive {
    param([string] $Name, [string] $User, [string[]] $Command)
    & wsl.exe -d $Name -u $User --exec @Command
    if ($LASTEXITCODE -ne 0) {
        throw "'$($Command -join ' ')' failed in $Name ($LASTEXITCODE)"
    }
}

function Read-Choice([string] $Prompt, [string[]] $Options, [int] $Default) {
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Options[$i])
    }
    while ($true) {
        $answer = Read-Host "$Prompt [$($Default + 1)]"
        if (-not $answer) { return $Default }
        $index = 0
        if ([int]::TryParse($answer, [ref] $index) -and $index -ge 1 -and $index -le $Options.Count) {
            return $index - 1
        }
        Write-Host "Choose 1 to $($Options.Count)."
    }
}

function Confirm-Step([string] $Prompt) {
    if ($NonInteractive) { return $true }
    $answer = Read-Host "$Prompt [Y/n]"
    return (-not $answer) -or ($answer -match '^[yY]')
}

function Assert-Wsl {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'WSL is not installed. Install it with: wsl --install'
    }
    $version = Invoke-Wsl --version
    $wsl = $version | Select-String -Pattern '^WSL[^:]*:\s*([\d.]+)' | Select-Object -First 1
    $wslg = $version | Select-String -Pattern '^WSLg[^:]*:\s*([\d.]+)' | Select-Object -First 1
    if (-not $wsl -or -not $wslg) {
        throw "Could not read the WSL and WSLg versions from 'wsl --version'; update WSL with: wsl --update"
    }
    # wsl --install --name needs 2.4.4.
    if ([version] $wsl.Matches[0].Groups[1].Value -lt [version] '2.4.4') {
        throw "WSL $($wsl.Matches[0].Groups[1].Value) is too old; update it with: wsl --update"
    }
}

function Get-WslDistro {
    Invoke-Wsl --list --quiet |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notlike 'docker-desktop*' }
}

function Get-DefaultUserName {
    $name = ($env:USERNAME).ToLowerInvariant() -replace '[^a-z0-9_-]', ''
    if ($name -notmatch '^[a-z_]') { $name = "u$name" }
    if ($name.Length -gt 32) { $name = $name.Substring(0, 32) }
    if ($name -eq 'u' -or $name -eq 'root') { $name = 'cutefish' }
    return $name
}

# Converts a Windows path into the distribution's view of it.
function ConvertTo-WslPath([string] $Name, [string] $Path) {
    return (Invoke-Wsl -d $Name -u root --exec wslpath -a -u $Path | Select-Object -First 1).Trim()
}

# Runs a bash script, written with Unix line endings, as root in a
# distribution; with -Capture, returns its output instead of showing it.
function Invoke-WslScript {
    param([string] $Name, [string] $Script, [string[]] $Arguments = @(), [switch] $Capture)
    $file = Join-Path ([IO.Path]::GetTempPath()) ("cutefish-wslg-{0}.sh" -f [guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($file, ($Script -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
        $command = @('bash', (ConvertTo-WslPath $Name $file)) + $Arguments
        if ($Capture) {
            return Invoke-Wsl (@('-d', $Name, '-u', 'root', '--exec') + $command)
        }
        Invoke-WslLive -Name $Name -User root -Command $command
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function New-CutefishDistro([string] $Name, [string] $User) {
    if ((Get-WslDistro) -contains $Name) {
        throw "A distribution named $Name already exists; pick another with -NewDistroName, or install into it with -Distro $Name"
    }
    Write-Step "Creating the Debian 13 distribution $Name"
    & wsl.exe --install Debian --name $Name --no-launch
    if ($LASTEXITCODE -ne 0) { throw "wsl --install Debian --name $Name failed ($LASTEXITCODE)" }

    $release = (Invoke-Wsl -d $Name -u root --exec cat /etc/debian_version | Select-Object -First 1).Trim()
    if ($release -notmatch '^13(\.|$)') {
        throw "The Debian image WSL installed is $release, not 13; remove it with: wsl --unregister $Name"
    }

    Write-Step "Creating the user $User"
    $setup = @'
set -Eeuo pipefail
user="$1"
id "$user" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --groups sudo "$user"
cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[user]
default=$user
EOF
'@
    Invoke-WslScript -Name $Name -Script $setup -Arguments @($User)

    if ($NonInteractive) {
        # No password to ask for: sudo without one, as root is a wsl -u root away anyway.
        $sudoers = "printf '%s ALL=(ALL) NOPASSWD:ALL\n' `"`$1`" > /etc/sudoers.d/90-cutefish-wslg && chmod 440 /etc/sudoers.d/90-cutefish-wslg"
        Invoke-WslScript -Name $Name -Script $sudoers -Arguments @($User)
        Write-Host "  $User has no password and uses sudo without one."
    } else {
        Write-Host "  Set the password of $User (for sudo):"
        Invoke-WslLive -Name $Name -User root -Command @('passwd', $User)
    }
    & wsl.exe --terminate $Name | Out-Null
}

# Turns on systemd, which gives the user the session bus the applications use.
function Enable-Systemd([string] $Name) {
    $script = @'
set -Eeuo pipefail
conf=/etc/wsl.conf
touch "$conf"
if grep -Eq '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' "$conf"; then
  exit 0
fi
if grep -Eq '^[[:space:]]*systemd[[:space:]]*=' "$conf"; then
  sed -Ei 's/^[[:space:]]*systemd[[:space:]]*=.*/systemd=true/' "$conf"
elif grep -Eq '^\[boot\]' "$conf"; then
  sed -i '/^\[boot\]/a systemd=true' "$conf"
else
  printf '\n[boot]\nsystemd=true\n' >> "$conf"
fi
echo changed
'@
    $result = Invoke-WslScript -Name $Name -Script $script -Capture
    if ($result -contains 'changed') {
        Write-Host "  Turned on systemd in /etc/wsl.conf; restarting $Name."
        & wsl.exe --terminate $Name | Out-Null
    }
}

function Assert-SupportedDistro([string] $Name) {
    $info = Invoke-Wsl -d $Name -u root --exec sh -c '. /etc/os-release; echo "$ID|${VERSION_ID:-}|$PRETTY_NAME"' |
        Select-Object -Last 1
    $id, $versionId, $pretty = $info.Trim().Split('|')
    $supported = ($id -eq 'debian' -and $versionId -eq '13') -or
        ($id -eq 'ubuntu' -and $versionId -match '^\d+\.\d+$' -and [version] $versionId -ge [version] '26.04')
    if (-not $supported) {
        throw "$Name runs $pretty; Cutefish needs Debian 13 or Ubuntu 26.04 or newer. Upgrade it, or use -NewDistro."
    }
    Write-Host "  $Name runs $pretty."
}

# Distributions running systemd share WSL's cgroup tree, so two of them
# cannot both run a user session for the same UID.
function Write-RunningDistroWarning([string] $Name) {
    $running = Invoke-Wsl --list --running --quiet |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -ne $Name -and $_ -notlike 'docker-desktop*' }
    if ($running) {
        Write-Warning ("Also running: {0}. Two systemd distributions running at once can stop the second one's user session from starting; if the applications do not open, stop the others with: wsl --terminate <name>" -f ($running -join ', '))
    }
}

function Set-WslgConfig {
    $path = Join-Path $env:USERPROFILE '.wslgconfig'
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $path) {
        foreach ($line in [IO.File]::ReadAllLines($path)) { $lines.Add($line) }
    }

    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ieq "[$WslgSection]") { $start = $i; break }
    }
    if ($start -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
        $lines.Add("[$WslgSection]")
        $start = $lines.Count - 1
    }

    $changed = $false
    foreach ($key in $WslgOptions.Keys) {
        $value = $WslgOptions[$key]
        $end = $lines.Count
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim().StartsWith('[')) { $end = $i; break }
        }
        $found = $false
        for ($i = $start + 1; $i -lt $end; $i++) {
            if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") {
                $found = $true
                if ($lines[$i] -ne "$key=$value") { $lines[$i] = "$key=$value"; $changed = $true }
            }
        }
        if (-not $found) {
            $insert = $end
            while ($insert -gt $start + 1 -and -not $lines[$insert - 1].Trim()) { $insert-- }
            $lines.Insert($insert, "$key=$value")
            $changed = $true
        }
    }

    if ($changed) {
        # WSLg reads values up to the line end, so the file keeps Unix line endings.
        [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
        Write-Host "  Updated $path; it applies to every WSL distribution as each restarts."
    } else {
        Write-Host "  $path already has the options."
    }
}

function Get-RepositorySource([string] $Name) {
    if (Test-Path -LiteralPath $Repository) {
        return 'file://' + (ConvertTo-WslPath $Name (Resolve-Path -LiteralPath $Repository).Path)
    }
    return $Repository
}

function Install-Cutefish([string] $Name, [string] $Source) {
    $bootstrap = @'
set -Eeuo pipefail
repository="$1" ref="$2" channel="$3"
export DEBIAN_FRONTEND=noninteractive
if ! command -v git >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends git ca-certificates >/dev/null
fi
dir=/var/lib/cutefish-wslg/src
rm -rf "$dir"
mkdir -p "$(dirname "$dir")"
git -c safe.directory='*' clone --quiet --depth 1 --branch "$ref" \
  --recurse-submodules --shallow-submodules "$repository" "$dir"
exec "$dir/linux/install.sh" --channel "$channel" --yes
'@
    Invoke-WslScript -Name $Name -Script $bootstrap -Arguments @($Source, $Ref, $Channel)
}

Assert-Wsl

if ($Distro -and $NewDistro) {
    throw 'Pass either -Distro or -NewDistro, not both.'
}
if (-not $Distro -and -not $NewDistro) {
    if ($NonInteractive) {
        throw 'Name the distribution with -Distro <name>, or pass -NewDistro to create one.'
    }
    $distros = @(Get-WslDistro)
    $options = @($distros) + "Create a new Debian 13 distribution"
    Write-Host 'Install Cutefish into which WSL distribution?'
    $choice = Read-Choice -Prompt 'Distribution' -Options $options -Default ($options.Count - 1)
    if ($choice -eq $distros.Count) { $NewDistro = $true } else { $Distro = $distros[$choice] }
}
if (-not $Channel) {
    $Channel = 'stable'
    if (-not $NonInteractive) {
        Write-Host 'Which channel?'
        $choice = Read-Choice -Prompt 'Channel' -Default 0 -Options @(
            'stable  - the upstream commits this repository pins and tests',
            'nightly - the newest upstream commits; the patches may not apply')
        $Channel = @('stable', 'nightly')[$choice]
    }
}
if ($Channel -notin @('stable', 'nightly')) {
    throw "-Channel is stable or nightly, not '$Channel'."
}

if ($NewDistro) {
    if (-not $UserName) {
        $UserName = Get-DefaultUserName
        if (-not $NonInteractive) {
            $answer = Read-Host "User name in $NewDistroName [$UserName]"
            if ($answer) { $UserName = $answer }
        }
    }
    if ($UserName -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        throw "'$UserName' is not a valid Linux user name."
    }
    New-CutefishDistro -Name $NewDistroName -User $UserName
    $Distro = $NewDistroName
} else {
    if ((Get-WslDistro) -notcontains $Distro) {
        throw "There is no WSL distribution named $Distro; 'wsl --list' shows them."
    }
    Write-Step "Checking $Distro"
    Assert-SupportedDistro $Distro
    Enable-Systemd $Distro
}

Write-RunningDistroWarning $Distro

if (-not $SkipWslgConfig) {
    Write-Step 'Setting the WSLg options'
    if (Confirm-Step "Set the WSLg options in $env:USERPROFILE\.wslgconfig (HiDPI rounding, application icons)?") {
        Set-WslgConfig
    }
}

Write-Step "Building and installing Cutefish in $Distro ($Channel channel)"
Install-Cutefish -Name $Distro -Source (Get-RepositorySource $Distro)

if (-not $NoRestart) {
    if (Confirm-Step "Restart $Distro now, so WSLg picks up the icons and options? Its open windows close.") {
        & wsl.exe --terminate $Distro | Out-Null
        Write-Host "  Restarted $Distro."
    }
}

Write-Step 'Done'
Write-Host "The Cutefish applications are in the Start menu under $Distro, or run one from the distribution, e.g.:"
Write-Host "  wsl -d $Distro -- cutefish-calculator"
