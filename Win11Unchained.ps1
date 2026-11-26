#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Обновление Windows 10 -> Windows 11 «на месте» без проверок TPM 2.0 / CPU.

.DESCRIPTION
    1. Показывает сведения о железе и проверяет базовые условия.
    2. Прописывает ключи реестра, снимающие проверки совместимости.
    3. Копирует содержимое ISO в C:\Win11_Upgrade и обнуляет sources\appraiserres.dll.
    4. Запускает setup.exe с сохранением файлов и приложений.

.PARAMETER IsoPath
    Путь к ISO Windows 11. Если не указан, откроется окно выбора файла.

.PARAMETER ProductServer
    Запускать setup.exe с ключом /product server (запасной обход проверок).

.PARAMETER Cleanup
    Удалить ключи реестра, добавленные скриптом, и папку C:\Win11_Upgrade.
    Запускать после завершения обновления.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\Upgrade-Win11.ps1

.EXAMPLE
    .\Upgrade-Win11.ps1 -IsoPath D:\Win11.iso -ProductServer

.EXAMPLE
    .\Upgrade-Win11.ps1 -Cleanup
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [switch]$ProductServer,
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[x] $m" -ForegroundColor Red }

$moSetup = 'HKLM:\SYSTEM\Setup\MoSetup'
$labCfg  = 'HKLM:\SYSTEM\Setup\LabConfig'
$labKeys = 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassCPUCheck', 'BypassRAMCheck', 'BypassStorageCheck'
$work    = "$env:SystemDrive\Win11_Upgrade"

# ---------- Режим очистки ----------
if ($Cleanup) {
    Info "Удаляю ключи реестра, добавленные скриптом..."
    Remove-ItemProperty -Path $moSetup -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -ErrorAction SilentlyContinue
    foreach ($n in $labKeys) { Remove-ItemProperty -Path $labCfg -Name $n -ErrorAction SilentlyContinue }
    if (Test-Path $work) {
        Info "Удаляю $work ..."
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    Ok "Очистка завершена."
    return
}

$log = Join-Path $env:TEMP 'Upgrade-Win11.log'
try { Start-Transcript -Path $log -Append | Out-Null } catch { }

try {
    Add-Type -AssemblyName System.Windows.Forms
    if (-not ('Win32.CpuInfo' -as [type])) {
        Add-Type -Namespace Win32 -Name CpuInfo -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool IsProcessorFeaturePresent(uint feature);
'@
    }

    Write-Host "`n=== Windows 10 -> 11 без проверок TPM 2.0 / CPU ===`n" -ForegroundColor Magenta

    # ---------- 0. Проверки системы ----------
    $os    = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber

    if ($build -ge 22000) {
        Warn "На этом компьютере уже установлена Windows 11 (сборка $build). Обновлять нечего."
        return
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Fail "Установлена 32-разрядная Windows. Windows 11 существует только в 64-разрядной версии."
        return
    }
    if ($build -lt 19041) {
        Warn "Сборка Windows 10 ($build) старше 2004. Сначала обновите Windows 10 до 22H2 через Центр обновления."
    }

    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
    $ramGB   = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    $sse42   = [Win32.CpuInfo]::IsProcessorFeaturePresent(38)

    $tpmInfo = 'не найден'
    try {
        $t = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        if ($t) { $tpmInfo = "версия $(($t.SpecVersion -split ',')[0])" }
    } catch { }

    try   { $sb = if (Confirm-SecureBootUEFI) { 'включён' } else { 'выключен' } }
    catch { $sb = 'недоступен (Legacy BIOS или не поддерживается)' }

    Info "Сведения о системе:"
    Write-Host "    Windows 10, сборка : $build"
    Write-Host "    Процессор          : $cpuName"
    Write-Host "    ОЗУ                : $ramGB ГБ"
    Write-Host "    TPM                : $tpmInfo"
    Write-Host "    Secure Boot        : $sb"
    Write-Host "    SSE4.2             : $(if ($sse42) { 'есть' } else { 'НЕТ' })`n"

    if (-not $sse42) {
        Warn "Процессор не поддерживает SSE4.2. Windows 11 24H2 и новее на нём не загрузится."
        if ((Read-Host "Всё равно продолжить? (y/n)") -ne 'y') { return }
    }
    if ($ramGB -lt 3.5) {
        Warn "Мало оперативной памяти ($ramGB ГБ). Windows 11 официально требует 4 ГБ."
    }

    Warn "Сделайте резервную копию важных данных до продолжения."
    Warn "Microsoft не гарантирует поддержку и обновления на неподдерживаемом железе."
    if ((Read-Host "Продолжить? (y/n)") -ne 'y') { return }

    # ---------- 1. Реестр ----------
    Info "Прописываю ключи реестра..."
    foreach ($p in $moSetup, $labCfg) {
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    }
    Set-ItemProperty -Path $moSetup -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Value 1 -Type DWord
    foreach ($n in $labKeys) { Set-ItemProperty -Path $labCfg -Name $n -Value 1 -Type DWord }
    Ok "Реестр настроен."

    # ---------- 2. Выбор ISO ----------
    if (-not $IsoPath) {
        Info "Выберите ISO-образ Windows 11 (microsoft.com/software-download/windows11)."
        try {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = 'ISO образ (*.iso)|*.iso'
            $dlg.Title  = 'Выберите Windows 11 ISO'
            if ($dlg.ShowDialog() -ne 'OK') { Warn "ISO не выбран. Выход."; return }
            $IsoPath = $dlg.FileName
        } catch {
            $IsoPath = (Read-Host "Окно выбора недоступно. Введите полный путь к ISO").Trim('"')
        }
    }
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf) -or $IsoPath -notmatch '\.iso$') {
        Fail "Файл ISO не найден или имеет неверное расширение: $IsoPath"
        return
    }
    $IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path

    # ---------- 3. Свободное место ----------
    $free = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free / 1GB
    if ($free -lt 25) {
        Fail ("Свободно только {0:N1} ГБ на системном диске. Нужно минимум ~25 ГБ." -f $free)
        return
    }

    # ---------- 4. Копирование содержимого ISO ----------
    Info "Монтирую ISO и копирую файлы в $work (несколько минут)..."
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Path $work | Out-Null

    $mounted = $false
    try {
        Mount-DiskImage -ImagePath $IsoPath | Out-Null
        $mounted = $true

        $letter = $null
        for ($i = 0; $i -lt 15 -and -not $letter; $i++) {
            $vol = Get-DiskImage -ImagePath $IsoPath | Get-Volume
            if ($vol -and $vol.DriveLetter) { $letter = $vol.DriveLetter } else { Start-Sleep -Seconds 1 }
        }
        if (-not $letter) { throw "Не удалось получить букву диска смонтированного ISO." }

        $src = "${letter}:\"
        $hasImage = (Test-Path "${src}sources\install.wim") -or (Test-Path "${src}sources\install.esd")
        if (-not (Test-Path "${src}setup.exe") -or -not $hasImage) {
            throw "Это не похоже на установочный ISO Windows (нет setup.exe или install.wim/esd)."
        }

        robocopy $src $work /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Ошибка копирования (robocopy, код $LASTEXITCODE)." }
    } finally {
        if ($mounted) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
    }
    if (-not (Test-Path "$work\setup.exe")) { throw "После копирования не найден setup.exe." }
    Ok "Файлы скопированы."

    # ---------- 5. Отключение проверки совместимости ----------
    Info "Заменяю appraiserres.dll пустым файлом..."
    $dll = Join-Path $work 'sources\appraiserres.dll'
    if (Test-Path $dll) { Remove-Item $dll -Force }
    New-Item -ItemType File -Path $dll -Force | Out-Null
    Ok "Проверка совместимости отключена."

    # ---------- 6. Запуск установки ----------
    $setupArgs = @('/auto', 'upgrade', '/compat', 'ignorewarning', '/migratedrivers', 'all', '/dynamicupdate', 'disable', '/eula', 'accept')
    if ($ProductServer) { $setupArgs = @('/product', 'server') + $setupArgs }

    Info "Запускаю установку Windows 11 с сохранением файлов и приложений..."
    Start-Process -FilePath "$work\setup.exe" -ArgumentList $setupArgs
    Ok "Установщик запущен. Компьютер перезагрузится несколько раз, не выключайте его."
    Info "После завершения можно запустить: .\Upgrade-Win11.ps1 -Cleanup"
}
catch {
    Fail "Ошибка: $($_.Exception.Message)"
    Warn "Журнал скрипта: $log"
    Warn "Журналы установщика: C:\`$WINDOWS.~BT\Sources\Panther"
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}
