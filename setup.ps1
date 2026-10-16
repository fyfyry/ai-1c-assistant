# Мастер установки ИИ-помощника 1С: проверяет 1С и Claude, подключает выбранную базу,
# ставит мост в автозагрузку Windows и запускает его. Запуск: setup.cmd.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ai-common.ps1')
[Console]::OutputEncoding = $utf8
$Host.UI.RawUI.WindowTitle = 'ИИ-помощник 1С — установка'

# Файлы из интернета или из архива Windows помечает как скачанные — снимаем пометку.
Get-ChildItem $toolRoot -Recurse -File | Unblock-File

function Write-Step($text) { Write-Host ''; Write-Host $text -ForegroundColor Yellow }
function Write-Ok($text) { Write-Host "  ✓ $text" -ForegroundColor Green }

function Test-ClaudeLogin($claude) {
    $out = & $claude -p 'Ответь одним словом: ок' --output-format json 2>$null
    try { $r = ($out -join '') | ConvertFrom-Json } catch { return $false }
    -not $r.is_error
}

# Значение параметра строки соединения вида Имя="Значение";
function Get-ConnValue($connect, $name) {
    foreach ($part in $connect -split ';') {
        $kv = $part -split '=', 2
        if ($kv.Count -eq 2 -and $kv[0].Trim() -eq $name) { return $kv[1].Trim().Trim('"') }
    }
    ''
}

# Базы из списка стартового окна 1С.
function Get-1CBaseList {
    $file = Join-Path $env:APPDATA '1C\1CEStart\ibases.v8i'
    if (-not (Test-Path $file)) { return }
    $name = $null
    foreach ($line in Get-Content $file -Encoding UTF8) {
        if ($line -match '^\[(.+)\]$') { $name = $Matches[1]; continue }
        if ($name -and $line -match '^Connect=(.*)$') {
            $connect = $Matches[1]
            [pscustomobject]@{
                name   = $name
                file   = Get-ConnValue $connect 'File'
                server = Get-ConnValue $connect 'Srvr'
                ref    = Get-ConnValue $connect 'Ref'
            }
            $name = $null
        }
    }
}

function Find-Configured($candidate) {
    Get-Bases | Where-Object {
        ($candidate.file -and $_.file -and $_.file.TrimEnd('\') -eq $candidate.file.TrimEnd('\')) -or
        ($candidate.server -and $_.server -eq $candidate.server -and $_.ref -eq $candidate.ref)
    } | Select-Object -First 1
}

function Install-Autostart {
    $startup = [Environment]::GetFolderPath('Startup')
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path $startup 'ИИ-помощник 1С — мост.lnk'))
    $link.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $link.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$(Join-Path $toolRoot 'ai-bridge.ps1')`""
    $link.WorkingDirectory = $toolRoot
    $link.Description = 'Мост между чатом ИИ-помощника в 1С и Claude'
    $link.Save()
}

function Start-Bridge {
    if (Test-BridgeRunning) { return }
    Start-Process (Join-Path $PSHOME 'powershell.exe') -WorkingDirectory $toolRoot -WindowStyle Minimized `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $toolRoot 'ai-bridge.ps1')`""
}

function Connect-Base {
    Write-Step 'Выберите базу 1С'
    $list = @(Get-1CBaseList)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $b = $list[$i]
        $where = if ($b.file) { $b.file } elseif ($b.server) { "сервер $($b.server), база $($b.ref)" } else { 'веб-база — не поддерживается' }
        $mark = if (Find-Configured $b) { '  [уже подключена]' } else { '' }
        Write-Host ("  {0,2}. {1} — {2}{3}" -f ($i + 1), $b.name, $where, $mark)
    }
    Write-Host '   0. Указать путь к файловой базе вручную'
    $choice = Read-Host 'Номер базы'

    if ($choice -eq '0') {
        $path = (Read-Host 'Каталог файловой базы (где лежит 1Cv8.1CD)').Trim('"', ' ')
        if (-not (Test-Path (Join-Path $path '1Cv8.1CD'))) { throw "В каталоге «$path» нет файла 1Cv8.1CD." }
        $candidate = [pscustomobject]@{ name = Split-Path $path -Leaf; file = $path; server = ''; ref = '' }
    } else {
        $index = 0
        if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $list.Count) { throw 'Нет базы с таким номером.' }
        $candidate = $list[$index - 1]
        if (-not $candidate.file -and -not $candidate.server) { throw 'Веб-базы (через веб-сервер) не поддерживаются.' }
        if ($candidate.server) {
            Write-Host '  Клиент-серверная база работает, только если сервер 1С запущен на этом же компьютере.' -ForegroundColor DarkYellow
        }
    }

    $installArgs = @{}
    $configured = Find-Configured $candidate
    if ($configured) {
        Write-Host "  База уже подключена как «$($configured.name)» — обновлю расширение и выгрузку."
        $installArgs.Base = $configured.name
    } else {
        $user = Read-Host 'Пользователь 1С с правами администратора (Enter — если пользователей в базе нет)'
        $password = ''
        if ($user) {
            $secure = Read-Host 'Пароль (Enter — если без пароля)' -AsSecureString
            $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        }
        $epf = (Read-Host 'Папка с вашими внешними обработками .epf/.erf (Enter — пропустить)').Trim('"', ' ')

        $installArgs.Name = $candidate.name
        $installArgs.User = $user
        $installArgs.Password = $password
        if ($epf) { $installArgs.EpfFolders = @($epf) }
        if ($candidate.file) { $installArgs.File = $candidate.file }
        else { $installArgs.Server = $candidate.server; $installArgs.Ref = $candidate.ref }
    }

    # Хранилище конфигурации: по нему помощник отвечает, кто, что и когда менял.
    $hint = if ($configured -and $configured.repository -and $configured.repository.path) { "Enter — оставить $($configured.repository.path)" } else { 'Enter — база не подключена к хранилищу' }
    $repoPath = (Read-Host "Хранилище конфигурации: каталог или tcp://сервер/имя ($hint)").Trim('"', ' ')
    if ($repoPath) {
        $installArgs.RepoPath = $repoPath
        $installArgs.RepoUser = Read-Host 'Пользователь хранилища (достаточно права только на чтение; лучше завести отдельного)'
        if ($installArgs.RepoUser) {
            $secure = Read-Host 'Пароль пользователя хранилища (Enter — если без пароля)' -AsSecureString
            $installArgs.RepoPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        }
        $depth = Read-Host 'По скольким последним версиям хранить подробные изменения «было → стало» (Enter — 20)'
        if ($depth -match '^\d+$') { $installArgs.RepoDepth = [int]$depth }
    }

    Write-Host ''
    Write-Host '  Закройте эту базу в 1С (и Предприятие, и Конфигуратор) и нажмите Enter.' -ForegroundColor Cyan
    Read-Host | Out-Null
    & (Join-Path $toolRoot 'install-extension.ps1') @installArgs
}

# --- Мастер ---
Write-Host 'Установка ИИ-помощника 1С' -ForegroundColor Cyan
Write-Host "Папка помощника: $toolRoot"
Write-Host 'Не переносите эту папку после установки: в ней хранятся настройки и выгрузки баз.'

try {
    Write-Step '1. Платформа 1С'
    $oneC = $null
    try { $oneC = Find-1C } catch {}
    while (-not $oneC) {
        Write-Host '  Платформа 1С не найдена в стандартных папках.' -ForegroundColor DarkYellow
        Write-Host '  Укажите, где она установлена: папку с версиями (например D:\1cv8), папку версии'
        Write-Host '  (D:\1cv8\8.3.27.1989), её папку bin или сам файл 1cv8.exe.'
        $path = (Read-Host '  Путь').Trim('"', ' ')
        $exe = @(Get-1CFromPath $path) | Select-Object -First 1
        if ($exe) {
            [IO.File]::WriteAllText($platformFile, $exe.FullName, $utf8)
            $oneC = Find-1C
        } else {
            Write-Host "  В «$path» нет 1cv8.exe." -ForegroundColor Red
        }
    }
    Write-Ok $oneC

    Write-Step '2. Claude Code'
    $claude = Find-Claude
    Write-Ok $claude
    while (-not (Test-ClaudeLogin $claude)) {
        Write-Host '  Claude Code ещё не авторизован на этом компьютере.' -ForegroundColor DarkYellow
        Write-Host '  Сейчас откроется окно Claude Code: выберите тему, выполните вход (команда /login,'
        Write-Host '  войдите в браузере своим аккаунтом Claude), затем введите /exit — окно закроется.'
        Read-Host '  Нажмите Enter, чтобы открыть окно входа' | Out-Null
        Start-Process $claude -Wait
    }
    Write-Ok 'вход выполнен'

    do {
        try {
            Connect-Base
        } catch {
            Write-Host "  Ошибка: $_" -ForegroundColor Red
        }
        $more = Read-Host 'Подключить ещё одну базу? (д/н)'
    } while ($more -match '^[дДyY]')

    Write-Step '3. Мост'
    Install-Autostart
    Write-Ok 'добавлен в автозагрузку Windows'
    Start-Bridge
    Write-Ok 'запущен (свёрнутое окно «ИИ-помощник 1С — мост»)'

    Write-Host ''
    Write-Host 'Готово! Откройте базу в 1С:Предприятии и нажмите раздел «ИИ-помощник».' -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "Установка прервана: $_" -ForegroundColor Red
}
