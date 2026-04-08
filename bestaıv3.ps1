# ============================================================
#  LOCAL AI SERVER SETUP v3.0 - Powered by Ollama
#  Siber Akademi | Toprak Ahmet Aydoğmuş
#  github.com/toprak | hopp.bio/siberegitim
# ============================================================
#  OZELLIKLER:
#  - Ollama otomatik kurulum (Windows / Linux)
#  - GPU algilama (NVIDIA CUDA / AMD ROCm)
#  - Sistem kaynak kontrolu (RAM / Disk / CPU)
#  - Guclu model yonetimi (indirme / silme / listeleme)
#  - Caddy Reverse Proxy + HTML Web Arayuzu
#  - Cloudflare Tunnel (global erisim)
#  - ngrok alternatif tunel destegi
#  - Servis yonetimi (baslat / durdur / yeniden baslat)
#  - Detayli log sistemi
#  - Guvenlik: API anahtar korumasi
#  - Yedekleme / geri yukleme
#  - Model benchmark testi
#  - Otomatik guncelleme kontrolu
#  - Kurulum geri alma (uninstall)
#  - Gelismis HTML UI (dark/neon tema, dosya yukleme, ses)
# ============================================================

$Host.UI.RawUI.WindowTitle = "LOCAL AI SERVER SETUP v3.0 - Siber Akademi"
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
#  GLOBAL DEGISKENLER
# ============================================================
$SCRIPT_VERSION = "3.0.0"
$OLLAMA_PORT = 11434
$CADDY_PORT = 8080
# ============================================================
# Ensure admin elevation before creating data folder (prevents access denied)
function Pause-Screen { param([string]$Message = "Press ENTER to continue...") Write-Host ""; Write-Host "  $Message" -ForegroundColor Yellow; Read-Host | Out-Null; exit }

# If Windows, re-launch elevated if needed
if ($env:OS -match "Windows") {
    try {
        $scriptPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } elseif ($PSCommandPath) { $PSCommandPath } else { $null }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $isAdmin = $false }

    if (-not $isAdmin) {
        Write-Host "  Yonetici izni gerekiyor. Yeniden baslatiliyor..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        if ($scriptPath) {
            Start-Process -FilePath "powershell" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`"" -Verb RunAs
        }
        else {
            Start-Process -FilePath "powershell" -ArgumentList "-ExecutionPolicy Bypass -NoProfile" -Verb RunAs
        }
        exit
    }
}

# Fast executable find: checks Get-Command, PATH dirs, and common install locations quickly (timeout in ms)
function Find-ExecutableFast {
    param([string]$Name, [int]$TimeoutMs = 2000)
    if (-not $Name) { return $null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # 1) Get-Command (very fast)
    try {
        $cmd = Get-Command $Name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    } catch {}
    if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $null }

    # 2) PATH directories
    try {
        $pathDirs = ($env:Path -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and (Test-Path $_) }
        foreach ($d in $pathDirs) {
            if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { break }
            $cand = Join-Path $d $Name
            if ($checkIsWindows -and ($cand -notlike '*.exe')) { $cand = "$cand.exe" }
            if (Test-Path $cand) { return (Get-Item $cand).FullName }
        }
    } catch {}
    if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $null }

    # 3) Common locations (ProgramFiles, LocalAppData, ProgramData)
    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA "Programs" }
    if ($env:ProgramFiles) { $candidates += $env:ProgramFiles }
    if (${env:ProgramFiles(x86)}) { $candidates += ${env:ProgramFiles(x86)} }
    if ($env:ProgramData) { $candidates += $env:ProgramData }

    foreach ($base in $candidates | Where-Object { $_ -and (Test-Path $_) }) {
        if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { break }
        # direct path
        try {
            $cand = Join-Path $base $Name
            if ($checkIsWindows -and ($cand -notlike '*.exe')) { $cand = "$cand.exe" }
            if (Test-Path $cand) { return (Get-Item $cand).FullName }

            # shallow search for directories with executable name
            $found = Get-ChildItem -Path $base -Filter "*$Name*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $exe = Join-Path $found.FullName $Name
                if ($checkIsWindows) { $exe = "$exe.exe" }
                if (Test-Path $exe) { return (Get-Item $exe).FullName }
            }
        } catch {}
    }

    return $null
}

$BASE_PATH = if ($PSScriptRoot) { "$PSScriptRoot\ai_server_data" } else { "$env:USERPROFILE\Desktop\ai_server_data" }
if (-not (Test-Path $BASE_PATH)) { New-Item -ItemType Directory -Path $BASE_PATH -Force | Out-Null }

$LOG_DIR = "$BASE_PATH\logs"
$WEB_DIR = "$BASE_PATH\web"
$CONFIG_FILE = "$BASE_PATH\config.json"
$API_KEY_FILE = "$BASE_PATH\apikey.txt"
$BACKUP_DIR = "$BASE_PATH\backups"
$CADDY_EXE = "$BASE_PATH\caddy"
$CF_EXE = "$BASE_PATH\cloudflared"
$NGROK_EXE = "$BASE_PATH\ngrok"
$LOG_FILE = "$LOG_DIR\setup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# OS detect
$checkIsLinux = $IsLinux -or ($PSVersionTable.OS -match "Linux")
$checkIsWindows = $IsWindows -or ($PSVersionTable.OS -match "Windows") -or ($env:OS -match "Windows")

if ($checkIsWindows) {
    $CADDY_EXE += ".exe"
    $CF_EXE += ".exe"
    $NGROK_EXE += ".exe"
}

# Runtime state
$global:isRemote = $false
$global:bindIp = "127.0.0.1"
$global:tunnelMode = "cloudflare"
$global:useApiKey = $false
$global:generatedApiKey = ""
$global:gpuInfo = @{ Available = $false; Type = "CPU"; VRAM = 0 }
$global:systemInfo = @{ RAM = 0; FreeRAM = 0; FreeDisk = 0; CPUCores = 0 }
$global:ollamaRunning = $false
$global:caddyRunning = $false
$global:tunnelUrl = "Kapali"
$global:selectedModels = @()
$global:installedModels = @()
$global:benchmarkResults = @{}

# ============================================================
#  YARDIMCI: LOG + EKRAN YAZICILARI
# ============================================================
function Init-Logging {
    if (-not (Test-Path $LOG_DIR)) {
        New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    }
    "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [INFO] Siber Akademi AI Server Setup v$SCRIPT_VERSION baslatildi." | Out-File -FilePath $LOG_FILE -Encoding UTF8
}

function Write-Log {
    param([string]$Level = "INFO", [string]$Message)
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] [$Level] $Message"
    $line | Out-File -FilePath $LOG_FILE -Append -Encoding UTF8
}

function Pause-Screen {
    Write-Host ""
    Write-Host "  ==========================================" -ForegroundColor Gray
    Write-Host "  Cikmak icin LUTFEN [ENTER] tusuna basin..." -ForegroundColor Green
    Write-Host "  ==========================================" -ForegroundColor Gray
    $null = Read-Host
    exit
}

function Get-LocalIPs {
    if ($checkIsWindows) {
        try {
            return Get-NetIPAddress -AddressFamily IPv4 | 
            Where-Object { $_.InterfaceAlias -notmatch "Loopback|vEthernet|Pseudo" -and $_.IPAddress -notmatch "^169\." } | 
            Select-Object -ExpandProperty IPAddress
        }
        catch { return @() }
    }
    else {
        try { return (hostname -I).Trim().Split(" ") | Where-Object { $_ -ne "" } } catch { return @() }
    }
}

trap {
    $errMsg = $_.Exception.Message
    Write-Host ""
    Write-Host "  [HATA OLUSTU] $errMsg" -ForegroundColor Red
    Write-Log -Level "ERROR" -Message $errMsg
    Pause-Screen
}

function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  +==========================================================+" -ForegroundColor DarkYellow
    Write-Host "  |                                                          |" -ForegroundColor DarkYellow
    Write-Host "  |   ####  #  ###  ####  ###        ##   #                  |" -ForegroundColor Yellow
    Write-Host "  |  #      #  #  # #     #  #      #  #  #                  |" -ForegroundColor Yellow
    Write-Host "  |   ###   #  ###  ###   ###       ####  #                  |" -ForegroundColor Yellow
    Write-Host "  |      #  #  #  # #     #  #      #  #  #                  |" -ForegroundColor Yellow
    Write-Host "  |  ####   #  ###  ####  #  #      #  #  #                  |" -ForegroundColor Yellow
    Write-Host "  |                                                          |" -ForegroundColor DarkYellow
    Write-Host "  |          LOCAL AI SERVER SETUP  v$SCRIPT_VERSION               |" -ForegroundColor Cyan
    Write-Host "  |       Siber Akademi | Toprak Ahmet Aydogmus          |" -ForegroundColor DarkCyan
    Write-Host "  |          hopp.bio/siberegitim                          |" -ForegroundColor Gray
    Write-Host "  |                                                          |" -ForegroundColor DarkYellow
    Write-Host "  +==========================================================+" -ForegroundColor DarkYellow
    Write-Host ""
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  +------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ("  |  " + $Title.PadRight(52) + "  |") -ForegroundColor Cyan
    Write-Host "  +------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Log -Level "SECTION" -Message $Title
}

function Write-Step {
    param([string]$msg)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "  [$ts] >> " -NoNewline -ForegroundColor Cyan
    Write-Host $msg -ForegroundColor White
    Write-Log -Level "STEP" -Message $msg
}

function Write-OK {
    param([string]$msg)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "  [$ts] " -NoNewline -ForegroundColor Green
    Write-Host "[OK] " -NoNewline -ForegroundColor Green
    Write-Host $msg -ForegroundColor Gray
    Write-Log -Level "OK" -Message $msg
}

function Set-EnvSafe {
    param([string]$Name, [string]$Value)
    $current = [System.Environment]::GetEnvironmentVariable($Name, "Machine")
    if ($current -ne $Value) {
        [System.Environment]::SetEnvironmentVariable($Name, $Value, "Machine")
    }
    # Her zaman process ortaminda da guncelle (hizli)
    [System.Environment]::SetEnvironmentVariable($Name, $Value, "Process")
}

function Add-Directory-To-SystemPath {
    param([string]$Dir)
    if (-not $Dir) { return }
    if (-not (Test-Path $Dir)) { return }
    try {
        # Normalize path
        try { $full = (Get-Item -LiteralPath $Dir).FullName } catch { $full = $Dir }

        # Update process PATH immediately so current session sees the change
        $currentParts = $env:Path -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($currentParts -notcontains $full) {
            $env:Path = "$full;$env:Path"
            Write-OK "Process PATH guncellendi: $full"
        }

        # Add to User PATH (does not require admin)
        try {
            $userPath = [System.Environment]::GetEnvironmentVariable('Path','User')
            if (-not $userPath) { $userPath = '' }
            if ($userPath -notmatch [regex]::Escape($full)) {
                $newUserPath = ($userPath.TrimEnd(';') + ";" + $full).Trim(';')
                [System.Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
                Write-OK "PATH (User) eklendi: $full"
            }
            else { Write-Info "PATH (User) zaten iceriyor: $full" }
        }
        catch { Write-Warn "User PATH guncelleme hatasi: $($_.Exception.Message)" }

        # If we are admin, also update Machine PATH (persistent for all users)
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { $isAdmin = $false }

        if ($isAdmin) {
            try {
                $machinePath = [System.Environment]::GetEnvironmentVariable('Path','Machine')
                if (-not $machinePath) { $machinePath = '' }
                if ($machinePath -notmatch [regex]::Escape($full)) {
                    $newMachinePath = ($machinePath.TrimEnd(';') + ";" + $full).Trim(';')
                    # Write to registry and environment
                    $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
                    if ($regKey) { $regKey.SetValue('Path', $newMachinePath, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
                    [System.Environment]::SetEnvironmentVariable('Path', $newMachinePath, 'Machine')
                    Write-OK "PATH (Machine) eklendi: $full"
                }
                else { Write-Info "PATH (Machine) zaten iceriyor: $full" }
            }
            catch { Write-Warn "Machine PATH guncelleme hatasi: $($_.Exception.Message)" }
        }
        else {
            Write-Info "Machine PATH degisikligi icin admin ihtiyaci var; sadece User PATH guncellendi." 
        }
    }
    catch {
        Write-Warn "PATH guncelleme basarisiz: $($_.Exception.Message)"
    }
}

function Register-RunAtStartup {
    param([string]$Name, [string]$Exe, [string]$Args)
    if (-not $Name -or -not $Exe) { return }
    try {
        $value = if ($Args) { "`"$Exe`" $Args" } else { "`"$Exe`"" }
        New-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $Name -Value $value -PropertyType String -Force | Out-Null
        Write-OK "Startup kaydi olusturuldu: $Name"
    }
    catch {
        Write-Warn "Startup kaydi olusturulamadi: $($_.Exception.Message)"
    }
}

function Ensure-RequiredTools {
    Write-Section "GEREKLI ARACLAR KONTROLU"

    # Ensure a private bin directory under the data folder so we can avoid permission issues
    $binDir = Join-Path $BASE_PATH 'bin'
    if (-not (Test-Path $binDir)) { New-Item -Path $binDir -ItemType Directory -Force | Out-Null }

    # Point executables into the bin folder for consistent behavior
    if ($checkIsWindows) {
        $global:CADDY_EXE = Join-Path $binDir 'caddy.exe'
        $global:CF_EXE    = Join-Path $binDir 'cloudflared.exe'
        $global:NGROK_EXE = Join-Path $binDir 'ngrok.exe'
    }
    else {
        $global:CADDY_EXE = Join-Path $binDir 'caddy'
        $global:CF_EXE    = Join-Path $binDir 'cloudflared'
        $global:NGROK_EXE = Join-Path $binDir 'ngrok'
    }

    function Download-FileWithProgress {
        param([string]$Url, [string]$Destination, [string]$Name)
        Write-Step "$Name indiriliyor: $Url"
        try {
            $total = 0
            try { $head = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop; if ($head.Headers['Content-Length']) { $total = [int64]$head.Headers['Content-Length'] } } catch {}

            if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }

            $job = Start-Job -ScriptBlock {
                param($u, $d)
                Invoke-WebRequest -Uri $u -OutFile $d -UseBasicParsing -ErrorAction Stop
            } -ArgumentList $Url, $Destination

            $start = Get-Date
            while ($job.State -eq 'Running') {
                Start-Sleep -Seconds 1
                $cur = 0
                if (Test-Path $Destination) { $cur = (Get-Item $Destination).Length }
                $percent = if ($total -gt 0) { [int]([Math]::Min(99, [Math]::Round($cur / $total * 100))) } else { [int](((Get-Date) - $start).TotalSeconds % 100) }
                $status = if ($total -gt 0) { "{0:N0}/{1:N0} bytes" -f $cur, $total } else { "indirme devam ediyor... {0}s" -f ([int]((Get-Date)-$start).TotalSeconds) }
                Write-Progress -Activity "Indiriliyor: $Name" -Status $status -PercentComplete $percent
            }
            Receive-Job -Job $job -ErrorAction Stop | Out-Null
            Remove-Job -Job $job -ErrorAction SilentlyContinue
            Write-Progress -Activity "Indiriliyor: $Name" -Completed
            if (-not (Test-Path $Destination)) { throw "Dosya indirilemedi: $Destination" }
            return $true
        }
        catch {
            if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
            Write-Warn "$Name indirilemedi: $($_.Exception.Message)"
            return $false
        }
    }

    # Ollama (fast search)
    try {
        $foundOllama = Find-ExecutableFast 'ollama' 2000
        if ($foundOllama) {
            Write-OK "Ollama mevcut: $foundOllama"
        }
        else {
            Write-Step "Ollama bulunamadi; yukleniyor..."
            Install-Ollama
        }
    } catch { Write-Warn "Ollama kontrolu hatasi: $($_.Exception.Message)" }

    # Caddy
    try {
        $foundCaddy = Find-ExecutableFast 'caddy' 2000
        if ($foundCaddy) {
            $global:CADDY_EXE = $foundCaddy
            Add-Directory-To-SystemPath -Dir (Split-Path $foundCaddy -Parent)
            Write-OK "Caddy mevcut: $foundCaddy"
        }
        else {
            $caddyUrl = "https://caddyserver.com/api/download?os=windows&arch=amd64"
            $tmp = $CADDY_EXE
            if (Download-FileWithProgress -Url $caddyUrl -Destination $tmp -Name 'Caddy') {
                try { if (-not $checkIsWindows) { & chmod +x $tmp } } catch {}
                Add-Directory-To-SystemPath -Dir $binDir
                try { Register-RunAtStartup -Name "BestAI-Caddy" -Exe $tmp -Args "run --config `"$WEB_DIR\Caddyfile`"" } catch {}
                Write-OK "Caddy indirildi ve PATH eklendi."
            }
        }
    } catch { Write-Warn "Caddy kontrolu hatasi: $($_.Exception.Message)" }

    # cloudflared
    try {
        $foundCF = Find-ExecutableFast 'cloudflared' 2000
        if ($foundCF) {
            $global:CF_EXE = $foundCF
            Add-Directory-To-SystemPath -Dir (Split-Path $foundCF -Parent)
            Write-OK "cloudflared mevcut: $foundCF"
        }
        else {
            $cfUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
            $tmp = $CF_EXE
            if (Download-FileWithProgress -Url $cfUrl -Destination $tmp -Name 'cloudflared') {
                try { if (-not $checkIsWindows) { & chmod +x $tmp } } catch {}
                Add-Directory-To-SystemPath -Dir $binDir
                try { Register-RunAtStartup -Name "BestAI-cloudflared" -Exe $tmp -Args "tunnel --url http://127.0.0.1:$CADDY_PORT" } catch {}
                Write-OK "cloudflared indirildi ve PATH eklendi."
            }
        }
    } catch { Write-Warn "cloudflared kontrolu hatasi: $($_.Exception.Message)" }

    # ngrok
    try {
        $foundNgrok = Find-ExecutableFast 'ngrok' 2000
        if ($foundNgrok) {
            $global:NGROK_EXE = $foundNgrok
            Add-Directory-To-SystemPath -Dir (Split-Path $foundNgrok -Parent)
            Write-OK "ngrok mevcut: $foundNgrok"
        }
        else {
            $ngrokZipUrl = "https://bin.equinox.io/c/4VmDzA7iaHb/ngrok-stable-windows-amd64.zip"
            $tmpZip = Join-Path $env:TEMP "ngrok.zip"
            $tmpExe = $NGROK_EXE
            if (Download-FileWithProgress -Url $ngrokZipUrl -Destination $tmpZip -Name 'ngrok') {
                try {
                    Expand-Archive -Path $tmpZip -DestinationPath $binDir -Force
                    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
                    Add-Directory-To-SystemPath -Dir $binDir
                    try { Register-RunAtStartup -Name "BestAI-ngrok" -Exe $tmpExe -Args "http $CADDY_PORT --log=stdout" } catch {}
                    Write-OK "ngrok indirildi ve PATH eklendi."
                }
                catch { Write-Warn "ngrok zip acilamadi: $($_.Exception.Message)" }
            }
        }
    } catch { Write-Warn "ngrok kontrolu hatasi: $($_.Exception.Message)" }

    # Final PATH sync for common dirs
    try {
        $commonDirs = @($binDir, (Join-Path $env:LOCALAPPDATA 'Programs\Ollama'))
        foreach ($d in $commonDirs) { if ($d -and (Test-Path $d)) { Add-Directory-To-SystemPath -Dir $d } }
    } catch {}
}

function Write-Warn {
    param([string]$msg)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "  [$ts] " -NoNewline -ForegroundColor Yellow
    Write-Host "[!!] " -NoNewline -ForegroundColor Yellow
    Write-Host $msg -ForegroundColor Gray
    Write-Log -Level "WARN" -Message $msg
}

function Write-Fail {
    param([string]$msg)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "  [$ts] " -NoNewline -ForegroundColor Red
    Write-Host "[XX] " -NoNewline -ForegroundColor Red
    Write-Host $msg -ForegroundColor Gray
    Write-Log -Level "FAIL" -Message $msg
}

function Write-Info {
    param([string]$msg)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "  [$ts] " -NoNewline -ForegroundColor DarkCyan
    Write-Host "[--] " -NoNewline -ForegroundColor DarkCyan
    Write-Host $msg -ForegroundColor Gray
    Write-Log -Level "INFO" -Message $msg
}

function Show-Progress {
    param([string]$Activity, [int]$Percent)
    $barLen = 40
    $filled = [Math]::Round($barLen * $Percent / 100)
    $empty = $barLen - $filled
    $bar = "[" + ("=" * $filled) + (" " * $empty) + "]"
    Write-Host "`r  $bar $Percent% - $Activity" -NoNewline -ForegroundColor Cyan
    if ($Percent -ge 100) { Write-Host "" }
}

# ============================================================
#  YONETICI KONTROL
# ============================================================
function Assert-AdminPrivileges {
    if ($checkIsWindows) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Write-Host "  Yonetici izni gerekiyor. Yeniden baslatiliyor..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            try {
                Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`"" -Verb RunAs
                exit
            }
            catch {
                Write-Host "  Yonetici olarak baslatilamadi!" -ForegroundColor Red
                Pause-Screen
            }
        }
        Write-OK "Yonetici ayricaliklari dogrulandi."
    }
    elseif ($checkIsLinux) {
        $uid = & id -u
        if ($uid -ne "0") {
            Write-Host ""
            Write-Host "  Linux'ta sudo gerekli. Calistirin: sudo pwsh setup-ai-server.ps1" -ForegroundColor Yellow
            Pause-Screen
        }
        Write-OK "Root ayricaliklari dogrulandi."
    }
}

# ============================================================
#  SISTEM KAYNAK KONTROLU
# ============================================================
function Get-SystemInfo {
    Write-Section "SISTEM KAYNAK ANALIZI"

    # RAM
    if ($checkIsWindows) {
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $global:systemInfo.RAM = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
            $global:systemInfo.FreeRAM = [Math]::Round($os.FreePhysicalMemory / 1MB, 2)
        }
        # Disk (C: veya ilk drive)
        $disk = Get-PSDrive -Name C -ErrorAction SilentlyContinue
        if ($disk) {
            $global:systemInfo.FreeDisk = [Math]::Round($disk.Free / 1GB, 2)
        }
        # CPU
        $cpu = Get-WmiObject -Class Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cpu) {
            $global:systemInfo.CPUCores = $cpu.NumberOfCores
            $global:systemInfo.CPUName = $cpu.Name.Trim()
            $global:systemInfo.CPUSpeed = "$($cpu.MaxClockSpeed) MHz"
        }
    }
    elseif ($checkIsLinux) {
        try {
            $memTotal = (Get-Content /proc/meminfo | Where-Object { $_ -match "MemTotal" }) -replace "[^0-9]", ""
            $memFree = (Get-Content /proc/meminfo | Where-Object { $_ -match "MemAvailable" }) -replace "[^0-9]", ""
            $global:systemInfo.RAM = [Math]::Round([long]$memTotal / 1MB, 2)
            $global:systemInfo.FreeRAM = [Math]::Round([long]$memFree / 1MB, 2)
            $dfOut = & df -BG / 2>/dev/null | Select-Object -Last 1
            if ($dfOut -match "\s(\d+)G\s+(\d+)G\s+(\d+)G") {
                $global:systemInfo.FreeDisk = [int]$matches[3]
            }
            $cpuInfo = Get-Content /proc/cpuinfo | Where-Object { $_ -match "model name" } | Select-Object -First 1
            $coreCount = (Get-Content /proc/cpuinfo | Where-Object { $_ -match "^processor" }).Count
            $global:systemInfo.CPUCores = $coreCount
            $global:systemInfo.CPUName = ($cpuInfo -replace ".*:\s*", "").Trim()
        }
        catch {
            Write-Warn "Linux sistem bilgisi alinamadi."
        }
    }

    $ramGB = $global:systemInfo.RAM
    $freeRAM = $global:systemInfo.FreeRAM
    $freeDisk = $global:systemInfo.FreeDisk
    $cores = $global:systemInfo.CPUCores
    $cpuName = if ($global:systemInfo.CPUName) { $global:systemInfo.CPUName } else { "Bilinmiyor" }

    Write-Info "CPU     : $cpuName ($cores cekirdek)"
    Write-Info "RAM     : $ramGB GB toplam / $freeRAM GB bos"
    Write-Info "Disk    : $freeDisk GB bos alan"

    if ($freeDisk -lt 10) {
        Write-Warn "Disk alani az! En az 10 GB bos alan onerilir."
    }
    else {
        Write-OK "Disk alani yeterli ($freeDisk GB)."
    }
}

# ============================================================
#  GPU ALGILAMA
# ============================================================
function Detect-GPU {
    Write-Section "GPU ALGILAMA"

    try {
        if ($checkIsWindows) {
            # Try nvidia-smi first (robust arg format)
            $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
            if ($nvidiaSmi) {
                try {
                    $nvidiaOut = & $nvidiaSmi.Source "--query-gpu=name,memory.total" "--format=csv,noheader,nounits" 2>$null
                    $line = $nvidiaOut -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1
                    if ($line) {
                        if ($line -match '^(.*),\s*([0-9]+)') {
                            $name = $matches[1].Trim()
                            $memMB = [int]$matches[2].Trim()
                        }
                        else {
                            $parts = $line -split ','
                            $memMB = [int]$parts[-1].Trim()
                            $name = ($parts[0..($parts.Count-2)] -join ',').Trim()
                        }
                        $global:gpuInfo.Available = $true
                        $global:gpuInfo.Type = "NVIDIA"
                        $global:gpuInfo.Name = $name
                        $global:gpuInfo.VRAM = [Math]::Round($memMB / 1024, 1)
                        Write-OK "NVIDIA GPU: $($global:gpuInfo.Name) | VRAM: $($global:gpuInfo.VRAM) GB"
                        Write-OK "CUDA hizlandirmasi AKTIF olacak!"
                        return
                    }
                } catch {}
            }

            # Fallback: use WMI to inspect video controllers
            $controllers = Get-WmiObject -Class Win32_VideoController -ErrorAction SilentlyContinue
            if ($controllers) {
                foreach ($c in $controllers) {
                    $caption = $c.Caption
                    $memBytes = $null
                    try { $memBytes = [int]$c.AdapterRAM } catch {}

                    if ($caption -match 'NVIDIA|GeForce|Quadro') {
                        $global:gpuInfo.Available = $true
                        $global:gpuInfo.Type = 'NVIDIA'
                        $global:gpuInfo.Name = $caption
                        if ($memBytes) { $global:gpuInfo.VRAM = [Math]::Round($memBytes / 1GB, 1) }
                        Write-OK "NVIDIA GPU (WMI): $caption"
                        return
                    }
                    if ($caption -match 'AMD|Radeon|Advanced Micro Devices') {
                        $global:gpuInfo.Available = $true
                        $global:gpuInfo.Type = 'AMD'
                        $global:gpuInfo.Name = $caption
                        if ($memBytes) { $global:gpuInfo.VRAM = [Math]::Round($memBytes / 1GB, 1) }
                        Write-OK "AMD GPU algilandi: $caption"
                        Write-Warn "AMD ROCm destegi sinirli olabilir, CPU fallback kullanilabilir."
                        return
                    }
                    if ($caption -match 'Intel') {
                        $global:gpuInfo.Available = $false
                        $global:gpuInfo.Type = 'Intel'
                        $global:gpuInfo.Name = $caption
                        Write-Warn "Intel GPU: $caption - CPU modu kullanilacak."
                        return
                    }
                }
            }
        }
        elseif ($checkIsLinux) {
            $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
            if ($nvidiaSmi) {
                try {
                    $nvidiaOut = & $nvidiaSmi.Source "--query-gpu=name,memory.total" "--format=csv,noheader,nounits" 2>/dev/null
                    $line = $nvidiaOut -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1
                    if ($line -match '^(.*),\s*([0-9]+)') {
                        $name = $matches[1].Trim()
                        $memMB = [int]$matches[2].Trim()
                        $global:gpuInfo.Available = $true
                        $global:gpuInfo.Type = 'NVIDIA'
                        $global:gpuInfo.Name = $name
                        $global:gpuInfo.VRAM = [Math]::Round($memMB / 1024, 1)
                        Write-OK "NVIDIA GPU: $($global:gpuInfo.Name) | VRAM: $($global:gpuInfo.VRAM) GB"
                        return
                    }
                } catch {}
            }
            if (Test-Path "/dev/kfd") {
                $global:gpuInfo.Available = $true
                $global:gpuInfo.Type = "AMD-ROCm"
                Write-OK "AMD ROCm cihazi algilandi (/dev/kfd)."
                return
            }
        }
    }
    catch {
        Write-Warn "GPU algilama sirasinda hata: $($_.Exception.Message)"
    }

    $global:gpuInfo.Available = $false
    $global:gpuInfo.Type = 'CPU'
    Write-Warn "Dedicated GPU bulunamadi. CPU modunda calisacak (yavas olabilir)."
}

# ============================================================
#  MODELLER LISTESI
# ============================================================
$MODELS = @(
    @{ Name = "qwen2.5:7b"; Label = "Qwen 2.5 7B"; Vendor = "Alibaba"; RAM = 6; Tags = "cok-dilli,genel" }
    @{ Name = "qwen2.5:3b"; Label = "Qwen 2.5 3B"; Vendor = "Alibaba"; RAM = 3; Tags = "cok-dilli,hizli" }
    @{ Name = "qwen2.5-coder:7b"; Label = "Qwen 2.5 Coder 7B"; Vendor = "Alibaba"; RAM = 6; Tags = "kod,teknik" }
    @{ Name = "llama3.2:3b"; Label = "Llama 3.2 3B"; Vendor = "Meta"; RAM = 3; Tags = "hizli,genel" }
    @{ Name = "llama3.2:1b"; Label = "Llama 3.2 1B"; Vendor = "Meta"; RAM = 1; Tags = "ultra-hizli,hafif" }
    @{ Name = "llama3.1:8b"; Label = "Llama 3.1 8B"; Vendor = "Meta"; RAM = 7; Tags = "guclu,genel" }
    @{ Name = "mistral:7b"; Label = "Mistral 7B"; Vendor = "Mistral"; RAM = 6; Tags = "guclu,fransiz" }
    @{ Name = "mistral-nemo:12b"; Label = "Mistral Nemo 12B"; Vendor = "Mistral"; RAM = 10; Tags = "guclu,buyuk" }
    @{ Name = "gemma2:2b"; Label = "Gemma 2 2B"; Vendor = "Google"; RAM = 2; Tags = "hafif,hizli" }
    @{ Name = "gemma2:9b"; Label = "Gemma 2 9B"; Vendor = "Google"; RAM = 8; Tags = "guclu,google" }
    @{ Name = "phi3:mini"; Label = "Phi-3 Mini"; Vendor = "Microsoft"; RAM = 2; Tags = "verimli,hizli" }
    @{ Name = "phi3:medium"; Label = "Phi-3 Medium"; Vendor = "Microsoft"; RAM = 6; Tags = "dengeli,microsoft" }
    @{ Name = "phi4:14b"; Label = "Phi-4 14B"; Vendor = "Microsoft"; RAM = 12; Tags = "en-yeni,guclu" }
    @{ Name = "deepseek-r1:7b"; Label = "DeepSeek R1 7B"; Vendor = "DeepSeek"; RAM = 6; Tags = "reasoning,akil" }
    @{ Name = "deepseek-r1:1.5b"; Label = "DeepSeek R1 1.5B"; Vendor = "DeepSeek"; RAM = 2; Tags = "reasoning,hafif" }
    @{ Name = "codellama:7b"; Label = "Code Llama 7B"; Vendor = "Meta"; RAM = 6; Tags = "kod,python" }
    @{ Name = "nomic-embed-text"; Label = "Nomic Embed Text"; Vendor = "Nomic"; RAM = 1; Tags = "embedding,vektor" }
    @{ Name = "mxbai-embed-large"; Label = "MxBAI Embed Large"; Vendor = "MixedBread"; RAM = 1; Tags = "embedding,buyuk" }
)

# ============================================================
#  OLLAMA KURULUM / KONTROL
# ============================================================
function Install-Ollama {
    Write-Section "OLLAMA KURULUM KONTROLU"

    $ollamaPath = Get-Command ollama -ErrorAction SilentlyContinue

    if (-not $ollamaPath) {
        Write-Warn "Ollama bulunamadi. Yukleniyor..."

        if ($checkIsWindows) {
            $winget = Get-Command winget -ErrorAction SilentlyContinue
            if ($winget) {
                Write-Step "winget ile yukleniyor..."
                try {
                    & winget install Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements
                    Write-OK "Ollama winget ile yuklendi."
                }
                catch {
                    Write-Warn "winget basarisiz. Direkt indirme deneniyor..."
                    Install-OllamaDirectDownload
                }
            }
            else {
                Install-OllamaDirectDownload
            }
            # PATH guncelle (kullanici + machine)
            $newPath = "$env:LOCALAPPDATA\Programs\Ollama"
            if (-not $env:Path.Contains($newPath)) {
                $env:Path += ";" + $newPath
                [System.Environment]::SetEnvironmentVariable("Path", $env:Path, "User")
            }
            Add-Directory-To-SystemPath -Dir $newPath
            Write-OK "PATH guncellendi: $newPath"
        }
        elseif ($checkIsLinux) {
            Write-Step "Linux: curl ile Ollama kuruluyor..."
            try {
                $curlCmd = "curl -fsSL https://ollama.com/install.sh | sh"
                Invoke-Expression $curlCmd
                Write-OK "Ollama Linux'a yuklendi."
            }
            catch {
                Write-Fail "Ollama Linux kurulumu basarisiz!"
                throw
            }
        }
    }
    else {
        Write-OK "Ollama zaten kurulu: $($ollamaPath.Source)"
    }

    # Versiyon kontrol
    try {
        $ver = & ollama --version 2>$null
        Write-OK "Ollama versiyonu: $ver"
        Write-Log -Level "INFO" -Message "Ollama version: $ver"
    }
    catch {
        Write-Warn "Versiyon alinamadi."
    }
}

function Install-OllamaDirectDownload {
    Write-Step "Dogrudan indirme: https://ollama.com/download/OllamaSetup.exe"
    $installer = "$env:TEMP\OllamaSetup.exe"
    try {
        Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $installer -UseBasicParsing
        Write-Step "Kurulum basliyor (sessiz mod)..."
        Start-Process -FilePath $installer -ArgumentList "/S" -Wait
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        Write-OK "Ollama kurulumu tamamlandi."
    }
    catch {
        Write-Fail "Ollama indirilemedi: $($_.Exception.Message)"
        throw
    }
}

# ============================================================
#  OLLAMA GUNCELLEME KONTROLU
# ============================================================
function Check-OllamaUpdate {
    Write-Step "Ollama guncelleme kontrol ediliyor..."
    try {
        $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/ollama/ollama/releases/latest" -TimeoutSec 10
        $latestVer = $releaseInfo.tag_name -replace "^v", ""
        $localVer = (& ollama --version 2>$null) -replace "[^0-9.]", ""
        if ($latestVer -and $localVer) {
            if ($latestVer -ne $localVer) {
                Write-Warn "Yeni Ollama surumu mevcut: v$latestVer (Kurulu: v$localVer)"
                Write-Host "  Guncellemek ister misiniz? (E/H): " -NoNewline -ForegroundColor Yellow
                $upd = Read-Host
                if ($upd -match "^[Ee]") {
                    Write-Step "Guncelleniyor..."
                    if ($checkIsWindows) {
                        Install-OllamaDirectDownload
                    }
                    else {
                        Invoke-Expression "curl -fsSL https://ollama.com/install.sh | sh"
                    }
                    Write-OK "Guncelleme tamamlandi."
                }
            }
            else {
                Write-OK "Ollama guncel: v$localVer"
            }
        }
    }
    catch {
        Write-Warn "Guncelleme kontrolu yapilamadi (internet erisimine bakin)."
    }
}

function Check-ScriptUpdate {
    Write-Section "SCRIPT GUNCELLEME KONTROLU (BEST-AI)"
    $owner = "toprakahmetaydogmus"
    $repo  = "BEST-AI"
    $headers = @{ 'User-Agent' = 'BestAI-UpdateCheck' }
    $latest = $null
    $htmlUrl = "https://github.com/$owner/$repo"
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/releases/latest" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
        $latest = $rel.tag_name -replace '^v',''
        if ($rel.html_url) { $htmlUrl = $rel.html_url }
    } catch {
        try {
            $comm = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/commits?per_page=1" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            if ($comm -and $comm[0]) {
                $latest = $comm[0].sha.Substring(0,7)
                $htmlUrl = "https://github.com/$owner/$repo/commit/$latest"
            }
        } catch {
            Write-Warn "Guncelleme bilgisi alinamadi."
            return
        }
    }

    if (-not $latest) {
        Write-Warn "Guncel surum bilgisi alinamadi."
        return
    }

    if ($latest -ne $SCRIPT_VERSION) {
        Write-Warn "Yeni script surumu mevcut: $latest (Kurulu: $SCRIPT_VERSION)"
        Write-Host "  Guncelleme sayfasi: $htmlUrl" -ForegroundColor Cyan
        Write-Host "  Guncellemek ister misiniz? (E/H): " -NoNewline -ForegroundColor Yellow
        $yn = Read-Host
        if ($yn -match '^[Ee]') {
            $rawUrl = "https://raw.githubusercontent.com/$owner/$repo/main/bestaı.ps1"
            $tmp = Join-Path $env:TEMP "BESTAI_bestaı.ps1"
            try {
                Invoke-WebRequest -Uri $rawUrl -OutFile $tmp -UseBasicParsing -Headers $headers -TimeoutSec 30
                $dest = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $PSCommandPath }
                if ($dest) {
                    Copy-Item -Path $tmp -Destination $dest -Force
                    Write-OK "Script guncellendi. Lütfen scripti yeniden baslatin."
                } else {
                    Write-Fail "Script yolu tespit edilemedi. Elle indirin: $rawUrl"
                }
            } catch {
                Write-Fail "Guncelleme indirilemedi: $($_.Exception.Message)"
            }
        }
    } else {
        Write-OK "Script zaten guncel: v$SCRIPT_VERSION"
    }
}

# ============================================================
#  AG YAPILANDIRMASI
# ============================================================
function Configure-Network {
    Write-Section "AG VE ERISIM YAPILANDIRMASI"

    $localIps = Get-LocalIPs
    
    Write-Host "  Lutfen erisim modunu secin:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] Yerel Mod           - Sadece bu bilgisayar (127.0.0.1)" -ForegroundColor White
    Write-Host "  [2] Tum Agda Calistir   - LAN uzerindeki tum cihazlar (0.0.0.0)" -ForegroundColor Green
    
    $i = 3
    foreach ($ip in $localIps) {
        Write-Host "  [$i] Ozel IP Sec: $ip" -ForegroundColor Yellow
        $i++
    }

    $tIndex = $i
    Write-Host "  [$tIndex] Ag + Tunel (CF)    - Internet uzerinden erisim" -ForegroundColor Magenta
    $nIndex = $i + 1
    Write-Host "  [$nIndex] Ag + ngrok Tunel   - Internet uzerinden erisim" -ForegroundColor Cyan
    Write-Host ""

    $choice = ""
    $validChoices = New-Object System.Collections.Generic.List[string]
    @("1", "2", "$tIndex", "$nIndex") | ForEach-Object { $validChoices.Add($_) }
    for ($j = 3; $j -lt $tIndex; $j++) { $validChoices.Add("$j") }

    while ($choice -notin $validChoices) {
        Write-Host "  Seciminiz: " -NoNewline -ForegroundColor White
        $choice = Read-Host
    }

    switch ($choice) {
        "1" {
            $global:isRemote = $false
            $global:bindIp = "127.0.0.1"
            $global:tunnelMode = "none"
            Write-OK "Yerel mod secildi (127.0.0.1)."
        }
        "2" {
            $global:isRemote = $true
            $global:bindIp = "0.0.0.0"
            $global:tunnelMode = "none"
            Write-OK "Tum ag modunda (0.0.0.0) calisacak."
        }
        "$tIndex" {
            $global:isRemote = $true
            $global:bindIp = "0.0.0.0"
            $global:tunnelMode = "cloudflare"
            Write-OK "Cloudflare Tunnel modu secildi."
        }
        "$nIndex" {
            $global:isRemote = $true
            $global:bindIp = "0.0.0.0"
            $global:tunnelMode = "ngrok"
            Write-OK "ngrok Tunnel modu secildi."
        }
        default {
            $idx = [int]$choice - 3
            $selectedIp = $localIps[$idx]
            $global:isRemote = $true
            $global:bindIp = $selectedIp
            $global:tunnelMode = "none"
            Write-OK "Ozel IP secildi: $selectedIp"
        }
    }

    Write-Host ""
    Write-Host "  API Anahtar korumasi eklensin mi? (Onerilen: E)" -ForegroundColor Yellow
    Write-Host "  (E/H): " -NoNewline -ForegroundColor White
    $apiChoice = Read-Host
    if ($apiChoice -match "^[Ee]") {
        $global:useApiKey = $true
        if (-not $global:generatedApiKey) {
            $global:generatedApiKey = [System.Guid]::NewGuid().ToString("N").Substring(0, 32)
        }
        $global:generatedApiKey | Out-File -FilePath $API_KEY_FILE -Encoding ASCII
        Write-OK "API anahtari aktif."
    }
    else {
        $global:useApiKey = $false
        Write-Warn "API anahtari KAPALI. Dikkatli olun!"
    }
}

# ============================================================
#  ORTAM DEGISKENLERI AYARLA
# ============================================================
function Set-OllamaEnvironment {
    Write-Section "ORTAM DEGISKENLERI AYARLANIYOR"

    $bindIp = $global:bindIp

    if ($checkIsWindows) {
        Set-EnvSafe -Name "OLLAMA_HOST" -Value "$bindIp`:$OLLAMA_PORT"
        Set-EnvSafe -Name "OLLAMA_ORIGINS" -Value "*"
        Set-EnvSafe -Name "OLLAMA_KEEP_ALIVE" -Value "10m"
        Set-EnvSafe -Name "OLLAMA_NUM_PARALLEL" -Value "2"
        # GPU Acceleration
        if ($global:gpuInfo.Available -and $global:gpuInfo.Type -ne 'CPU') {
            Set-EnvSafe -Name "OLLAMA_USE_GPU" -Value "1"
            Set-EnvSafe -Name "OLLAMA_GPU_TYPE" -Value $global:gpuInfo.Type
            if ($global:gpuInfo.Type -eq "NVIDIA") {
                Set-EnvSafe -Name "CUDA_VISIBLE_DEVICES" -Value "0"
                Write-OK "CUDA GPU hizlandirmasi etkinlestirildi."
            }
            elseif ($global:gpuInfo.Type -eq "AMD") {
                Set-EnvSafe -Name "OLLAMA_USE_ROCM" -Value "1"
                Write-OK "AMD ROCm destekli GPU algilandi."
            }
        }
        else {
            Set-EnvSafe -Name "OLLAMA_USE_GPU" -Value "0"
            Write-Info "GPU bulunamadi veya desteklenmiyor; CPU modunda calisacak."
        }
    }
    elseif ($checkIsLinux) {
        Write-Step "Linux systemd override yapilandiriliyor..."
        $overrideDir = "/etc/systemd/system/ollama.service.d"
        $overrideFile = "$overrideDir/override.conf"

        Invoke-Expression "mkdir -p $overrideDir"

        $envLines = @(
            "[Service]",
            "Environment=`"OLLAMA_HOST=$bindIp`:$OLLAMA_PORT`"",
            "Environment=`"OLLAMA_ORIGINS=*`"",
            "Environment=`"OLLAMA_KEEP_ALIVE=10m`"",
            "Environment=`"OLLAMA_NUM_PARALLEL=2`""
        )
        if ($global:gpuInfo.Type -eq "NVIDIA") {
            $envLines += "Environment=`"CUDA_VISIBLE_DEVICES=0`""
        }

        $envLines | Out-File -FilePath $overrideFile -Encoding ASCII
        Invoke-Expression "systemctl daemon-reload"
        Write-OK "systemd override yazildi: $overrideFile"
    }

    $env:OLLAMA_HOST = "$bindIp`:$OLLAMA_PORT"
    $env:OLLAMA_ORIGINS = "*"
    $env:OLLAMA_KEEP_ALIVE = "10m"

    Write-OK "OLLAMA_HOST    = $bindIp`:$OLLAMA_PORT"
    Write-OK "OLLAMA_ORIGINS = *"
    Write-OK "OLLAMA_KEEP_ALIVE = 10m"
}

# ============================================================
#  GUVENLIK DUVARI KURALLARI
# ============================================================
function Configure-Firewall {
    if (-not $global:isRemote) {
        Write-OK "Yerel mod: Guvenlik duvari kurali gerekli degil."
        return
    }

    Write-Section "GUVENLIK DUVARI YAPILANDIRMASI"

    if ($checkIsWindows) {
        # Ollama port
        $rule1 = Get-NetFirewallRule -DisplayName "Ollama AI Server" -ErrorAction SilentlyContinue
        if (-not $rule1) {
            New-NetFirewallRule -DisplayName "Ollama AI Server" `
                -Direction Inbound -Protocol TCP -LocalPort $OLLAMA_PORT `
                -Action Allow -Profile Any | Out-Null
            Write-OK "Windows Firewall: Port $OLLAMA_PORT acildi (Ollama API)"
        }
        else {
            Write-OK "Windows Firewall: Port $OLLAMA_PORT zaten acik"
        }

        # Caddy web UI port
        $rule2 = Get-NetFirewallRule -DisplayName "Siber Akademi Web UI" -ErrorAction SilentlyContinue
        if (-not $rule2) {
            New-NetFirewallRule -DisplayName "Siber Akademi Web UI" `
                -Direction Inbound -Protocol TCP -LocalPort $CADDY_PORT `
                -Action Allow -Profile Any | Out-Null
            Write-OK "Windows Firewall: Port $CADDY_PORT acildi (Web UI)"
        }
        else {
            Write-OK "Windows Firewall: Port $CADDY_PORT zaten acik"
        }

    }
    elseif ($checkIsLinux) {
        $ufw = Get-Command ufw -ErrorAction SilentlyContinue
        if ($ufw) {
            Invoke-Expression "ufw allow $OLLAMA_PORT/tcp" | Out-Null
            Invoke-Expression "ufw allow $CADDY_PORT/tcp"  | Out-Null
            Write-OK "UFW: Port $OLLAMA_PORT ve $CADDY_PORT acildi."
        }
        else {
            $iptables = Get-Command iptables -ErrorAction SilentlyContinue
            if ($iptables) {
                Invoke-Expression "iptables -A INPUT -p tcp --dport $OLLAMA_PORT -j ACCEPT"
                Invoke-Expression "iptables -A INPUT -p tcp --dport $CADDY_PORT -j ACCEPT"
                Write-OK "iptables: Port $OLLAMA_PORT ve $CADDY_PORT acildi."
            }
            else {
                Write-Warn "Guvenlik duvari aracı bulunamadi. Portlari manuel aciniz."
            }
        }
    }
}

# ============================================================
#  OLLAMA SERVİSİ BASLAT
# ============================================================
function Start-OllamaService {
    Write-Section "OLLAMA SERVIS YONETIMI"

    if ($checkIsWindows) {
        $proc = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Step "Mevcut Ollama surecleri (arka plan, tepsi uygulamasi vb.) durduruluyor..."
            $proc | Where-Object { $_.ProcessName -match "ollama" } | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        
        Write-Step "Ollama servisi baslatiliyor (Host: $($global:bindIp))..."
        try {
            $sInfo = New-Object System.Diagnostics.ProcessStartInfo
            $sInfo.FileName = "ollama"
            $sInfo.Arguments = "serve"
            $sInfo.CreateNoWindow = $true
            $sInfo.UseShellExecute = $false
            $sInfo.WindowStyle = "Hidden"
            
            # Ortam degiskenlerini enjekte et
            $sInfo.EnvironmentVariables["OLLAMA_HOST"] = "$($global:bindIp):$OLLAMA_PORT"
            $sInfo.EnvironmentVariables["OLLAMA_ORIGINS"] = "*"
            # GPU hints for Ollama
            try {
                $sInfo.EnvironmentVariables["OLLAMA_USE_GPU"] = if ($global:gpuInfo.Available -and $global:gpuInfo.Type -ne 'CPU') { '1' } else { '0' }
                $sInfo.EnvironmentVariables["OLLAMA_GPU_TYPE"] = $global:gpuInfo.Type
                if ($global:gpuInfo.Type -eq 'NVIDIA') { $sInfo.EnvironmentVariables['CUDA_VISIBLE_DEVICES'] = '0' }
            } catch {}
            
            [System.Diagnostics.Process]::Start($sInfo) | Out-Null
            Start-Sleep -Seconds 4
            Write-OK "Ollama yeni ayarlarla baslatildi."
            $global:ollamaRunning = $true
        }
        catch {
            Write-Fail "Ollama baslatma hatasi: $($_.Exception.Message)"
            $global:ollamaRunning = $false
        }
    }
    elseif ($checkIsLinux) {
        $svcStatus = & systemctl is-active ollama 2>$null
        if ($svcStatus -eq "active") {
            Invoke-Expression "systemctl restart ollama"
            Write-OK "Ollama servisi yeniden baslatildi (systemd)."
        }
        else {
            Invoke-Expression "systemctl start ollama"
            Write-OK "Ollama servisi baslatildi (systemd)."
        }
        $global:ollamaRunning = $true
    }

    # Use 127.0.0.1 for internal check to ensure we hit Ollama regardless of binding
    $checkUrl = "http://127.0.0.1:$OLLAMA_PORT/api/tags"
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $checkUrl -UseBasicParsing -TimeoutSec 2
            if ($resp.StatusCode -eq 200) {
                $ready = $true
                break
            }
        }
        catch {}
        Write-Host "." -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host ""

    if ($ready) {
        Write-OK "Ollama API hazir! ($checkUrl)"
    }
    else {
        Write-Warn "Ollama API 20 saniye icinde yanit vermedi. Devam ediliyor..."
    }
}

# ============================================================
#  KURULU MODEL LISTESI
# ============================================================
function Get-InstalledModels {
    try {
        $checkUrl = "http://127.0.0.1:$OLLAMA_PORT/api/tags"
        $resp = $null
        try { $resp = Invoke-RestMethod -Uri $checkUrl -TimeoutSec 3 -ErrorAction Stop } catch { $resp = $null }

        $names = @()
        if ($resp) {
            # Common shape: { models: [ { name: 'model' }, ... ] }
            if ($resp.PSObject.Properties.Name -contains 'models' -and $resp.models) {
                foreach ($m in $resp.models) {
                    if ($m -is [string]) { $names += $m }
                    elseif ($m.PSObject.Properties.Name -contains 'name') { $names += $m.name }
                    elseif ($m.PSObject.Properties.Name -contains 'model') { $names += $m.model }
                }
            }
            else {
                # If the response is an array or has 'tags'
                if ($resp -is [System.Collections.IEnumerable]) {
                    foreach ($item in $resp) {
                        if ($item -is [string]) { $names += $item }
                        elseif ($item.PSObject.Properties.Name -contains 'name') { $names += $item.name }
                        elseif ($item.PSObject.Properties.Name -contains 'model') { $names += $item.model }
                    }
                }
                elseif ($resp.PSObject.Properties.Name -contains 'tags' -and $resp.tags) {
                    foreach ($t in $resp.tags) {
                        if ($t -is [string]) { $names += $t }
                        elseif ($t.PSObject.Properties.Name -contains 'name') { $names += $t.name }
                    }
                }
            }
        }

        # Fallback: try ollama CLI if API gave nothing
        if ($names.Count -eq 0) {
            if (Get-Command -Name 'ollama' -ErrorAction SilentlyContinue) {
                try {
                    $out = & ollama list 2>&1
                    foreach ($line in $out) {
                        # Typical CLI listing usually starts with the model id
                        if ($line -match '^\s*([^\s]+)') { $names += $matches[1] }
                    }
                } catch {}
            }
        }

        # If still empty, attempt to start Ollama service in background (useful when service isn't running)
        if ($names.Count -eq 0) {
            $ollamaCmd = Get-Command -Name 'ollama' -ErrorAction SilentlyContinue
            $proc = Get-Process -Name 'ollama' -ErrorAction SilentlyContinue
            if ($ollamaCmd -and -not $proc) {
                Write-Step "Ollama algilamadi; arka planda baslatiliyor..."
                try {
                    Start-OllamaService
                    # Give Ollama some time to initialize and expose API
                    for ($i = 0; $i -lt 12; $i++) {
                        try {
                            $resp2 = Invoke-RestMethod -Uri $checkUrl -TimeoutSec 2 -ErrorAction Stop
                            if ($resp2) {
                                # populate names from API response
                                if ($resp2.PSObject.Properties.Name -contains 'models' -and $resp2.models) {
                                    foreach ($m in $resp2.models) {
                                        if ($m -is [string]) { $names += $m }
                                        elseif ($m.PSObject.Properties.Name -contains 'name') { $names += $m.name }
                                        elseif ($m.PSObject.Properties.Name -contains 'model') { $names += $m.model }
                                    }
                                }
                                break
                            }
                        } catch {}
                        Start-Sleep -Seconds 1
                    }
                } catch {
                    Write-Warn "Ollama arka planda baslatilamadi: $($_.Exception.Message)"
                }
            }
        }

        $global:installedModels = ($names | Where-Object { $_ } | Select-Object -Unique)
        return $global:installedModels
    }
    catch {
        return @()
    }
}

# ============================================================
#  MODEL SECIMI VE INDIRME
# ============================================================
function Select-And-Download-Models {
    Write-Section "MODEL SECIMI VE INDIRME"

    $freeRAM = $global:systemInfo.FreeRAM
    $vram = $global:gpuInfo.VRAM
    $totalAvailableMem = $freeRAM + ($vram * 0.8) # VRAM'in %80'ini guvenli limit olarak ekle

    Write-Host "  Sisteminizde $freeRAM GB bos RAM ve $vram GB VRAM var." -ForegroundColor Gray
    Write-Host "  Onerilen modeller [*] isaretlidir." -ForegroundColor Gray
    Write-Host ""
    Write-Host ("  {0,-3}  {1,-22} {2,-12} {3,-10} {4,-6}  {5}" -f "#", "Model", "Saglayici", "Gerekli", "Tags", "") -ForegroundColor DarkCyan
    Write-Host ("  " + "-" * 70) -ForegroundColor Gray

    for ($i = 0; $i -lt $MODELS.Count; $i++) {
        $m = $MODELS[$i]
        $marker = if ($m.RAM -le $totalAvailableMem) { "*" } else { " " }
        $numStr = "[$($i+1)]"
        $color = if ($m.RAM -le $totalAvailableMem) { "White" } else { "DarkGray" }
        Write-Host ("  $marker {0,-3}  {1,-22} {2,-12} {3,-6} GB   {4}" -f $numStr, $m.Label, $m.Vendor, $m.RAM, $m.Tags) -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "  [ENTER] Otomatik olarak guclu modelleri sec / Devam et" -ForegroundColor Green
    Write-Host "  [A]  Tumunu indir" -ForegroundColor DarkCyan
    Write-Host "  [R]  Sadece donanima uyan tum modelleri indir" -ForegroundColor Yellow
    Write-Host "  [F]  Sadece hizli/hafif set (llama3.2 + phi3 + gemma2)" -ForegroundColor Cyan
    Write-Host "  [0]  Model atla" -ForegroundColor Red
    Write-Host ""

    $isValid = $false
    $toDownload = @()

    while (-not $isValid) {
        Write-Host "  Seciminiz [BOS=Otomatik]: " -NoNewline -ForegroundColor White
        $choice = Read-Host

        $isValid = $true
        if ([string]::IsNullOrWhiteSpace($choice)) {
            Write-OK "Otomatik mod devrede. Sisteme uyan optimal modeller seciliyor..."
            # Auto defaults: Bir genel guc, bir hizli, bir kod, bir reasoning eyer yetiyorsa
            $toDownload = $MODELS | Where-Object { $_.RAM -le $totalAvailableMem -and $_.Name -match "llama3|qwen2.5|deepseek" }
            if ($toDownload.Count -gt 3) { $toDownload = $toDownload[0..2] }
        }
        else {
            switch ($choice.Trim().ToUpper()) {
                "A" { $toDownload = $MODELS }
                "R" { $toDownload = $MODELS | Where-Object { $_.RAM -le $totalAvailableMem -and $_.Tags -notmatch "embedding" } }
                "F" { $toDownload = $MODELS | Where-Object { $_.Name -in @("llama3.2:3b", "phi3:mini", "gemma2:2b") } }
                "0" { $toDownload = @(); Write-OK "Model secimi atlandi." }
                default {
                    $indices = $choice -split "," | ForEach-Object {
                        $v = 0
                        if ([int]::TryParse($_.Trim(), [ref]$v)) { $v - 1 } else { -99 }
                    }
                    $hasValid = $false
                    $toDownload = $indices | ForEach-Object {
                        if ($_ -ge 0 -and $_ -lt $MODELS.Count) {
                            $hasValid = $true
                            $MODELS[$_]
                        }
                    }
                    if (-not $hasValid) {
                        Write-Warn "Gecersiz secim. Tekrar deneyin."
                        $isValid = $false
                    }
                }
            }
        }
    }

    $global:selectedModels = $toDownload

    Write-Host ""
    foreach ($model in $toDownload) {
        Write-Step "Indiriliyor: $($model.Label) ($($model.Name)) | ~$($model.RAM) GB RAM"
        Write-Host ""
        try {
            if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
                Write-Warn "Ollama yurutulemedi; once Ollama kuruluyor..."
                Install-Ollama
            }

            $safeName = ($model.Name -replace '[:/\\]', '_') -replace '[^\w\-\._]', '_'
            $outLog = Join-Path $env:TEMP ("ollama_pull_$safeName.log")
            $errLog = "$outLog.err"
            if (Test-Path $outLog) { Remove-Item $outLog -Force -ErrorAction SilentlyContinue }
            if (Test-Path $errLog) { Remove-Item $errLog -Force -ErrorAction SilentlyContinue }

            $start = Get-Date
            # Redirect stdout and stderr to separate files (cannot use the same file for both)
            $proc = Start-Process -FilePath "ollama" -ArgumentList "pull", $model.Name -RedirectStandardOutput $outLog -RedirectStandardError $errLog -NoNewWindow -PassThru

            while (-not $proc.HasExited) {
                $elapsed = (Get-Date) - $start
                $percent = [Math]::Min(95, [int]($elapsed.TotalSeconds * 3))
                $tailParts = @()
                if (Test-Path $outLog) { $tailParts += (Get-Content $outLog -Tail 3 -ErrorAction SilentlyContinue) }
                if (Test-Path $errLog) { $tailParts += (Get-Content $errLog -Tail 3 -ErrorAction SilentlyContinue) }
                $tail = $tailParts -join ' '
                Write-Progress -Activity "Model indiriliyor: $($model.Label)" -Status $tail -PercentComplete $percent
                Start-Sleep -Seconds 1
            }
            Write-Progress -Activity "Model indiriliyor: $($model.Label)" -Completed

            if ($proc.ExitCode -eq 0) {
                Write-OK "$($model.Name) hazir!"
            }
            else {
                $logTailParts = @()
                if (Test-Path $outLog) { $logTailParts += Get-Content $outLog -Tail 20 -ErrorAction SilentlyContinue }
                if (Test-Path $errLog) { $logTailParts += Get-Content $errLog -Tail 20 -ErrorAction SilentlyContinue }
                $logTail = if ($logTailParts.Count -gt 0) { $logTailParts } else { @('No log') }
                Write-Fail "$($model.Name) indirilemedi. ExitCode: $($proc.ExitCode). Son log: $($logTail -join '`n')"
            }
        }
        catch {
            Write-Fail "$($model.Name) indirilemedi: $($_.Exception.Message)"
        }
        Write-Host ""
    }
}

# ============================================================
#  MODEL SILME
# ============================================================
function Remove-OllamaModel {
    $installed = Get-InstalledModels
    if ($installed.Count -eq 0) {
        Write-Warn "Kurulu model bulunamadi."
        return
    }
    Write-Host ""
    Write-Host "  Kurulu modeller:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $installed.Count; $i++) {
        Write-Host "  [$($i+1)] $($installed[$i])" -ForegroundColor White
    }
    Write-Host "  [0] Vazgec" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Silmek istediginiz numara: " -NoNewline -ForegroundColor Yellow
    $delChoice = Read-Host
    $delIdx = 0
    if ([int]::TryParse($delChoice, [ref]$delIdx) -and $delIdx -ge 1 -and $delIdx -le $installed.Count) {
        $modelToDelete = $installed[$delIdx - 1]
        Write-Step "Siliniyor: $modelToDelete"
        try {
            & ollama rm $modelToDelete
            Write-OK "$modelToDelete silindi."
        }
        catch {
            Write-Fail "Silme hatasi: $($_.Exception.Message)"
        }
    }
}

# ============================================================
#  MODEL BENCHMARK
# ============================================================
function Run-ModelBenchmark {
    Write-Section "MODEL BENCHMARK TESTI"

    $installed = Get-InstalledModels
    if ($installed.Count -eq 0) {
        Write-Warn "Benchmark icin kurulu model gerekli."
        return
    }

    $testPrompt = "Turkce olarak 'merhaba dunya' yaz ve 1+1 hesapla."
    Write-Info "Test sorusu: $testPrompt"
    Write-Host ""

    foreach ($m in $installed) {
        Write-Step "Benchmark: $m"
        $startTime = Get-Date
        try {
            $body = @{
                model  = $m
                prompt = $testPrompt
                stream = $false
            } | ConvertTo-Json

            $resp = Invoke-RestMethod -Uri "http://localhost:$OLLAMA_PORT/api/generate" `
                -Method POST -Body $body -ContentType "application/json" -TimeoutSec 120

            $elapsed = (Get-Date) - $startTime
            $tokensEval = $resp.eval_count
            $tps = if ($elapsed.TotalSeconds -gt 0) { [Math]::Round($tokensEval / $elapsed.TotalSeconds, 1) } else { 0 }

            $global:benchmarkResults[$m] = @{
                Time   = [Math]::Round($elapsed.TotalSeconds, 2)
                TPS    = $tps
                Tokens = $tokensEval
            }

            Write-OK "$m | Sure: $([Math]::Round($elapsed.TotalSeconds,2))s | Hiz: $tps token/sn | Tokens: $tokensEval"

        }
        catch {
            Write-Fail "$m benchmark hatasi: $($_.Exception.Message)"
            $global:benchmarkResults[$m] = @{ Time = -1; TPS = 0; Tokens = 0 }
        }
    }

    Write-Host ""
    Write-Host "  BENCHMARK SONUCLARI:" -ForegroundColor Yellow
    $global:benchmarkResults.GetEnumerator() | Sort-Object { $_.Value.TPS } -Descending | ForEach-Object {
        if ($_.Value.TPS -gt 0) {
            Write-Host ("  {0,-30} {1,8} tok/sn  {2,6}s" -f $_.Key, $_.Value.TPS, $_.Value.Time) -ForegroundColor Cyan
        }
    }
    Write-Log -Level "INFO" -Message "Benchmark tamamlandi: $($global:benchmarkResults | ConvertTo-Json -Compress)"
}

# ============================================================
#  CADDY KURULUM + BASLAT
# ============================================================
function Setup-CaddyProxy {
    Write-Section "CADDY WEB SUNUCUSU"

    # Web dizini hazirla
    if (-not (Test-Path $WEB_DIR)) {
        New-Item -ItemType Directory -Path $WEB_DIR -Force | Out-Null
    }

    # Caddy indir
    if (-not (Test-Path $CADDY_EXE)) {
        Write-Step "Caddy indiriliyor..."
        if ($checkIsWindows) {
            Invoke-WebRequest -Uri "https://caddyserver.com/api/download?os=windows&arch=amd64" `
                -OutFile $CADDY_EXE -UseBasicParsing
        }
        else {
            $dlCmd = "wget -q 'https://caddyserver.com/api/download?os=linux&arch=amd64' -O '$CADDY_EXE' && chmod +x '$CADDY_EXE'"
            Invoke-Expression $dlCmd
        }
        Write-OK "Caddy indirildi."
    }
    else {
        Write-OK "Caddy zaten mevcut."
    }

    # PATH ve startup ayari (Windows icin)
    try {
        $caddyBinDir = Split-Path -Path $CADDY_EXE -Parent
        Add-Directory-To-SystemPath -Dir $caddyBinDir
        if ($checkIsWindows) {
            Register-RunAtStartup -Name "BestAI-Caddy" -Exe $CADDY_EXE -Args "run --config `"$WEB_DIR\Caddyfile`""
        }
    } catch {}

    # Caddyfile olustur
    $caddyBind = if ($global:isRemote) { "http://:$CADDY_PORT" } else { "http://127.0.0.1:$CADDY_PORT" }
    $apiKeyHeader = ""
    if ($global:useApiKey) {
        $apiKeyHeader = @"

    @protected {
        not header X-API-Key $($global:generatedApiKey)
        path /api/*
    }
    respond @protected 401
"@
    }

    $proxyTarget = if ($global:bindIp -eq "0.0.0.0") { "127.0.0.1" } else { $global:bindIp }
    $caddyfileContent = @"
{
    auto_https off
}

$caddyBind {
    root * "$WEB_DIR"
    file_server
    $apiKeyHeader
    reverse_proxy /api/* $($proxyTarget):$OLLAMA_PORT {
        header_up Access-Control-Allow-Origin *
        header_up Access-Control-Allow-Methods "GET, POST, OPTIONS"
        header_up Access-Control-Allow-Headers "Content-Type, Authorization, X-API-Key"
    }

    encode gzip zstd

    header {
        X-Frame-Options SAMEORIGIN
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
    }

    log {
        output file "$LOG_DIR\caddy_access.log" {
            roll_size 10mb
            roll_keep 3
        }
        format json
    }
}
"@
    $caddyfileContent | Out-File -FilePath "$WEB_DIR\Caddyfile" -Encoding utf8
    Write-OK "Caddyfile yazildi."

    # Eski Caddy'yi kapat
    if ($checkIsWindows) {
        Get-Process caddy -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    else {
        Invoke-Expression "pkill caddy 2>/dev/null; true"
    }
    Start-Sleep -Seconds 1

    # Caddy baslat
    Write-Step "Caddy baslatiliyor ($caddyBind)..."
    if ($checkIsWindows) {
        Start-Process -FilePath $CADDY_EXE -ArgumentList "run --config `"$WEB_DIR\Caddyfile`"" -WindowStyle Hidden
    }
    else {
        Invoke-Expression "nohup '$CADDY_EXE' run --config '$WEB_DIR/Caddyfile' > '$LOG_DIR/caddy.log' 2>&1 &"
    }
    Start-Sleep -Seconds 2

    # Kontrol
    try {
        $test = Invoke-WebRequest -Uri "http://127.0.0.1:$CADDY_PORT" -UseBasicParsing -TimeoutSec 5
        Write-OK "Caddy calisiyor: http://127.0.0.1:$CADDY_PORT"
        $global:caddyRunning = $true
    }
    catch {
        Write-Warn "Caddy port kontrolunde gecikme var, devam ediliyor..."
        $global:caddyRunning = $true
    }
}

# ============================================================
#  CLOUDFLARE TUNNEL
# ============================================================

# GUI removed: console-only mode enforced (Show-GUIMainMenu and Windows Forms removed)

# GUI disabled - Show-GUIMainMenu removed; console interactive loop handles startup args at the end of the script.
function Start-CloudflareTunnel {
    Write-Section "CLOUDFLARE TUNNEL"
    Write-Step "cloudflared indiriliyor / kontrol ediliyor..."

    if (-not (Test-Path $CF_EXE)) {
        if ($checkIsWindows) {
            Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" `
                -OutFile $CF_EXE -UseBasicParsing
        }
        else {
            Invoke-Expression "wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O '$CF_EXE' && chmod +x '$CF_EXE'"
        }
        Write-OK "cloudflared indirildi."
    }
    else {
        Write-OK "cloudflared zaten mevcut."
    }

    try {
        $cfDir = Split-Path -Path $CF_EXE -Parent
        Add-Directory-To-SystemPath -Dir $cfDir
        if ($checkIsWindows) {
            Register-RunAtStartup -Name "BestAI-cloudflared" -Exe $CF_EXE -Args "tunnel --url http://127.0.0.1:$CADDY_PORT"
        }
    } catch {}

    $cfLogFile = "$LOG_DIR\cf_tunnel.log"
    if (Test-Path $cfLogFile) { Remove-Item $cfLogFile -Force }

    # Kill old
    if ($checkIsWindows) {
        Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    else {
        Invoke-Expression "pkill cloudflared 2>/dev/null; true"
    }
    Start-Sleep -Seconds 1

    Write-Step "Tunel baslatiliyor (Port $CADDY_PORT)..."
    if ($checkIsWindows) {
        $cfProc = Start-Process -FilePath $CF_EXE `
            -ArgumentList "tunnel --url http://127.0.0.1:$CADDY_PORT" `
            -NoNewWindow -RedirectStandardError $cfLogFile -PassThru
        $null = $cfProc
    }
    else {
        Invoke-Expression "nohup '$CF_EXE' tunnel --url http://127.0.0.1:$CADDY_PORT > '$cfLogFile' 2>&1 &"
    }

    Write-Step "Global domain bekleniyor (max 20s)..."
    $found = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path $cfLogFile) {
            $logContent = Get-Content $cfLogFile -Raw -ErrorAction SilentlyContinue
            if ($logContent -match "(https://[a-zA-Z0-9\-]+\.trycloudflare\.com)") {
                $global:tunnelUrl = $matches[1]
                $found = $true
                break
            }
        }
        Write-Host "." -NoNewline -ForegroundColor Cyan
    }
    Write-Host ""

    if ($found) {
        Write-OK "Cloudflare Tunnel AKTIF: $($global:tunnelUrl)"
    }
    else {
        Write-Warn "Tunel URL 20 saniyede alinamadi. Log: $cfLogFile"
        $global:tunnelUrl = "Alinamadi - Log kontrol edin: $cfLogFile"
    }
}

# ============================================================
#  NGROK TUNNEL
# ============================================================
function Start-NgrokTunnel {
    Write-Section "NGROK TUNNEL"

    if (-not (Test-Path $NGROK_EXE)) {
        Write-Step "ngrok indiriliyor..."
        if ($checkIsWindows) {
            Invoke-WebRequest -Uri "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip" `
                -OutFile "$env:TEMP\ngrok.zip" -UseBasicParsing
            Expand-Archive -Path "$env:TEMP\ngrok.zip" -DestinationPath $env:TEMP -Force
            Remove-Item "$env:TEMP\ngrok.zip" -Force -ErrorAction SilentlyContinue
        }
        else {
            Invoke-Expression "wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz -O /tmp/ngrok.tgz && tar xzf /tmp/ngrok.tgz -C /tmp && chmod +x /tmp/ngrok"
            $NGROK_EXE = "/tmp/ngrok"
        }
        Write-OK "ngrok indirildi."
    }
    else {
        Write-OK "ngrok zaten mevcut."
    }

    try {
        $ngrokDir = Split-Path -Path $NGROK_EXE -Parent
        Add-Directory-To-SystemPath -Dir $ngrokDir
        if ($checkIsWindows) {
            Register-RunAtStartup -Name "BestAI-ngrok" -Exe $NGROK_EXE -Args "http $CADDY_PORT --log=stdout"
        }
    } catch {}

    Write-Host "  ngrok authtoken gerekiyor (https://ngrok.com/signup)" -ForegroundColor Yellow
    Write-Host "  Authtoken: " -NoNewline -ForegroundColor White
    $ngrokToken = Read-Host

    if ($ngrokToken) {
        try {
            & $NGROK_EXE config add-authtoken $ngrokToken 2>$null
            Write-OK "ngrok token eklendi."
        }
        catch { Write-Warn "Token eklenirken sorun: $($_.Exception.Message)" }
    }

    $ngrokLog = "$LOG_DIR\ngrok.log"
    if ($checkIsWindows) {
        Start-Process -FilePath $NGROK_EXE -ArgumentList "http $CADDY_PORT --log=stdout" `
            -NoNewWindow -RedirectStandardOutput $ngrokLog -PassThru | Out-Null
    }
    else {
        Invoke-Expression "nohup '$NGROK_EXE' http $CADDY_PORT > '$ngrokLog' 2>&1 &"
    }

    Start-Sleep -Seconds 4
    try {
        $ngrokApi = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 5
        $publicUrl = $ngrokApi.tunnels | Where-Object { $_.proto -eq "https" } | Select-Object -First 1 -ExpandProperty public_url
        if ($publicUrl) {
            $global:tunnelUrl = $publicUrl
            Write-OK "ngrok Tunnel AKTIF: $publicUrl"
        }
        else {
            Write-Warn "ngrok URL alinamadi. ngrok dashboard: http://127.0.0.1:4040"
            $global:tunnelUrl = "http://127.0.0.1:4040 (dashboard)"
        }
    }
    catch {
        Write-Warn "ngrok API yanit vermedi. Loglara bakin: $ngrokLog"
    }
}

# ============================================================
#  WEB ARAYUZU HTML OLUSTUR
# ============================================================
function Build-WebUI {
    Write-Section "WEB ARAYUZU OLUSTURULUYOR"

    if (-not (Test-Path $WEB_DIR)) {
        New-Item -ItemType Directory -Path $WEB_DIR -Force | Out-Null
    }

    $apiKeyMeta = if ($global:useApiKey) { $global:generatedApiKey } else { "" }
    $serverStatus = "AKTIF"

    # Copy custom icon if present
    try {
        $scriptIcon = if ($PSScriptRoot) { Join-Path $PSScriptRoot '1.ico' } else { Join-Path (Get-Location) '1.ico' }
        if (Test-Path $scriptIcon) { Copy-Item -Path $scriptIcon -Destination (Join-Path $WEB_DIR '1.ico') -Force }
    } catch {}

    $gpuLabel = if ($global:gpuInfo.Available -and $global:gpuInfo.Name) { "$($global:gpuInfo.Name) ($($global:gpuInfo.VRAM)GB)" } elseif ($global:gpuInfo.Type) { $global:gpuInfo.Type } else { 'CPU' }

    $htmlContent = @'
<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Siber Akademi AI | Local Intelligence Hub</title>
    <link rel="icon" href="1.ico">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300;400;500;600;700&family=JetBrains+Mono:wght@300;400;600&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css">
    <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
    <style>
        :root {
            --gold:       #d4a843;
            --gold-light: #f0c96e;
            --gold-dim:   rgba(212,168,67,0.15);
            --bg:         #080808;
            --bg2:        #0f0f0f;
            --bg3:        #161616;
            --border:     rgba(212,168,67,0.2);
            --border-bright: rgba(212,168,67,0.5);
            --text:       #e8e8e8;
            --text-dim:   #888;
            --red:        #e05252;
            --green:      #52c48a;
            --radius:     12px;
            --font:       'Space Grotesk', sans-serif;
            --mono:       'JetBrains Mono', monospace;
        }

        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

        html, body {
            height: 100%;
            overflow: hidden;
            font-family: var(--font);
            background: var(--bg);
            color: var(--text);
        }

        /* Matrix Canvas */
        #matrix {
            position: fixed;
            top: 0; left: 0;
            width: 100vw; height: 100vh;
            z-index: 0;
            opacity: 0.12;
            pointer-events: none;
        }

        /* Background grid */
        body::before {
            content: '';
            position: fixed;
            inset: 0;
            background-image:
                linear-gradient(rgba(212,168,67,0.03) 1px, transparent 1px),
                linear-gradient(90deg, rgba(212,168,67,0.03) 1px, transparent 1px);
            background-size: 40px 40px;
            pointer-events: none;
            z-index: 1;
        }

        /* Corner glow */
        body::after {
            content: '';
            position: fixed;
            bottom: -200px; right: -200px;
            width: 500px; height: 500px;
            background: radial-gradient(circle, rgba(212,168,67,0.06) 0%, transparent 70%);
            pointer-events: none;
            z-index: 1;
        }

        /* ===================== LAYOUT ===================== */
        .layout {
            position: relative;
            z-index: 1;
            display: grid;
            grid-template-columns: 280px 1fr;
            height: 100vh;
        }

        /* ===================== SIDEBAR ===================== */
        .sidebar {
            background: var(--bg2);
            border-right: 1px solid var(--border);
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }

        .brand {
            padding: 20px 20px 16px;
            border-bottom: 1px solid var(--border);
        }
        .brand-icon { width:28px; height:28px; border-radius:6px; object-fit:contain; margin-right:8px }
        .brand-logo {
            font-size: 11px;
            letter-spacing: 3px;
            text-transform: uppercase;
            color: var(--gold);
            font-weight: 600;
            margin-bottom: 4px;
        }
        .brand-sub {
            font-size: 10px;
            color: var(--text-dim);
            letter-spacing: 1px;
        }

        .status-bar {
            padding: 10px 20px;
            border-bottom: 1px solid var(--border);
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 11px;
            color: var(--text-dim);
        }
        .dot {
            width: 7px; height: 7px;
            border-radius: 50%;
            background: var(--green);
            box-shadow: 0 0 6px var(--green);
            animation: breathe 2s ease infinite;
        }
        @keyframes breathe {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.4; }
        }
        .dot.red { background: var(--red); box-shadow: 0 0 6px var(--red); }

        .sidebar-section {
            padding: 14px 20px 8px;
            font-size: 10px;
            letter-spacing: 2px;
            text-transform: uppercase;
            color: var(--gold);
            font-weight: 600;
        }

        .model-select-wrap {
            padding: 0 16px 16px;
        }
        .model-select-wrap select {
            width: 100%;
            background: var(--bg3);
            color: var(--text);
            border: 1px solid var(--border);
            padding: 8px 12px;
            border-radius: 8px;
            font-family: var(--mono);
            font-size: 12px;
            outline: none;
            cursor: pointer;
            -webkit-appearance: none;
        }
        .model-select-wrap select:focus {
            border-color: var(--gold);
            box-shadow: 0 0 10px var(--gold-dim);
        }

        .sidebar-actions {
            padding: 0 16px;
            display: flex;
            flex-direction: column;
            gap: 6px;
        }
        .action-btn {
            display: flex;
            align-items: center;
            gap: 10px;
            padding: 9px 12px;
            background: transparent;
            border: 1px solid transparent;
            border-radius: 8px;
            color: var(--text-dim);
            font-size: 12px;
            cursor: pointer;
            transition: all 0.2s;
            text-align: left;
            font-family: var(--font);
        }
        .action-btn:hover {
            background: var(--gold-dim);
            border-color: var(--border);
            color: var(--gold);
        }
        .action-btn .btn-icon { font-size: 14px; }

        .sidebar-stats {
            margin-top: auto;
            padding: 16px 20px;
            border-top: 1px solid var(--border);
        }
        .stat-row {
            display: flex;
            justify-content: space-between;
            font-size: 11px;
            padding: 3px 0;
            color: var(--text-dim);
        }
        .stat-val { color: var(--gold); font-family: var(--mono); }

        /* ===================== MAIN ===================== */
        .main {
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }

        .topbar {
            padding: 0 24px;
            height: 52px;
            border-bottom: 1px solid var(--border);
            display: flex;
            align-items: center;
            justify-content: space-between;
            background: var(--bg2);
            flex-shrink: 0;
        }
        .topbar-title {
            font-size: 14px;
            font-weight: 600;
            color: var(--text);
            letter-spacing: 0.5px;
        }
        .topbar-right {
            display: flex;
            gap: 8px;
            align-items: center;
        }
        .chip {
            font-size: 10px;
            padding: 3px 10px;
            border-radius: 20px;
            border: 1px solid var(--border);
            color: var(--text-dim);
            font-family: var(--mono);
            letter-spacing: 0.5px;
        }
        .chip.active { border-color: var(--gold); color: var(--gold); background: var(--gold-dim); }

        /* ===================== CHAT ===================== */
        .chat {
            flex: 1;
            overflow-y: auto;
            padding: 24px;
            display: flex;
            flex-direction: column;
            gap: 18px;
        }
        .chat::-webkit-scrollbar { width: 5px; }
        .chat::-webkit-scrollbar-track { background: transparent; }
        .chat::-webkit-scrollbar-thumb { background: var(--border); border-radius: 10px; }

        .msg {
            display: flex;
            gap: 14px;
            max-width: 800px;
            animation: slideUp 0.25s ease;
        }
        @keyframes slideUp {
            from { opacity: 0; transform: translateY(14px); }
            to   { opacity: 1; transform: translateY(0); }
        }
        .msg.user { flex-direction: row-reverse; align-self: flex-end; }
        .msg.ai   { align-self: flex-start; }

        .avatar {
            width: 34px; height: 34px;
            border-radius: 8px;
            flex-shrink: 0;
            display: flex; align-items: center; justify-content: center;
            font-size: 14px;
        }
        .avatar.user-av {
            background: linear-gradient(135deg, var(--gold) 0%, #a07820 100%);
            color: #000;
            font-weight: 700;
        }
        .avatar.ai-av {
            background: var(--bg3);
            border: 1px solid var(--border);
            color: var(--gold);
        }

        .bubble {
            padding: 12px 18px;
            border-radius: 12px;
            font-size: 14px;
            line-height: 1.6;
            word-wrap: break-word;
            max-width: 85%;
            min-width: 50px;
            position: relative;
        }
        .bubble.user-bubble {
            background: var(--gold-dim);
            border: 1px solid var(--border-bright);
            color: var(--text);
            border-top-right-radius: 2px;
        }
        .bubble.ai-bubble {
            background: var(--bg3);
            border: 1px solid var(--border);
            color: var(--text);
            border-top-left-radius: 2px;
        }

        .bubble pre {
            background: #0d0d0d;
            border: 1px solid rgba(255,255,255,0.07);
            border-radius: 8px;
            padding: 14px 16px;
            margin: 10px 0;
            overflow-x: auto;
            font-family: var(--mono);
            font-size: 13px;
        }
        .bubble code:not(pre code) {
            background: rgba(255,255,255,0.07);
            border-radius: 4px;
            padding: 1px 6px;
            font-family: var(--mono);
            font-size: 12px;
        }
        .bubble table {
            border-collapse: collapse;
            width: 100%;
            margin: 10px 0;
            font-size: 13px;
        }
        .bubble th, .bubble td {
            border: 1px solid var(--border);
            padding: 6px 12px;
            text-align: left;
        }
        .bubble th { background: var(--bg2); color: var(--gold); }
        .bubble strong { color: var(--gold-light); }
        .bubble h1,.bubble h2,.bubble h3 {
            color: var(--gold);
            margin: 12px 0 6px;
            font-size: 1em;
        }

        .typing-indicator {
            display: flex;
            gap: 5px;
            padding: 4px 0;
        }
        .typing-indicator span {
            width: 6px; height: 6px;
            border-radius: 50%;
            background: var(--gold);
            animation: bounce 1.2s infinite;
        }
        .typing-indicator span:nth-child(2) { animation-delay: 0.2s; }
        .typing-indicator span:nth-child(3) { animation-delay: 0.4s; }
        @keyframes bounce {
            0%, 80%, 100% { transform: translateY(0); opacity: 0.4; }
            40% { transform: translateY(-5px); opacity: 1; }
        }

        .file-badge {
            display: inline-flex; align-items: center; gap: 6px;
            background: rgba(212,168,67,0.1); border: 1px solid var(--border);
            padding: 3px 10px; border-radius: 20px;
            font-size: 11px; font-family: var(--mono);
            color: var(--gold); margin-bottom: 8px;
        }
        .meta-info {
            font-size: 10px; color: var(--text-dim);
            margin-top: 6px; font-family: var(--mono);
        }

        /* ===================== INPUT ===================== */
        .input-zone {
            padding: 16px 24px;
            border-top: 1px solid var(--border);
            background: var(--bg2);
            flex-shrink: 0;
        }
        .input-box {
            display: flex;
            gap: 10px;
            align-items: flex-end;
        }
        .input-inner {
            flex: 1;
            background: var(--bg3);
            border: 1px solid var(--border);
            border-radius: var(--radius);
            padding: 10px 14px;
            transition: border-color 0.2s, box-shadow 0.2s;
        }
        .input-inner:focus-within {
            border-color: var(--gold);
            box-shadow: 0 0 20px rgba(212,168,67,0.08);
        }
        .input-file-preview {
            margin-bottom: 8px;
            display: flex; gap: 6px; flex-wrap: wrap;
        }
        #promptInput {
            display: block; width: 100%;
            background: transparent; border: none; outline: none;
            color: var(--text); font-family: var(--font); font-size: 14px;
            resize: none; min-height: 42px; max-height: 140px;
            overflow-y: auto; line-height: 1.5;
        }
        #promptInput::placeholder { color: var(--text-dim); }
        .input-toolbar {
            display: flex; gap: 4px; margin-top: 6px;
        }
        .tool-btn {
            background: transparent; border: 1px solid transparent;
            color: var(--text-dim); padding: 4px 8px;
            border-radius: 6px; cursor: pointer; font-size: 13px;
            transition: all 0.2s;
        }
        .tool-btn:hover { border-color: var(--border); color: var(--gold); }
        .tool-btn.recording {
            color: var(--red);
            text-shadow: 0 0 8px var(--red);
            animation: micPulse 1.2s infinite;
        }
        @keyframes micPulse {
            0%, 100% { transform: scale(1); opacity: 1; }
            50% { transform: scale(1.2); opacity: 0.7; }
        }
        .tool-btn.recording {
            color: var(--red);
            animation: recordPulse 1s infinite;
        }
        @keyframes recordPulse {
            0%,100% { box-shadow: none; }
            50% { box-shadow: 0 0 10px var(--red); border-color: var(--red); }
        }
        .send-button {
            padding: 0 20px;
            height: 50px;
            background: linear-gradient(135deg, #c49030 0%, #8a6010 100%);
            color: #000;
            border: none;
            border-radius: var(--radius);
            font-weight: 700;
            font-size: 12px;
            letter-spacing: 1.5px;
            text-transform: uppercase;
            cursor: pointer;
            transition: all 0.2s;
            font-family: var(--font);
        }
        .send-button:hover {
            background: linear-gradient(135deg, var(--gold-light) 0%, #c49030 100%);
            box-shadow: 0 0 20px rgba(212,168,67,0.3);
            transform: translateY(-1px);
        }
        .send-button:active { transform: translateY(0); }
        .input-hint {
            font-size: 10px; color: var(--text-dim);
            margin-top: 8px; text-align: center;
            font-family: var(--mono);
        }

        /* ===================== MODAL ===================== */
        .modal-bg {
            position: fixed; inset: 0;
            background: rgba(0,0,0,0.7); backdrop-filter: blur(6px);
            z-index: 100;
            display: none; align-items: center; justify-content: center;
        }
        .modal-bg.open { display: flex; }
        .modal {
            background: var(--bg2);
            border: 1px solid var(--border-bright);
            border-radius: 16px;
            padding: 28px 32px;
            width: 500px; max-width: 95vw;
            box-shadow: 0 20px 60px rgba(0,0,0,0.6);
        }
        .modal h2 { color: var(--gold); font-size: 16px; margin-bottom: 16px; letter-spacing: 0.5px; }
        .modal-close {
            float: right; background: transparent; border: none;
            color: var(--text-dim); font-size: 20px; cursor: pointer;
            line-height: 1;
        }
        .modal-close:hover { color: var(--red); }
        .modal-body { font-size: 13px; color: var(--text-dim); line-height: 1.7; }
        .modal-row { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid var(--border); }
        .modal-key { color: var(--text-dim); }
        .modal-val { color: var(--gold); font-family: var(--mono); font-size: 12px; }

        /* ===================== TOAST ===================== */
        #toast {
            position: fixed; bottom: 20px; right: 20px;
            background: var(--bg3); border: 1px solid var(--gold);
            color: var(--gold); padding: 10px 20px;
            border-radius: 8px; font-size: 13px;
            z-index: 200; opacity: 0;
            transition: opacity 0.3s;
            pointer-events: none;
        }
        #toast.show { opacity: 1; }

        /* Responsive */
        @media (max-width: 700px) {
            .layout { grid-template-columns: 1fr; }
            .sidebar { display: none; }
        }
    </style>
</head>
<body>
<canvas id="matrix"></canvas>

<div class="layout">

    <!-- ========== SIDEBAR ========== -->
    <aside class="sidebar">
        <div class="brand">
            <div style="display:flex;align-items:center;gap:10px">
                <img src="1.ico" class="brand-icon" alt="icon" />
                <div>
                    <div class="brand-logo">Siber Akademi AI</div>
                    <div class="brand-sub">hopp.bio/siberegitim &mdash; v3.0</div>
                </div>
            </div>
        </div>

        <div class="status-bar">
            <div class="dot" id="serverDot"></div>
            <span id="serverStatusText">Sunucu kontrol ediliyor...</span>
        </div>

        <div class="sidebar-section">Model</div>
        <div class="model-select-wrap">
            <select id="modelSelect">
                <option value="">Y&#252;kleniyor...</option>
            </select>
        </div>

        <div class="sidebar-section">&#304;&#351;lemler</div>
        <div class="sidebar-actions">
            <button class="action-btn" onclick="clearChat()">
                <span class="btn-icon">&#x1F5D1;</span> Sohbeti Temizle
            </button>
            <button class="action-btn" onclick="exportChat()">
                <span class="btn-icon">&#x1F4BE;</span> Sohbeti D&#305;&#351;a Aktar
            </button>
            <button class="action-btn" onclick="refreshModels()">
                <span class="btn-icon">&#x21BB;</span> Modelleri Yenile
            </button>
            <button class="action-btn" onclick="openSystemModal()">
                <span class="btn-icon">&#x2139;</span> Sistem Bilgisi
            </button>
            <button class="action-btn" id="streamToggle" onclick="toggleStream()">
                <span class="btn-icon">&#x26A1;</span> Stream: Acik
            </button>
        </div>

        <div class="sidebar-stats">
            <div class="stat-row"><span>Mesajlar</span> <span class="stat-val" id="msgCount">0</span></div>
            <div class="stat-row"><span>Toplam Token</span> <span class="stat-val" id="tokenCount">~0</span></div>
            <div class="stat-row"><span>Sunucu</span> <span class="stat-val">{{BIND_IP}}:{{OLLAMA_PORT}}</span></div>
            <div class="stat-row"><span>Aray&#252;z</span> <span class="stat-val">{{BIND_IP}}:{{CADDY_PORT}}</span></div>
        </div>
    </aside>

    <!-- ========== MAIN ========== -->
    <main class="main">
        <div class="topbar">
            <span class="topbar-title" id="topbarTitle">Yeni Sohbet</span>
            <div class="topbar-right">
                <span class="chip active" id="modelChip">Model se&#231;iniz</span>
                <span class="chip" id="gpuChip">{{GPU_LABEL}}</span>
            </div>
        </div>

        <div class="chat" id="chatArea">
            <div class="msg ai" id="welcomeMsg">
                <div class="avatar ai-av">&#x2666;</div>
                <div>
                    <div class="bubble ai-bubble">
                        <strong>Siber Akademi Yerel Yapay Zeka Asistan&#305;'na ho&#351;geldiniz.</strong><br><br>
                        Bu sistem tamamen <em>offline</em> &#231;al&#305;&#351;&#305;r &mdash; verileriniz hi&#231;bir zaman d&#305;&#351;ar&#305; &#231;&#305;kmaz.
                        Model se&#231;ip mesaj yazarak ba&#351;lay&#305;n. Dosya ekleyebilir, sesli komut kullanabilirsiniz.<br><br>
                        <code>Shift+Enter</code> ile g&#246;nderin &bull; Dosya i&#231;in &#x1F4CE; &bull; Ses i&#231;in &#x1F3A4;
                    </div>
                    <div class="meta-info">Siber Akademi AI Server v3.0</div>
                </div>
            </div>
        </div>

        <div class="input-zone">
            <div class="input-box">
                <div class="input-inner">
                    <div class="input-file-preview" id="filePreview"></div>
                    <textarea id="promptInput" placeholder="Mesaj&#305;n&#305;z&#305; yaz&#305;n...  (Shift+Enter ile g&#246;nder)" rows="1"></textarea>
                    <div class="input-toolbar">
                        <button class="tool-btn" id="micBtn" title="Sesli Giri&#351;">&#x1F3A4;</button>
                        <button class="tool-btn" id="fileBtn" title="Dosya Ekle">&#x1F4CE;</button>
                        <input type="file" id="fileInput" style="display:none" accept=".txt,.csv,.json,.md,.js,.py,.html,.css,.ps1,.sh,.log,.xml,.yaml,.yml,.c,.cpp,.h,.rs,.go,.ts">
                        <button class="tool-btn" onclick="clearPrompt()" title="Temizle">&#x2715;</button>
                    </div>
                </div>
                <button class="send-button" id="sendBtn" onclick="sendMessage()">G&#214;NDER</button>
            </div>
            <div class="input-hint">Shift+Enter: G&#246;nder &nbsp;&bull;&nbsp; Enter: Yeni Sat&#305;r &nbsp;&bull;&nbsp; API: {{BIND_IP}}:{{OLLAMA_PORT}}</div>
        </div>
    </main>
</div>

<!-- ========== SYSTEM MODAL ========== -->
<div class="modal-bg" id="sysModal">
    <div class="modal">
        <button class="modal-close" onclick="closeSysModal()">&#x2715;</button>
        <h2>&#x2139; Sistem Bilgisi</h2>
        <div class="modal-body" id="sysModalBody">Y&#252;kleniyor...</div>
    </div>
</div>

<div id="toast"></div>

<script>
    const API_KEY = "{{API_KEY}}";
    const PORT    = "{{OLLAMA_PORT}}";
    const BASE_URL = location.origin; // Use the same origin for all API requests via Caddy proxy


    // ===== STATE =====
    let chatHistory  = [];
    let msgCount     = 0;
    let tokenCount   = 0;
    let streamMode   = true;
    let attached     = null;
    let isRecording  = false;
    let recognition  = null;

    // ===== INIT =====
    document.addEventListener('DOMContentLoaded', () => {
        fetchModels();
        checkServer();
        autoResizeTextarea();
        setupKeyboard();
        setupMic();
        setupFileBtn();
        setInterval(checkServer, 15000);
    });

    // ===== HELPERS =====
    function getHeaders() {
        const h = { 'Content-Type': 'application/json' };
        if (API_KEY) h['X-API-Key'] = API_KEY;
        return h;
    }

    function toast(msg) {
        const el = document.getElementById('toast');
        el.textContent = msg;
        el.classList.add('show');
        setTimeout(() => el.classList.remove('show'), 3000);
    }

    function scrollChat() {
        const c = document.getElementById('chatArea');
        setTimeout(() => c.scrollTop = c.scrollHeight, 30);
    }

    function updateCounters() {
        document.getElementById('msgCount').textContent = msgCount;
        document.getElementById('tokenCount').textContent = '~' + tokenCount;
    }

    // ===== SERVER CHECK =====
    async function checkServer() {
        const dot  = document.getElementById('serverDot');
        const text = document.getElementById('serverStatusText');
        try {
            const r = await fetch(BASE_URL + '/api/tags', { 
                headers: getHeaders(), 
                signal: AbortSignal.timeout(4000) 
            });
            if (r.ok) {
                dot.classList.remove('red');
                text.textContent = 'Sunucu AKTIF';
            } else { throw new Error(); }
        } catch {
            dot.classList.add('red');
            text.textContent = 'Sunucu baglanti yok';
        }
    }

    // ===== MODELS =====
    async function fetchModels() {
        try {
            const r    = await fetch(BASE_URL + '/api/tags', { headers: getHeaders() });
            const data = await r.json();
            const sel  = document.getElementById('modelSelect');
            sel.innerHTML = '';
            if (!data.models || data.models.length === 0) {
                sel.innerHTML = '<option value="">Model bulunamadi</option>';
                return;
            }
            data.models.forEach(m => {
                const opt  = document.createElement('option');
                opt.value  = m.name;
                opt.textContent = m.name;
                sel.appendChild(opt);
            });
            updateModelChip();
        } catch {
            document.getElementById('modelSelect').innerHTML = '<option value="">Baglanti hatasi</option>';
        }
    }

    function refreshModels() { fetchModels(); toast('Modeller yenilendi'); }

    document.getElementById('modelSelect').addEventListener('change', updateModelChip);
    function updateModelChip() {
        const v = document.getElementById('modelSelect').value;
        const chip = document.getElementById('modelChip');
        chip.textContent = v || 'Model seciniz';
        chip.className   = 'chip' + (v ? ' active' : '');
        const title = document.getElementById('topbarTitle');
        title.textContent = v ? `${v} ile Sohbet` : 'Yeni Sohbet';
    }

    // ===== SEND MESSAGE =====
    async function sendMessage() {
        const input = document.getElementById('promptInput');
        const model = document.getElementById('modelSelect').value;
        const raw   = input.value.trim();

        if (!raw && !attached) return;
        if (!model) { toast('Lutfen bir model secin!'); return; }

        let userPrompt = raw;
        let fileBadgeHtml = '';

        if (attached) {
            fileBadgeHtml = `<div class="file-badge">&#x1F4C4; ${attached.name}</div><br>`;
            userPrompt    = `Yuklenen Dosya: ${attached.name}\nIcerik:\n${attached.content}\n\n---\nSoru: ${raw}`;
            clearAttached();
        }

        // User bubble
        appendMsg('user', fileBadgeHtml + (raw ? marked.parse(raw) : '<em>(Dosya gonderildi)</em>'), '');
        chatHistory.push({ role: 'user', content: userPrompt });
        input.value = '';
        input.style.height = 'auto';
        msgCount++;
        tokenCount += Math.ceil(userPrompt.length / 4);
        updateCounters();
        scrollChat();

        // AI bubble with loader
        const aiEl = appendMsg('ai', '<div class="typing-indicator"><span></span><span></span><span></span></div>', null);
        const start = Date.now();

        try {
            if (streamMode) {
                const resp = await fetch(BASE_URL + '/api/chat', {
                    method: 'POST',
                    headers: getHeaders(),
                    body: JSON.stringify({ model, messages: chatHistory, stream: true })
                });
                if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

                const reader  = resp.body.getReader();
                const decoder = new TextDecoder();
                let full = '';
                aiEl.innerHTML = '';

                while (true) {
                    const { done, value } = await reader.read();
                    if (done) break;
                    const lines = decoder.decode(value, { stream: true }).split('\n');
                    for (const line of lines) {
                        if (!line.trim()) continue;
                        try {
                            const p = JSON.parse(line);
                            if (p.message?.content) {
                                full += p.message.content;
                                aiEl.innerHTML = marked.parse(full);
                                hljs.highlightAll();
                                scrollChat();
                            }
                        } catch {}
                    }
                }
                chatHistory.push({ role: 'assistant', content: full });
                tokenCount += Math.ceil(full.length / 4);
            } else {
                const resp = await fetch(BASE_URL + '/api/chat', {
                    method: 'POST',
                    headers: getHeaders(),
                    body: JSON.stringify({ model, messages: chatHistory, stream: false })
                });
                const data = await resp.json();
                const content = data.message?.content || '';
                aiEl.innerHTML = marked.parse(content);
                hljs.highlightAll();
                chatHistory.push({ role: 'assistant', content });
                tokenCount += Math.ceil(content.length / 4);
            }

            const elapsed = ((Date.now() - start) / 1000).toFixed(1);
            const metaEl  = aiEl.parentElement.parentElement.querySelector('.meta-info');
            if (metaEl) metaEl.textContent = `${model} &bull; ${elapsed}s`;
            msgCount++;
            updateCounters();

        } catch(e) {
            aiEl.innerHTML = `<span style="color:var(--red)">Hata: ${e.message}</span>`;
        }
        scrollChat();
    }

    function appendMsg(role, html, metaText) {
        const chat = document.getElementById('chatArea');
        const wrap = document.createElement('div');
        wrap.className = `msg ${role}`;

        const av = document.createElement('div');
        av.className = role === 'user' ? 'avatar user-av' : 'avatar ai-av';
        av.textContent = role === 'user' ? 'S' : '\u2666';

        const inner = document.createElement('div');
        const bubble = document.createElement('div');
        bubble.className = role === 'user' ? 'bubble user-bubble' : 'bubble ai-bubble';
        bubble.innerHTML = html;

        inner.appendChild(bubble);

        if (metaText !== null) {
            const meta = document.createElement('div');
            meta.className = 'meta-info';
            meta.innerHTML = metaText || '';
            inner.appendChild(meta);
        }

        wrap.appendChild(av);
        wrap.appendChild(inner);
        chat.appendChild(wrap);
        scrollChat();
        return bubble;
    }

    // ===== KEYBOARD =====
    function setupKeyboard() {
        const inp = document.getElementById('promptInput');
        inp.addEventListener('keydown', e => {
            if (e.key === 'Enter' && e.shiftKey) {
                e.preventDefault();
                sendMessage();
            }
        });
    }

    function autoResizeTextarea() {
        const ta = document.getElementById('promptInput');
        ta.addEventListener('input', () => {
            ta.style.height = 'auto';
            ta.style.height = Math.min(ta.scrollHeight, 140) + 'px';
        });
    }

    function clearPrompt() {
        document.getElementById('promptInput').value = '';
        document.getElementById('promptInput').style.height = 'auto';
        clearAttached();
    }

    // ===== VOICE =====
    function setupMic() {
        const btn = document.getElementById('micBtn');
        const SR = window.SpeechRecognition || window.webkitSpeechRecognition;

        if (!SR) {
            btn.title = "Tarayici desteklemiyor veya HTTPS gerekiyor";
            btn.style.opacity = "0.3";
            btn.onclick = () => toast('Sesli giriş için HTTPS veya localhost gereklidir.');
            return;
        }

        recognition = new SR();
        recognition.lang = 'tr-TR';
        recognition.continuous = false;
        recognition.interimResults = true;

        recognition.onstart = () => {
            isRecording = true;
            btn.classList.add('recording');
            toast('Dinliyorum...');
        };

        recognition.onend = () => {
            isRecording = false;
            btn.classList.remove('recording');
        };

        recognition.onerror = (e) => {
            isRecording = false;
            btn.classList.remove('recording');
            if (e.error === 'not-allowed') toast('Mikrofon izni reddedildi!');
            else toast('Ses hatası: ' + e.error);
        };

        recognition.onresult = (e) => {
            const transcript = Array.from(e.results)
                .map(res => res[0].transcript)
                .join('');
            const inp = document.getElementById('promptInput');
            inp.value = transcript;
            autoResizeTextarea();

            if (e.results[0].isFinal) {
                // Optional: Auto send or just wait
                toast('Algılandı!');
            }
        };

        btn.onclick = () => {
            if (isRecording) recognition.stop();
            else recognition.start();
        };
    }

    // ===== FILE =====
    function setupFileBtn() {
        document.getElementById('fileBtn').onclick = () => document.getElementById('fileInput').click();
        document.getElementById('fileInput').onchange = e => {
            const file = e.target.files[0];
            if (!file) return;
            const reader = new FileReader();
            reader.onload = re => {
                attached = { name: file.name, content: re.target.result };
                const prev = document.getElementById('filePreview');
                prev.innerHTML = `<div class="file-badge">&#x1F4C4; ${file.name} <button onclick="clearAttached()" style="background:none;border:none;color:inherit;cursor:pointer;margin-left:6px;">&#x2715;</button></div>`;
            };
            reader.readAsText(file);
        };
    }

    function clearAttached() {
        attached = null;
        document.getElementById('filePreview').innerHTML = '';
        document.getElementById('fileInput').value = '';
    }

    // ===== ACTIONS =====
    function clearChat() {
        chatHistory = [];
        const c = document.getElementById('chatArea');
        c.innerHTML = '';
        msgCount = tokenCount = 0;
        updateCounters();
        toast('Sohbet temizlendi');
    }

    function exportChat() {
        if (chatHistory.length === 0) { toast('Aktarilacak mesaj yok'); return; }
        const md = chatHistory.map(m => `**${m.role === 'user' ? 'SEN' : 'AI'}:**\n${m.content}`).join('\n\n---\n\n');
        const blob = new Blob([md], { type: 'text/markdown' });
        const a    = document.createElement('a');
        a.href     = URL.createObjectURL(blob);
        a.download = `sohbet-${new Date().toISOString().slice(0,10)}.md`;
        a.click();
        toast('Sohbet disa aktarildi');
    }

    function toggleStream() {
        streamMode = !streamMode;
        document.getElementById('streamToggle').querySelector('span:last-child').textContent = ' Stream: ' + (streamMode ? 'Acik' : 'Kapali');
        toast('Stream modu: ' + (streamMode ? 'Acik' : 'Kapali'));
    }

    function openSystemModal() {
        fetch(BASE_URL + '/api/tags', { headers: getHeaders() }).then(r => r.json()).then(data => {
            const list = data.models || [];
            const models = list.map(m =>
                `<div class="modal-row"><span class="modal-key">${m.name}</span><span class="modal-val">${m.size ? (m.size/1e9).toFixed(1)+'B' : ''}</span></div>`
            ).join('');
            document.getElementById('sysModalBody').innerHTML = `
                <div class="modal-row"><span class="modal-key">Sunucu</span><span class="modal-val">{{BIND_IP}}:{{OLLAMA_PORT}}</span></div>
                <div class="modal-row"><span class="modal-key">Web UI</span><span class="modal-val">{{BIND_IP}}:{{CADDY_PORT}}</span></div>
                <div class="modal-row"><span class="modal-key">API Key</span><span class="modal-val">${API_KEY ? API_KEY.slice(0,8)+'...' : 'Kapali'}</span></div>
                <div class="modal-row"><span class="modal-key">Stream</span><span class="modal-val">${streamMode ? 'Acik' : 'Kapali'}</span></div>
                <div class="modal-row"><span class="modal-key">Kurulu Modeller</span><span class="modal-val">${list.length} adet</span></div>
                ${models}
            `;
        }).catch(() => {
            document.getElementById('sysModalBody').innerHTML = '<span style="color:var(--red)">Sunucuya baglanilamadi.</span>';
        });
        document.getElementById('sysModal').classList.add('open');
    }

    function closeSysModal() {
        document.getElementById('sysModal').classList.remove('open');
    }
    document.getElementById('sysModal').addEventListener('click', e => {
        if (e.target === document.getElementById('sysModal')) closeSysModal();
    });

    // ===== MATRIX EFFECT =====
    function initMatrix() {
        const c = document.getElementById('matrix');
        const ctx = c.getContext('2d');
        let w = c.width = window.innerWidth;
        let h = c.height = window.innerHeight;
        const font = 14;
        const cols = w / font;
        const drops = Array(Math.floor(cols)).fill(1);
        const chars = '01SiberAkademiAI%$&*@#';

        function draw() {
            ctx.fillStyle = 'rgba(8, 8, 8, 0.05)';
            ctx.fillRect(0, 0, w, h);
            ctx.fillStyle = '#d4a843';
            ctx.font = font + 'px monospace';
            for (let i = 0; i < drops.length; i++) {
                const text = chars.charAt(Math.floor(Math.random() * chars.length));
                ctx.fillText(text, i * font, drops[i] * font);
                if (drops[i] * font > h && Math.random() > 0.97) drops[i] = 0;
                drops[i]++;
            }
        }
        setInterval(draw, 50);
        window.onresize = () => { w = c.width = window.innerWidth; h = c.height = window.innerHeight; };
    }
    initMatrix();

    // ===== MARKED CONFIG =====
    marked.setOptions({
        highlight: (code, lang) => {
            const l = hljs.getLanguage(lang) ? lang : 'plaintext';
            return hljs.highlight(code, { language: l }).value;
        },
        breaks: true
    });
</script>
</body>
</html>
'@

    $htmlContent = $htmlContent.Replace("{{BIND_IP}}", $global:bindIp).Replace("{{OLLAMA_PORT}}", $OLLAMA_PORT).Replace("{{CADDY_PORT}}", $CADDY_PORT).Replace("{{API_KEY}}", $apiKeyMeta).Replace("{{GPU_LABEL}}", $gpuLabel)

    $htmlPath = "$WEB_DIR\index.html"
    $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-OK "Web arayuzu olusturuldu: $htmlPath"
}

# ============================================================
#  YAPILANDIRMA KAYDET
# ============================================================
function Save-Configuration {
    Write-Section "YAPILANDIRMA KAYDEDILIYOR"

    $config = @{
        Version    = $SCRIPT_VERSION
        SavedAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        IsRemote   = $global:isRemote
        BindIp     = $global:bindIp
        OllamaPort = $OLLAMA_PORT
        CaddyPort  = $CADDY_PORT
        TunnelMode = $global:tunnelMode
        TunnelUrl  = $global:tunnelUrl
        UseApiKey  = $global:useApiKey
        ApiKey     = $global:generatedApiKey
        GPUType    = $global:gpuInfo.Type
        GPUName    = $global:gpuInfo.Name
        SystemRAM  = $global:systemInfo.RAM
        SystemDisk = $global:systemInfo.FreeDisk
        Models     = ($global:selectedModels | ForEach-Object { $_.Name })
        LogFile    = $LOG_FILE
    }

    $config | ConvertTo-Json -Depth 3 | Out-File -FilePath $CONFIG_FILE -Encoding UTF8
    Write-OK "Yapilandirma kaydedildi: $CONFIG_FILE"
    Write-Log -Level "INFO" -Message "Config saved to $CONFIG_FILE"
}

# ============================================================
#  YAPILANDIRMA YUKLE
# ============================================================
function Load-Configuration {
    if (Test-Path $CONFIG_FILE) {
        try {
            $config = Get-Content $CONFIG_FILE -Raw | ConvertFrom-Json
            $global:isRemote = $config.IsRemote
            $global:bindIp = $config.BindIp
            # Portlar degismisse guncelle
            if ($config.OllamaPort) { $script:OLLAMA_PORT = $config.OllamaPort }
            if ($config.CaddyPort) { $script:CADDY_PORT = $config.CaddyPort }
            $global:tunnelMode = $config.TunnelMode
            $global:tunnelUrl = $config.TunnelUrl
            $global:useApiKey = $config.UseApiKey
            $global:generatedApiKey = $config.ApiKey
            Write-OK "Eski yapilandirma yuklendi."
            return $true
        }
        catch { return $false }
    }
    return $false
}

# ============================================================
#  SERVIS DURUMU RAPORU
# ============================================================
function Show-ServiceStatus {
    Write-Section "SERVIS DURUM RAPORU"

    # Ollama
    $ollamaRunning = $false
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$OLLAMA_PORT/api/tags" -UseBasicParsing -TimeoutSec 3
        $ollamaRunning = $resp.StatusCode -eq 200
    }
    catch {}

    # Caddy
    $caddyRunning = $false
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$CADDY_PORT" -UseBasicParsing -TimeoutSec 3
        $caddyRunning = $resp.StatusCode -eq 200
    }
    catch { $caddyRunning = $global:caddyRunning }

    $ollamaSymbol = if ($ollamaRunning) { "[OK]" } else { "[XX]" }
    $caddySymbol = if ($caddyRunning) { "[OK]" } else { "[XX]" }
    $ollamaColor = if ($ollamaRunning) { "Green" } else { "Red" }
    $caddyColor = if ($caddyRunning) { "Green" } else { "Red" }

    Write-Host ("  " + $ollamaSymbol) -NoNewline -ForegroundColor $ollamaColor
    Write-Host " Ollama API        : http://localhost:$OLLAMA_PORT"
    Write-Host ("  " + $caddySymbol) -NoNewline -ForegroundColor $caddyColor
    Write-Host " Web Arayuzu (Caddy): http://127.0.0.1:$CADDY_PORT"

    $installed = Get-InstalledModels
    Write-Host ""
    Write-Host "  Kurulu modeller ($($installed.Count) adet):" -ForegroundColor Cyan
    foreach ($m in $installed) {
        Write-Host "    - $m" -ForegroundColor Gray
    }
}

# ============================================================
#  YEDEKLEME
# ============================================================
function Backup-Config {
    Write-Section "YEDEKLEME"

    if (-not (Test-Path $BACKUP_DIR)) {
        New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
    }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupPath = "$BACKUP_DIR\backup_$ts"
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

    if (Test-Path $CONFIG_FILE) { Copy-Item $CONFIG_FILE  "$backupPath\config.json" }
    if (Test-Path $API_KEY_FILE) { Copy-Item $API_KEY_FILE "$backupPath\apikey.txt" }
    if (Test-Path "$WEB_DIR\Caddyfile") { Copy-Item "$WEB_DIR\Caddyfile" "$backupPath\Caddyfile" }

    Write-OK "Yedek alindi: $backupPath"
    Write-Log -Level "INFO" -Message "Backup created: $backupPath"
}

# ============================================================
#  KALDIR (UNINSTALL)
# ============================================================
function Uninstall-All {
    Write-Section "KALDIR (UNINSTALL)"
    Write-Host ""
    Write-Host "  UYARI: Bu islem Ollama haric tum Siber Akademi dosyalarini siler!" -ForegroundColor Red
    Write-Host "  Devam etmek icin 'EVET' yazin: " -NoNewline -ForegroundColor Yellow
    $confirm = Read-Host
    if ($confirm -ne "EVET") {
        Write-OK "Kaldirma islemi iptal edildi."
        return
    }

    # Servisleri durdur
    if ($checkIsWindows) {
        Get-Process caddy       -ErrorAction SilentlyContinue | Stop-Process -Force
        Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force
        Get-Process ngrok       -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    else {
        foreach ($p in @("caddy", "cloudflared", "ngrok")) {
            Invoke-Expression "pkill $p 2>/dev/null; true"
        }
    }

    # Dosyalari sil
    foreach ($path in @($WEB_DIR, $LOG_DIR, $CONFIG_FILE, $API_KEY_FILE, $CADDY_EXE, $CF_EXE, $NGROK_EXE)) {
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-OK "Silindi: $path"
        }
    }

    # Windows Firewall kurallarini kaldir
    if ($checkIsWindows) {
        Remove-NetFirewallRule -DisplayName "Ollama AI Server"     -ErrorAction SilentlyContinue
        Remove-NetFirewallRule -DisplayName "Siber Akademi Web UI" -ErrorAction SilentlyContinue
        Write-OK "Firewall kurallari kaldirildi."
    }

    Write-OK "Kaldirma tamamlandi. Ollama ve modeller korundu."
    Write-Info "Ollama + modelleri de kaldirmak icin: ollama rm <model-adi> ve ardından Ollama uninstaller"
}

# ============================================================
#  LOG GOSTER
# ============================================================
function Show-RecentLogs {
    Write-Section "SON LOG KAYITLARI"
    if (Test-Path $LOG_FILE) {
        Get-Content $LOG_FILE -Tail 30 | ForEach-Object {
            $line = $_
            if ($line -match "\[ERROR\]|\[FAIL\]") { Write-Host "  $line" -ForegroundColor Red }
            elseif ($line -match "\[WARN\]") { Write-Host "  $line" -ForegroundColor Yellow }
            elseif ($line -match "\[OK\]") { Write-Host "  $line" -ForegroundColor Green }
            else { Write-Host "  $line" -ForegroundColor Gray }
        }
        Write-Info "Tam log: $LOG_FILE"
    }
    else {
        Write-Warn "Log dosyasi henuz olusturulmamis."
    }
}

# ============================================================
#  OZET VE SONUC EKRANI
# ============================================================
function Show-Summary {
    Write-Host ""
    Write-Host "  +==========================================================+" -ForegroundColor Green
    Write-Host "  |                                                          |" -ForegroundColor Green
    Write-Host "  |        KURULUM TAMAMLANDI!  SUNUCU HAZIR.               |" -ForegroundColor Green
    Write-Host "  |                                                          |" -ForegroundColor Green
    Write-Host "  +==========================================================+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  BAGLANMA BILGILERI:" -ForegroundColor Cyan
    Write-Host "  -------------------" -ForegroundColor Gray

    $localWebUrl = "http://127.0.0.1:$CADDY_PORT"
    Write-Host "  [WEB UI]      $localWebUrl" -ForegroundColor Yellow

    if ($global:isRemote) {
        try {
            $localIp = (Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.InterfaceAlias -match "Wi-Fi|Ethernet|eth|wlan" -and $_.IPAddress -notmatch "^169\." } |
                Select-Object -First 1).IPAddress
            if ($localIp) {
                Write-Host "  [LAN]         http://$localIp`:$CADDY_PORT" -ForegroundColor Yellow
            }
        }
        catch {}
    }

    if ($global:tunnelUrl -and $global:tunnelUrl -ne "Kapali") {
        Write-Host "  [GLOBAL]      $($global:tunnelUrl)" -ForegroundColor Magenta
    }

    Write-Host ""
    Write-Host "  API BILGILERI:" -ForegroundColor Cyan
    Write-Host "  -------------------" -ForegroundColor Gray
    Write-Host "  [API]         http://localhost:$OLLAMA_PORT" -ForegroundColor DarkYellow
    if ($global:useApiKey) {
        Write-Host "  [API KEY]     $($global:generatedApiKey)" -ForegroundColor DarkYellow
        Write-Host "                (Header: X-API-Key)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  DOSYALAR:" -ForegroundColor Cyan
    Write-Host "  -------------------" -ForegroundColor Gray
    Write-Host "  [LOG]         $LOG_FILE" -ForegroundColor Gray
    Write-Host "  [CONFIG]      $CONFIG_FILE" -ForegroundColor Gray
    Write-Host "  [WEB DIR]     $WEB_DIR" -ForegroundColor Gray

    Write-Host ""
    Write-Host "  GPU: $($global:gpuInfo.Type) | RAM: $($global:systemInfo.RAM) GB | Disk: $($global:systemInfo.FreeDisk) GB bos" -ForegroundColor Gray
    Write-Host ""

    # Tarayici ac
    $openUrl = if ($global:tunnelUrl -and $global:tunnelUrl -notmatch "Kapali|Alinamadi") { $global:tunnelUrl } else { $localWebUrl }
    if ($checkIsWindows) {
        try { Start-Process $openUrl } catch {}
    }
    elseif ($checkIsLinux) {
        try { Invoke-Expression "xdg-open '$openUrl' &" } catch {}
    }

    Write-Host "  Tarayici otomatik acildi." -ForegroundColor Green
    Write-Host "  Tum servisler arka planda calismaya devam ediyor." -ForegroundColor Gray
}

# ============================================================
#  ANA MENU
# ============================================================
function Show-MainMenu {
    Write-Header
    $statusText = if ($global:ollamaRunning -and $global:caddyRunning) { "AKTIF" } else { "KAPALI" }
    $statusColor = if ($statusText -eq "AKTIF") { "Green" } else { "Red" }
    
    Write-Host "  SUNUCU DURUMU: " -NoNewline -ForegroundColor White
    Write-Host "[$statusText]" -ForegroundColor $statusColor
    Write-Host ""
    Write-Host "  Lutfen bir islem secin:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] HIZLI BASLAT (Servisleri Ac)"           -ForegroundColor Green
    Write-Host "  [2] Tam Kurulum (Sifirdan Yapilandir)"      -ForegroundColor White
    Write-Host "  [3] Model Yonetimi (Indir / Sil)"           -ForegroundColor Yellow
    Write-Host "  [4] Servis Kontrol (Durdur / Durum)"        -ForegroundColor Cyan
    Write-Host "  [5] Model Benchmark Testi"                  -ForegroundColor Magenta
    Write-Host "  [6] Web Arayuzunu Yeniden Olustur"          -ForegroundColor White
    Write-Host "  [7] Yedekleme / Loglar / Diger"             -ForegroundColor Gray
    Write-Host "  [9] Kaldır (Uninstall)"                     -ForegroundColor Red
    Write-Host "  [0] Cik"                                    -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Seciminiz: " -NoNewline -ForegroundColor White
    return Read-Host
}

function Handle-ServiceMenu {
    Write-Header
    Write-Host "  Servis Yonetimi:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] Ollama'yi Baslat"       -ForegroundColor Green
    Write-Host "  [2] Ollama'yi Durdur"       -ForegroundColor Red
    Write-Host "  [3] Caddy'yi Baslat"        -ForegroundColor Green
    Write-Host "  [4] Caddy'yi Durdur"        -ForegroundColor Red
    Write-Host "  [5] Tum Servisleri Durdur"  -ForegroundColor Red
    Write-Host "  [6] Durum Raporu"           -ForegroundColor Cyan
    Write-Host "  [0] Geri"                   -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Seciminiz: " -NoNewline -ForegroundColor White
    $svc = Read-Host
    switch ($svc) {
        "1" { Start-OllamaService }
        "2" {
            if ($checkIsWindows) {
                Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force
                Write-OK "Ollama durduruldu."
            }
            else {
                Invoke-Expression "systemctl stop ollama"
                Write-OK "Ollama (systemd) durduruldu."
            }
        }
        "3" { Setup-CaddyProxy }
        "4" {
            if ($checkIsWindows) {
                Get-Process caddy -ErrorAction SilentlyContinue | Stop-Process -Force
                Write-OK "Caddy durduruldu."
            }
            else {
                Invoke-Expression "pkill caddy 2>/dev/null; true"
                Write-OK "Caddy durduruldu."
            }
        }
        "5" {
            foreach ($p in @("ollama", "caddy", "cloudflared", "ngrok")) {
                if ($checkIsWindows) {
                    Get-Process $p -ErrorAction SilentlyContinue | Stop-Process -Force
                }
                else {
                    Invoke-Expression "pkill $p 2>/dev/null; true"
                }
            }
            Write-OK "Tum servisler durduruldu."
        }
        "6" { Show-ServiceStatus }
    }
}

function Handle-ModelMenu {
    Write-Header
    Write-Host "  Model Yonetimi:" -ForegroundColor Cyan
    Write-Host "  [1] Model Indir"  -ForegroundColor Green
    Write-Host "  [2] Model Sil"   -ForegroundColor Red
    Write-Host "  [3] Kurulu Modelleri Listele" -ForegroundColor Yellow
    Write-Host "  [0] Geri"        -ForegroundColor Gray
    Write-Host "  Seciminiz: " -NoNewline -ForegroundColor White
    $mc = Read-Host
    switch ($mc) {
        "1" { Select-And-Download-Models }
        "2" { Remove-OllamaModel }
        "3" {
            $lst = Get-InstalledModels
            if ($lst.Count -gt 0) {
                Write-Host "  Kurulu modeller:" -ForegroundColor Cyan
                $lst | ForEach-Object { Write-Host "    - $_" -ForegroundColor White }
            }
            else {
                Write-Warn "Kurulu model yok."
            }
        }
    }
}

# ============================================================
#  HIZLI BASLAT (SKIP SETUP)
# ============================================================
function Run-FastStart {
    Init-Logging
    Write-Header
    Assert-AdminPrivileges
    Write-Step "HIZLI BASLATMA MODU"
    
    # Eskiyi yukle
    Load-Configuration | Out-Null
    
    # Donanim algila
    Detect-GPU
    Get-SystemInfo
    # Ensure required external tools are present and on PATH
    try { Ensure-RequiredTools } catch { Write-Warn "Ensure-RequiredTools hatasi: $($_.Exception.Message)" }
    
    # Servisleri ayarla ve baslat
    Set-OllamaEnvironment
    Start-OllamaService
    Build-WebUI
    Setup-CaddyProxy
    
    Show-ServiceStatus
    Show-Summary
    Write-OK "Sunucu hizlica hazir edildi!"
}

# ============================================================
#  FULL KURULUM AKISI
# ============================================================
function Run-FullSetup {
    Init-Logging
    Write-Header
    Write-Log -Level "INFO" -Message "Full setup basladi."

    Assert-AdminPrivileges
    Get-SystemInfo
    Detect-GPU
    # Ensure required external tools are present and on PATH
    try { Ensure-RequiredTools } catch { Write-Warn "Ensure-RequiredTools hatasi: $($_.Exception.Message)" }
    Configure-Network
    Install-Ollama
    Check-OllamaUpdate
    Set-OllamaEnvironment
    Configure-Firewall
    Start-OllamaService
    Select-And-Download-Models
    Build-WebUI
    Setup-CaddyProxy

    if ($global:tunnelMode -eq "cloudflare") {
        Start-CloudflareTunnel
    }
    elseif ($global:tunnelMode -eq "ngrok") {
        Start-NgrokTunnel
    }
    else {
        $global:tunnelUrl = if ($global:isRemote) {
            try {
                $ip = (Get-NetIPAddress -AddressFamily IPv4 |
                    Where-Object { $_.InterfaceAlias -match "Wi-Fi|Ethernet|eth|wlan" -and $_.IPAddress -notmatch "^169\." } |
                    Select-Object -First 1).IPAddress
                "http://$ip`:$CADDY_PORT"
            }
            catch { "http://127.0.0.1:$CADDY_PORT" }
        }
        else { "http://127.0.0.1:$CADDY_PORT" }
    }

    Save-Configuration
    Backup-Config
    Show-ServiceStatus
    Show-Summary
}

# ============================================================
#  ENTRY POINT - ANA PROGRAM AKISI
# ============================================================
$mainChoice = ""

# Komut satiri argumani varsa direkt tam kurulum
if ($args.Count -gt 0 -and $args[0] -eq "--full") {
    Run-FullSetup
    Pause-Screen
}

# Interaktif menu
while ($mainChoice -ne "0") {
    $mainChoice = Show-MainMenu

    switch ($mainChoice) {
        "1" {
            Run-FastStart
        }
        "2" {
            Run-FullSetup
        }
        "3" {
            Init-Logging
            Handle-ModelMenu
        }
        "4" {
            Init-Logging
            Handle-ServiceMenu
        }
        "5" {
            Init-Logging
            Write-Header
            Start-OllamaService
            Run-ModelBenchmark
        }
        "6" {
            Init-Logging
            Write-Header
            Build-WebUI
            Setup-CaddyProxy
            Write-OK "Web arayuzu yenilendi."
        }
        "7" {
            Init-Logging
            Write-Header
            Write-Host "  [1] Son Loglari Goster" -ForegroundColor Yellow
            Write-Host "  [2] Yedekleme Al" -ForegroundColor Cyan
            Write-Host "  [3] Guncelleme Kontrolu" -ForegroundColor White
            Write-Host "  [0] Geri" -ForegroundColor Gray
            $sub = Read-Host "  Secim"
            if ($sub -eq "1") { Show-RecentLogs }
            if ($sub -eq "2") { Backup-Config }
            if ($sub -eq "3") { Check-OllamaUpdate; Check-ScriptUpdate }
        }
        "9" {
            Init-Logging
            Uninstall-All
        }
        "0" {
            Write-Host "  Cikiyor..." -ForegroundColor Gray
        }
        default {
            Write-Host "  Gecersiz secim." -ForegroundColor Red
        }
    }

    if ($mainChoice -ne "0") {
        Write-Host ""
        Write-Host "  [ENTER] ile ana menuye don..." -ForegroundColor Gray
        $null = Read-Host
    }
}

Write-Host ""
Write-Host "" 
Write-Host "  Siber Akademi T.A.A AI Server - Gule gule!" -ForegroundColor Yellow
Write-Host ""

# SIG # Begin signature block
# MIIFeQYJKoZIhvcNAQcCoIIFajCCBWYCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUv7PMEPOx0qmVkVp6YEE1rPeN
# xsCgggMQMIIDDDCCAfSgAwIBAgIQFOuMJasQJ6NE7LUs0XXi6DANBgkqhkiG9w0B
# AQsFADAeMRwwGgYDVQQDDBNUb3ByYWtBaG1ldEF5ZG9nbXVzMB4XDTI2MDQwMzIx
# NDc1OVoXDTI3MDQwMzIyMDc1OVowHjEcMBoGA1UEAwwTVG9wcmFrQWhtZXRBeWRv
# Z211czCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAK8BSbqRl7kqXii8
# NNo+hfCyBwFdl4aonUg4vxt1ItrT4toK56or6KcYNDxrbxR2Tt7FccLAVzAqhx1U
# EoBORdJiRTiG+62D4UDJGyb9csSkir+9qi0zM3xRciQHrPpIh22HvovMIjAxGukq
# YfEbJEWA7S7T9SgyD0R6e6TeQ91hCkFm1oDPg4GeGeZcowDnoAJnn/Cys1pC1NMq
# Jsnpmu9Jof8G0r3BNVzB0Og4rA97QAX9Pn+as6T3TV58hM9HSQ1S1DV5AZeuPB+B
# 31XpDyL1OP6Yt4qsqHWxXd+MRXZpQgVcDPOFbw2az7INam6wdlGgh/+pwe4C93RL
# FddvXFUCAwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUF
# BwMDMB0GA1UdDgQWBBQm0Gc8b3byFkTQmPc0y9L5nPfj3zANBgkqhkiG9w0BAQsF
# AAOCAQEAFWeAfi52tICOB4xHFmD2/hG03cgrTGl0pwZrKG36PLY5Mc1TGTGMMYhI
# sJku6f4jzgBr0+Mu/uxI7shmSCLqIrKNvfVorZwZSHsz+Ru69vWo89D/0XR6XZGK
# GgBgqcGJy+Fk8p2xhU2a0ufrHBfWfFZxinlxENoHmY3+Lx7FKnDjnXXq+I6Vvuij
# QniqhHxZoGmIWm6hZwlKjh3uPs6ZQa2mQCN1WN9vRf2iexnqAsr++tAJDjKvDKIj
# 63tKZ0nFL+nknNhD+/Ez/XF06w9OppRbsXaR4erjL/ziKPKzP8HuGIDS4U05tfgT
# +ulqwd4BWtTShdgWHVQwF75pJ1P3bzGCAdMwggHPAgEBMDIwHjEcMBoGA1UEAwwT
# VG9wcmFrQWhtZXRBeWRvZ211cwIQFOuMJasQJ6NE7LUs0XXi6DAJBgUrDgMCGgUA
# oHgwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYB
# BAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0B
# CQQxFgQU+ubS6WVHIJcwF47iajWrdYG1V4cwDQYJKoZIhvcNAQEBBQAEggEAiVsn
# Mr2wmhKZiriKaXIr6aJ37blrgiAEjhQ4InRc35VR6n9WxJ/hglp6ea3BRmWTj4Yk
# EyxTtJqzxAFosn5QTxdxGjzCZpEfHpFKH62PSjCQ/xOIm0ugidBKtSSxKBN0sYlz
# kCYP+ZulFoVLB9kkcO3ALJe8NdJLynzlsDqyj8hstmKTAOq+SPRX6z+KFeHkj0y6
# UQNX6h/hmWRX0oAm4KJRzqIJjRVRpacXvbdkl0Ef2MV0Kes0sfZLePrDbe6jmIGU
# bPc7CcksRyJEOfKVl0HD0uZuhmNOQx0PTGhlX4WBwgUq48RDcwaXvFycRV4Iz7ZR
# sMILN59zxK1zRdFDqQ==
# SIG # End signature block
