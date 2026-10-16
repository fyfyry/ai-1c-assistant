# Общие функции мастера, моста и установщика ИИ-помощника 1С DeepSeek. Подключается через dot-source.
#
# Ключ API и модель DeepSeek — в deepseek.json рядом с этим файлом (его создаёт setup.cmd):
#   { "apiKey": "...", "model": "deepseek-chat", "baseUrl": "https://api.deepseek.com" }
#
# Базы описываются в bases.json рядом с этим файлом (его создаёт setup.cmd):
#   name       — любое имя базы (по нему называется рабочая папка в workspaces),
#   file       — каталог файловой базы, ИЛИ server + ref — сервер 1С и имя базы в кластере,
#   user, password — пользователь 1С с правами администратора,
#   epfFolders — необязательно: папки с внешними обработками .epf/.erf (без подпапок),
#   repository — необязательно: хранилище конфигурации { path, user, password, depth }:
#                path — каталог или tcp://сервер/хранилище, user/password — пользователь хранилища
#                (достаточно права только на чтение), depth — по скольким последним версиям
#                сохранять подробные изменения «было → стало» (по умолчанию 20).

$utf8 = New-Object Text.UTF8Encoding $false
$toolRoot = $PSScriptRoot
$basesFile = Join-Path $toolRoot 'bases.json'

if (-not ('AI1C.Anonymizer' -as [type])) {
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $toolRoot 'ai-tools.cs'), [Text.Encoding]::UTF8)) `
        -ReferencedAssemblies System.Core, System.Xml, System.Xml.Linq
}

function Get-Bases {
    if (-not (Test-Path $basesFile)) { return }
    $config = Get-Content $basesFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($b in $config.bases) {
        if (-not $b.name) { throw 'В bases.json у базы не указано имя (name)' }
        if (-not $b.file -and -not ($b.server -and $b.ref)) { throw "В bases.json у базы «$($b.name)» нужно указать file или server + ref" }
        $b
    }
}

function Save-Bases($bases) {
    $json = [pscustomobject]@{ bases = @($bases) } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($basesFile, $json, $utf8)
}

function Find-Base($name) {
    $base = Get-Bases | Where-Object { $_.name -eq $name }
    if (-not $base) { throw "База «$name» не найдена в bases.json" }
    $base
}

# Так же, как ДопустимоеИмяФайла в общем модуле ДС_ЧатСервер.
function Get-SafeName($name) {
    $safe = ($name -replace '[\\/:*?"<>|]', '_').Trim()
    if ($safe) { $safe } else { 'Обработка' }
}

# Каталог обмена с 1С; правила совпадают с функцией КаталогОбмена общего модуля ДС_ЧатСервер.
function Get-ExchangeDir($base) {
    if ($base.file) { return Join-Path $base.file 'ai-chat-deepseek' }
    Join-Path 'C:\ProgramData\1C-AI-DeepSeek' (Get-SafeName ("$($base.server)_$($base.ref)".ToLower()))
}

# Рабочая папка базы: выгрузки конфигурации и история хранилища — их читает модель.
function Get-Workspace($base) {
    $dir = Join-Path (Join-Path $toolRoot 'workspaces') (Get-SafeName $base.name)
    New-Item -ItemType Directory -Force $dir | Out-Null
    $dir
}

# Служебная папка базы, недоступная модели: таблица обезличивания, зеркало хранилища.
function Get-PrivateDir($base) {
    $dir = Join-Path (Join-Path $toolRoot 'private') (Get-SafeName $base.name)
    New-Item -ItemType Directory -Force $dir | Out-Null
    $dir
}

# Обезличиватель базы: метки персональных данных общие для всех чатов и истории хранилища базы.
function Get-Anonymizer($base) {
    if (-not $script:anonymizers) { $script:anonymizers = @{} }
    if (-not $script:anonymizers.ContainsKey($base.name)) {
        $script:anonymizers[$base.name] = New-Object AI1C.Anonymizer (Join-Path (Get-PrivateDir $base) 'pii-map.txt')
    }
    $script:anonymizers[$base.name]
}

# Обезличивает модули в выгрузках, изменённые с прошлого раза. Первый проход по большой
# конфигурации занимает пару минут, дальше обрабатываются только обновлённые файлы.
function Protect-Dump($base, $workspace) {
    $stampFile = Join-Path (Get-PrivateDir $base) 'dump-protected.txt'
    $since = [datetime]::MinValue
    if (Test-Path $stampFile) { $since = [datetime]::Parse((Get-Content $stampFile -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture) }
    $started = Get-Date
    $pii = Get-Anonymizer $base
    $pii.Begin()
    try {
        $count = 0
        foreach ($dir in 'cfdump', 'cfdump-ext', 'cfdump-epf') {
            $count += $pii.ProtectFiles((Join-Path $workspace $dir), '*.bsl', $since)
        }
    } finally {
        $pii.End()
    }
    [IO.File]::WriteAllText($stampFile, $started.ToString('o'), $utf8)
    $count
}

# Параметры подключения к хранилищу конфигурации для командной строки конфигуратора.
function Get-RepoArgs($base) {
    $repo = $base.repository
    $s = "/ConfigurationRepositoryF `"$($repo.path)`""
    if ($repo.user) { $s += " /ConfigurationRepositoryN `"$($repo.user)`"" }
    if ($repo.password) { $s += " /ConfigurationRepositoryP `"$($repo.password)`"" }
    $s
}

# Запускает фоновую синхронизацию истории хранилища (repo-sync.ps1), если она ещё не идёт.
function Start-RepoSync($base) {
    if (-not $base.repository -or -not $base.repository.path) { return }
    Start-Process (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -WorkingDirectory $toolRoot `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $toolRoot 'repo-sync.ps1')`" -Base `"$($base.name)`""
}

# Параметры подключения конфигуратора; $fileOverride — каталог копии файловой базы.
function Get-ConnArgs($base, $fileOverride) {
    $conn = if ($fileOverride) { "/F `"$fileOverride`"" }
            elseif ($base.file) { "/F `"$($base.file)`"" }
            else { "/S `"$($base.server)\$($base.ref)`"" }
    if ($base.user) { $conn += " /N `"$($base.user)`"" }
    if ($base.password) { $conn += " /P `"$($base.password)`"" }
    "DESIGNER $conn /DisableStartupDialogs /DisableStartupMessages"
}

$platformFile = Join-Path $toolRoot 'platform.txt'

# 1cv8.exe по указанному пути: сам файл, папка bin, папка версии или папка установки (…\1cv8).
function Get-1CFromPath($path) {
    $path = ([string]$path).Trim().Trim('"').TrimEnd('\')
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    if (-not (Get-Item -LiteralPath $path).PSIsContainer) {
        if ((Split-Path $path -Leaf) -eq '1cv8.exe') { Get-Item -LiteralPath $path }
        return
    }
    foreach ($exe in (Join-Path $path '1cv8.exe'), (Join-Path $path 'bin\1cv8.exe')) {
        if (Test-Path -LiteralPath $exe) { Get-Item -LiteralPath $exe }
    }
    Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'bin\1cv8.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-Item -LiteralPath $_ }
}

# Самая новая установленная платформа 1С. Где искать: путь из platform.txt (его пишет мастер,
# если платформа стоит в нестандартной папке), Program Files, папки установки из настроек
# стартера 1С (1cestart.cfg) и из списка установленных программ Windows.
function Find-1C {
    $places = @(
        if (Test-Path $platformFile) { [IO.File]::ReadAllText($platformFile) }
        "$env:ProgramFiles\1cv8"
        if (${env:ProgramFiles(x86)}) { "${env:ProgramFiles(x86)}\1cv8" }
        foreach ($cfg in "$env:APPDATA\1C\1CEStart\1cestart.cfg", "$env:ProgramData\1C\1CEStart\1cestart.cfg") {
            if (Test-Path $cfg) {
                [IO.File]::ReadAllLines($cfg) | Where-Object { $_ -match '^\s*InstalledLocation\s*=' } | ForEach-Object { ($_ -split '=', 2)[1] }
            }
        }
        Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '^1[CС]:Предприятие 8|^1C:Enterprise 8' -and $_.InstallLocation } | ForEach-Object { $_.InstallLocation }
    )
    $found = @($places | ForEach-Object { Get-1CFromPath $_ }) | Sort-Object FullName -Unique |
        Sort-Object { $v = $null; if ([version]::TryParse($_.Directory.Parent.Name, [ref]$v)) { $v } else { [version]'0.0' } } -Descending
    if (-not $found) { throw 'Платформа 1С не найдена. Запустите setup.cmd: мастер спросит, где она установлена.' }
    $found[0].FullName
}

$deepSeekConfigFile = Join-Path $toolRoot 'deepseek.json'

# Настройки DeepSeek: ключ API, модель и адрес API.
function Get-DeepSeekConfig {
    if (-not (Test-Path $deepSeekConfigFile)) { throw 'Нет файла deepseek.json с ключом API — запустите setup.cmd.' }
    $c = Get-Content $deepSeekConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $c.apiKey) { throw 'В deepseek.json не указан ключ API (apiKey) — запустите setup.cmd.' }
    [pscustomobject]@{
        apiKey  = -join (([string]$c.apiKey).ToCharArray() | Where-Object { [int]$_ -gt 32 -and [int]$_ -lt 127 })
        model   = if ($c.model) { [string]$c.model } else { 'deepseek-chat' }
        baseUrl = if ($c.baseUrl) { [string]$c.baseUrl } else { 'https://api.deepseek.com' }
    }
}

function Save-DeepSeekConfig($config) {
    [IO.File]::WriteAllText($deepSeekConfigFile, ($config | ConvertTo-Json), $utf8)
}
# Запущен ли мост (в любом окне).
function Test-BridgeRunning {
    [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*$(Join-Path $toolRoot 'ai-bridge.ps1')*" })
}

function Read-Log($log) {
    if (-not (Test-Path $log)) { return '' }
    $content = Get-Content $log -Raw -Encoding UTF8
    if ($content) { $content.Trim() } else { '' }
}

# --- Сравнение выгрузок: история хранилища (repo-sync.ps1) и журнал изменений базы (мост) ---

$textExtensions = '.bsl', '.xml', '.txt', '.html', '.htm', '.json', '.css', '.js'
$maxDiffFileSize = 3MB

# Папка выгрузки объекта по имени из -getChanges (CommonModule.Имя → CommonModules\Имя).
function Get-ObjectPaths($fullName) {
    $parts = $fullName.Split('.')
    if ($parts[0] -eq 'Configuration') { return 'Configuration.xml', 'Ext' }
    if ($parts.Count -lt 2) { return @() }
    $type = $parts[0]
    $folder = if ($type -eq 'FilterCriterion') { 'FilterCriteria' }
              elseif ($type -like 'ChartOf*') { 'ChartsOf' + $type.Substring(7) }
              elseif ($type -match 's$') { $type + 'es' }
              else { $type + 's' }
    "$folder\$($parts[1]).xml", "$folder\$($parts[1])"
}

function Copy-Paths($fromRoot, $relPaths, $toRoot) {
    foreach ($rel in $relPaths) {
        $src = Join-Path $fromRoot $rel
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $toRoot $rel
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item -LiteralPath $src $dst -Recurse -Force
    }
}

function Get-RelativeFiles($root) {
    if (-not (Test-Path $root)) { return @() }
    Get-ChildItem $root -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) }
}

# Сравнивает копии объектов до и после версии. Возвращает текст diff и список изменённых файлов.
function Compare-Snapshots($before, $after) {
    $files = @(Get-RelativeFiles $before) + @(Get-RelativeFiles $after) | Sort-Object -Unique
    $diff = New-Object Text.StringBuilder
    $changedFiles = @()
    foreach ($rel in $files) {
        # Служебный файл версий выгрузки меняется вместе с любым объектом — в сравнении он только шум.
        if ((Split-Path $rel -Leaf) -eq 'ConfigDumpInfo.xml') { continue }
        $b = Join-Path $before $rel
        $a = Join-Path $after $rel
        $bExists = Test-Path -LiteralPath $b
        $aExists = Test-Path -LiteralPath $a
        $status = if (-not $bExists) { 'добавлен' } elseif (-not $aExists) { 'удалён' } else { 'изменён' }
        if ($bExists -and $aExists) {
            $bBytes = [IO.File]::ReadAllBytes($b)
            $aBytes = [IO.File]::ReadAllBytes($a)
            if ($bBytes.Length -eq $aBytes.Length -and [Convert]::ToBase64String($bBytes) -eq [Convert]::ToBase64String($aBytes)) { continue }
        }
        $changedFiles += "  $rel — $status"
        $ext = [IO.Path]::GetExtension($rel).ToLower()
        $size = [Math]::Max($(if ($bExists) { (Get-Item -LiteralPath $b).Length } else { 0 }), $(if ($aExists) { (Get-Item -LiteralPath $a).Length } else { 0 }))
        if ($textExtensions -notcontains $ext) {
            [void]$diff.Append("### $rel — двоичный файл $status`n")
            continue
        }
        if ($size -gt $maxDiffFileSize) {
            [void]$diff.Append("### $rel — файл $status (больше $($maxDiffFileSize / 1MB) МБ, построчное сравнение не строилось)`n")
            continue
        }
        $bText = if ($bExists) { [IO.File]::ReadAllText($b, [Text.Encoding]::UTF8) } else { '' }
        $aText = if ($aExists) { [IO.File]::ReadAllText($a, [Text.Encoding]::UTF8) } else { '' }
        [void]$diff.Append([AI1C.Differ]::Unified($bText, $aText, "было/$($rel.Replace('\', '/'))", "стало/$($rel.Replace('\', '/'))"))
    }
    @{ diff = $diff.ToString(); files = $changedFiles }
}
