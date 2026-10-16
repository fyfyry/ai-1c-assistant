# Синхронизация истории хранилища конфигурации для ИИ-помощника. Мост запускает её в фоне
# при каждом открытии чата; второй экземпляр для той же базы сразу завершается.
#   repo-sync.ps1 -Base "имя базы из bases.json"
# Результат — папка workspaces\<база>\repo-history, её читает модель:
#   versions.txt     — все версии хранилища: номер, дата, автор, комментарий, изменённые объекты;
#   vNNNNNN\info.txt — то же по одной версии и список изменённых файлов;
#   vNNNNNN\changes.diff — что именно изменилось: было → стало (unified diff), для последних версий.
# Версии по очереди загружаются в отдельную пустую базу-зеркало private\<база>\repo-mirror и
# выгружаются в файлы. Рабочая база к хранилищу не подключается, достаточно пользователя
# хранилища с правом только на чтение. Авторы и персональные данные в истории обезличиваются.
param([Parameter(Mandatory = $true)][string]$Base)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ai-common.ps1')

$baseInfo = Find-Base $Base
if (-not $baseInfo.repository -or -not $baseInfo.repository.path) { exit }

$mutex = [Threading.Mutex]::new($false, 'Local\AI1CRepoDeepSeek_' + (Get-SafeName $Base))
if (-not $mutex.WaitOne(0)) { exit }

$private = Get-PrivateDir $baseInfo
$mirror = Join-Path $private 'repo-mirror'
$mirrorIb = Join-Path $mirror 'ib'
$mirrorDump = Join-Path $mirror 'dump'
$work = Join-Path $mirror 'work'
$stateFile = Join-Path $private 'repo-state.json'
$logFile = Join-Path $private 'repo-sync.log'
$history = Join-Path (Get-Workspace $baseInfo) 'repo-history'
$depth = if ($baseInfo.repository.depth) { [int]$baseInfo.repository.depth } else { 20 }
$exe = Find-1C
$pii = Get-Anonymizer $baseInfo

function Write-Log($text) {
    [IO.File]::AppendAllText($logFile, ('[{0:dd.MM.yyyy HH:mm:ss}] {1}' -f (Get-Date), $text) + "`r`n", $utf8)
}

function Read-State {
    if (Test-Path $stateFile) { return Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    [pscustomobject]@{ lastReported = 0; lastDiffed = -1; latest = 0; error = ''; updated = '' }
}

function Save-State($state) {
    $state.updated = (Get-Date).ToString('dd.MM.yyyy HH:mm')
    [IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json), $utf8)
}

# Конфигуратор на базе-зеркале; -Repo добавляет подключение к хранилищу.
function Invoke-Mirror($argString, $title, [switch]$Repo) {
    $log = Join-Path $work 'designer.log'
    if (Test-Path $log) { Remove-Item $log }
    $conn = "DESIGNER /F `"$mirrorIb`" /DisableStartupDialogs /DisableStartupMessages"
    if ($Repo) { $conn += ' ' + (Get-RepoArgs $baseInfo) }
    $p = Start-Process $exe -ArgumentList "$conn $argString /Out `"$log`"" -Wait -PassThru -WindowStyle Hidden
    $text = Read-Log $log
    if ($p.ExitCode -ne 0) { throw "${title}: $text" }
    $text
}

function Reset-Dir($dir) {
    if (Test-Path $dir) { [IO.Directory]::Delete($dir, $true) }
    New-Item -ItemType Directory -Force $dir | Out-Null
}

# Версии хранилища начиная с $from по отчёту конфигуратора. Отчёт — табличный документ (MXL),
# из него по порядку берём строки ячеек: подписи полей («Версия:», «Пользователь:» ...) и значения.
function Get-RepoVersions($from) {
    $file = Join-Path $work 'report.mxl'
    if (Test-Path $file) { Remove-Item $file }
    Invoke-Mirror "/ConfigurationRepositoryReport `"$file`" -NBegin $from" 'Отчёт по версиям хранилища' -Repo | Out-Null
    if (-not (Test-Path $file)) { return @() }
    $text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    $labels = 'Версия:', 'Пользователь:', 'Дата создания:', 'Время создания:', 'Версия конфигурации:',
              'Комментарий:', 'Добавлены:', 'Изменены:', 'Удалены:', 'Метка:', 'Комментарий метки:'
    $versions = New-Object Collections.ArrayList
    $current = $null
    $field = $null
    foreach ($m in [regex]::Matches($text, '\{"#","((?:[^"]|"")*)"\}')) {
        $s = $m.Groups[1].Value.Replace('""', '"')
        if ($labels -contains $s) {
            $field = $s
            if ($s -eq 'Версия:') {
                $current = [pscustomobject]@{ number = 0; user = ''; date = ''; time = ''; comment = ''
                                              added = @(); changed = @(); deleted = @() }
                [void]$versions.Add($current)
            }
            continue
        }
        if (-not $current) { continue }
        switch ($field) {
            'Версия:'         { $current.number = [int]$s }
            'Пользователь:'   { $current.user = $s }
            'Дата создания:'  { $current.date = $s }
            'Время создания:' { $current.time = $s }
            'Комментарий:'    { $current.comment = (($current.comment, $s) | Where-Object { $_ }) -join "`n" }
            'Добавлены:'      { $current.added += $s }
            'Изменены:'       { $current.changed += $s }
            'Удалены:'        { $current.deleted += $s }
        }
    }
    @($versions | Where-Object { $_.number -ge $from })
}

function Format-Objects($title, $objects, $max) {
    if (-not $objects) { return $null }
    $list = @($objects | Select-Object -First $max) -join ', '
    if ($objects.Count -gt $max) { $list += " и ещё $($objects.Count - $max)" }
    "${title}: $list"
}

# Описание версии; вызывается между $pii.Begin() и $pii.End().
function Format-Version($v, $maxObjects) {
    $parts = @(
        "Версия $($v.number)"
        "$($v.date) $($v.time)"
        "автор $($pii.Token('РАЗРАБОТЧИК', $v.user))"
        "комментарий: «$($pii.Protect(($v.comment -replace '\s+', ' ').Trim()))»"
        Format-Objects 'добавлены' $v.added $maxObjects
        Format-Objects 'изменены' $v.changed $maxObjects
        Format-Objects 'удалены' $v.deleted $maxObjects
    ) | Where-Object { $_ }
    $parts -join ' · '
}

# Загружает версию хранилища в зеркало и выгружает изменения; без -Diff — только выгрузка.
function Sync-Version($number, $meta, [switch]$Diff) {
    $cf = Join-Path $work 'version.cf'
    Invoke-Mirror "/ConfigurationRepositoryDumpCfg `"$cf`" -v $number" "Получение версии $number из хранилища" -Repo | Out-Null
    Invoke-Mirror "/LoadCfg `"$cf`"" "Загрузка версии $number в зеркало" | Out-Null
    Remove-Item $cf

    $hasDump = Test-Path (Join-Path $mirrorDump 'ConfigDumpInfo.xml')
    if (-not $Diff -or -not $hasDump) {
        Reset-Dir $mirrorDump
        Invoke-Mirror "/DumpConfigToFiles `"$mirrorDump`"" "Выгрузка версии $number" | Out-Null
        if (-not $Diff) { return }
    }

    $changesFile = Join-Path $work 'changes.txt'
    if (Test-Path $changesFile) { Remove-Item $changesFile }
    Invoke-Mirror "/DumpConfigToFiles `"$mirrorDump`" -update -getChanges `"$changesFile`"" "Список изменений версии $number" | Out-Null
    $relPaths = @()
    $fullDump = $false
    if (Test-Path $changesFile) {
        foreach ($line in Get-Content $changesFile -Encoding UTF8) {
            if ($line -match 'FullDump') { $fullDump = $true }
            if ($line -match '^\s*\w+:\s*(\S+)\s*$') { $relPaths += Get-ObjectPaths $Matches[1] }
        }
    }
    $relPaths = @($relPaths | Sort-Object -Unique)

    $before = Join-Path $work 'before'
    $after = Join-Path $work 'after'
    Reset-Dir $before
    Reset-Dir $after
    Copy-Paths $mirrorDump $relPaths $before
    if ($fullDump) {
        Reset-Dir $mirrorDump
        Invoke-Mirror "/DumpConfigToFiles `"$mirrorDump`"" "Выгрузка версии $number" | Out-Null
    } else {
        Invoke-Mirror "/DumpConfigToFiles `"$mirrorDump`" -update" "Выгрузка версии $number" | Out-Null
    }
    Copy-Paths $mirrorDump $relPaths $after
    $result = Compare-Snapshots $before $after

    $dir = Join-Path $history ('v{0:D6}' -f $number)
    Reset-Dir $dir
    $pii.Begin()
    try {
        $info = @(
            if ($meta) { (Format-Version $meta 1000) -split ' · ' } else { "Версия $number" }
            ''
            'Изменённые файлы выгрузки (подробности — в changes.diff):'
            if ($result.files) { $result.files } else { '  нет изменений в файлах' }
        ) -join "`r`n"
        [IO.File]::WriteAllText((Join-Path $dir 'info.txt'), $info, $utf8)
        [IO.File]::WriteAllText((Join-Path $dir 'changes.diff'), $pii.Protect($result.diff), $utf8)
    } finally {
        $pii.End()
    }
    [IO.Directory]::Delete($before, $true)
    [IO.Directory]::Delete($after, $true)
}

# --- Синхронизация ---
$state = Read-State
try {
    New-Item -ItemType Directory -Force $mirror, $work, $history | Out-Null
    if (-not (Test-Path (Join-Path $mirrorIb '1Cv8.1CD'))) {
        Write-Log 'Создаю базу-зеркало хранилища'
        $p = Start-Process $exe -ArgumentList "CREATEINFOBASE File=`"$mirrorIb`"" -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { throw 'Не удалось создать базу-зеркало хранилища' }
    }

    # 1. Новые версии — в общий список versions.txt.
    $from = [Math]::Max(1, [Math]::Min($state.lastReported + 1, $state.lastDiffed + 1))
    $versions = @(Get-RepoVersions $from)
    $meta = @{}
    foreach ($v in $versions) { $meta[$v.number] = $v }
    $newVersions = @($versions | Where-Object { $_.number -gt $state.lastReported } | Sort-Object number)
    if ($newVersions) {
        $pii.Begin()
        try {
            $lines = foreach ($v in $newVersions) { Format-Version $v 50 }
        } finally {
            $pii.End()
        }
        $versionsFile = Join-Path $history 'versions.txt'
        if (-not (Test-Path $versionsFile)) {
            $header = "История хранилища конфигурации: по строке на версию, от старых к новым.`r`n" +
                      "Подробности «было → стало» по последним версиям — в папках vNNNNNN (info.txt, changes.diff).`r`n"
            [IO.File]::WriteAllText($versionsFile, $header, $utf8)
        }
        [IO.File]::AppendAllText($versionsFile, (($lines -join "`r`n") + "`r`n"), $utf8)
        $state.lastReported = ($newVersions | Select-Object -Last 1).number
        $state.latest = $state.lastReported
        Write-Log "В список версий добавлено: $($newVersions.Count), последняя — $($state.lastReported)"
        Save-State $state
    }

    # 2. Подробные изменения последних версий.
    if ($state.lastDiffed -lt 0) {
        # Первый запуск: зеркало ставим на версию перед последними $depth и дальше идём по одной.
        $baseline = [Math]::Max(0, $state.latest - $depth)
        if ($baseline -ge 1) {
            Write-Log "Начальная выгрузка версии $baseline"
            Sync-Version $baseline $null
        }
        $state.lastDiffed = $baseline
        Save-State $state
    }
    while ($state.lastDiffed -lt $state.latest) {
        $number = $state.lastDiffed + 1
        Write-Log "Изменения версии $number"
        if ($number -eq 1) {
            # Первая версия — создание хранилища: вся конфигурация добавлена, построчный diff не нужен.
            Sync-Version 1 $meta[1]
            $dir = Join-Path $history 'v000001'
            Reset-Dir $dir
            $pii.Begin()
            try { $info = Format-Version $meta[1] 1000 } finally { $pii.End() }
            [IO.File]::WriteAllText((Join-Path $dir 'info.txt'), ($info -replace ' · ', "`r`n") + "`r`n`r`nПервая версия хранилища: вся конфигурация добавлена.", $utf8)
        } else {
            Sync-Version $number $meta[$number] -Diff
        }
        $state.lastDiffed = $number
        $state.error = ''
        Save-State $state
    }
    $state.error = ''
    Save-State $state
    Write-Log "Готово: версий $($state.latest), подробности с версии $([Math]::Max(1, $state.latest - $depth + 1))"
} catch {
    $state.error = "$_"
    Save-State $state
    Write-Log "Ошибка: $_"
}
