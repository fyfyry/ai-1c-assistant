# Журнал изменений базы: кто, когда и что изменил в конфигурации, расширениях, внешних обработках и отчётах.
# Подключается в мосте через dot-source.
#
# При каждом обновлении выгрузки (открытие чата):
#   - до выгрузки конфигурации -getChanges даёт список изменённых объектов, их прежние файлы
#     откладываем в private\<база>\changes\main-before;
#   - прежние выгрузки расширений и внешних обработок не удаляем, а переносим в changes\ext-before
#     и changes\epf-before;
#   - после выгрузки и обезличивания сравниваем «было → стало» (Compare-Snapshots из ai-common.ps1);
#   - кто вносил изменения — по журналу регистрации: события 1С передаёт в запросе обновления
#     (ИИ_ЧатСервер.СобытияИзменений).
# Результат: папка workspaces\<база>\change-history (её читает модель, данные обезличены) и записи,
# которые мост возвращает в 1С (регистр ИИ_ИсторияИзменений, форма «История изменений»).

$maxChangeDiffChars = 300000
# Как называть изменённые объекты в истории: тип по-русски, синоним и имя, что произошло.
$changeTypeNames = @{
    Configuration = 'Свойства конфигурации'; CommonModule = 'Общий модуль'; Catalog = 'Справочник'; Document = 'Документ'
    DocumentJournal = 'Журнал документов'; Enum = 'Перечисление'; Report = 'Отчет'; DataProcessor = 'Обработка'
    InformationRegister = 'Регистр сведений'; AccumulationRegister = 'Регистр накопления'; AccountingRegister = 'Регистр бухгалтерии'
    CalculationRegister = 'Регистр расчета'; ChartOfAccounts = 'План счетов'; ChartOfCharacteristicTypes = 'План видов характеристик'
    ChartOfCalculationTypes = 'План видов расчета'; BusinessProcess = 'Бизнес-процесс'; Task = 'Задача'; ExchangePlan = 'План обмена'
    Constant = 'Константа'; CommonForm = 'Общая форма'; CommonTemplate = 'Общий макет'; CommonCommand = 'Общая команда'
    CommonPicture = 'Общая картинка'; CommandGroup = 'Группа команд'; Role = 'Роль'; Subsystem = 'Подсистема'
    EventSubscription = 'Подписка на событие'; ScheduledJob = 'Регламентное задание'; SessionParameter = 'Параметр сеанса'
    FunctionalOption = 'Функциональная опция'; FunctionalOptionsParameter = 'Параметр функциональных опций'
    DefinedType = 'Определяемый тип'; CommonAttribute = 'Общий реквизит'; HTTPService = 'HTTP-сервис'; WebService = 'Web-сервис'
    XDTOPackage = 'Пакет XDTO'; Language = 'Язык'; Style = 'Стиль'; StyleItem = 'Элемент стиля'; FilterCriterion = 'Критерий отбора'
    SettingsStorage = 'Хранилище настроек'; DocumentNumerator = 'Нумератор'; Sequence = 'Последовательность'
    WSReference = 'WS-ссылка'; IntegrationService = 'Сервис интеграции'
}
$changeKindNames = @{ Modified = 'изменён'; Added = 'добавлен'; New = 'добавлен'; Deleted = 'удалён'; Removed = 'удалён' }
# Статус пишем в начале строки существительным — так не нужно согласовывать род с типом объекта.
$changeKindTitles = @{ 'изменён' = 'Изменение'; 'добавлен' = 'Добавление'; 'удалён' = 'Удаление' }
function Get-KindTitle($kind) { if ($changeKindTitles.ContainsKey($kind)) { $changeKindTitles[$kind] } else { $kind } }

# Синоним объекта из его XML в выгрузке; пусто, если файла нет.
function Get-Synonym($xmlFile) {
    if (-not $xmlFile -or -not (Test-Path -LiteralPath $xmlFile)) { return '' }
    try {
        [xml]$x = Get-Content -LiteralPath $xmlFile -Raw -Encoding UTF8
        $node = $x.SelectSingleNode("/*/*/*[local-name()='Properties']/*[local-name()='Synonym']//*[local-name()='content']")
        if ($node) { return $node.InnerText.Trim() }
    } catch {}
    ''
}

function Format-ObjectTitle($type, $name, $synonym) {
    $typeTitle = if ($changeTypeNames.ContainsKey($type)) { $changeTypeNames[$type] } else { $type }
    if ($synonym -and $synonym -ne $name) { "$typeTitle «$synonym» ($name)" } else { "$typeTitle $name" }
}

# Тип объекта по папке выгрузки: CommonModules → CommonModule (обратно к Get-ObjectPaths).
function Get-TypeByFolder($folder) {
    foreach ($type in $changeTypeNames.Keys) {
        $paths = @(Get-ObjectPaths "$type.x")
        if ($paths -and ($paths[0] -split '\\')[0] -eq $folder) { return $type }
    }
    $null
}

# Основная конфигурация: строки -getChanges → «Документ «Авансовый отчет» (АвансовыйОтчет) — изменён».
# Синоним ищем в новой выгрузке, у удалённых объектов — в прежней.
function Format-ChangedObjects($lines, $roots) {
    $result = [ordered]@{}
    foreach ($line in $lines) {
        if ($line -notmatch '^\s*(\w+):\s*(\S+)\s*$') { continue }
        $kind = if ($changeKindNames.ContainsKey($Matches[1])) { $changeKindNames[$Matches[1]] } else { $Matches[1] }
        $parts = $Matches[2].Split('.')
        if ($parts[0] -eq 'Configuration') { $result['Configuration'] = 'Изменение: свойства конфигурации'; continue }
        if ($parts.Count -lt 2) { continue }
        $key = "$($parts[0]).$($parts[1])"
        if ($result.Contains($key)) { continue }
        $synonym = ''
        foreach ($root in @($roots)) {
            $xml = @(Get-ObjectPaths $key)[0]
            if ($xml) { $synonym = Get-Synonym (Join-Path $root $xml) }
            if ($synonym) { break }
        }
        $result[$key] = "$(Get-KindTitle $kind): $(Format-ObjectTitle $parts[0] $parts[1] $synonym)"
    }
    @($result.Values)
}

# Статус объекта по его файлам: добавлен/удалён — по корневому XML, иначе изменён.
function Get-ObjectStatus($statuses, $rootRel) {
    if ($statuses.ContainsKey($rootRel)) {
        if ($statuses[$rootRel] -eq 'добавлен') { return 'добавлен' }
        if ($statuses[$rootRel] -eq 'удалён') { return 'удалён' }
    }
    'изменён'
}

# Расширения и внешние обработки: строки «  путь — статус» из Compare-Snapshots → понятные объекты.
function Format-ChangedFiles($fileLines, $sectionKey, $beforeRoot, $afterRoot) {
    $statuses = @{}
    foreach ($line in $fileLines) {
        if ($line -match '^\s*(.+?) — (\S+)\s*$') { $statuses[$Matches[1]] = $Matches[2] }
    }
    $result = [ordered]@{}
    foreach ($rel in $statuses.Keys | Sort-Object) {
        $seg = $rel.Split('\')
        if ($sectionKey -eq 'ext') {
            $ext = $seg[0]
            $extSyn = Get-Synonym (Join-Path $afterRoot "$ext\Configuration.xml")
            if (-not $extSyn) { $extSyn = Get-Synonym (Join-Path $beforeRoot "$ext\Configuration.xml") }
            $extTitle = if ($extSyn -and $extSyn -ne $ext) { "расширение «$extSyn» ($ext)" } else { "расширение $ext" }
            $extStatus = Get-ObjectStatus $statuses "$ext\Configuration.xml"
            if ($extStatus -ne 'изменён') { $result["ext:${ext}"] = "$(Get-KindTitle $extStatus): $extTitle"; continue }
            if ($seg.Count -ge 3 -and ($type = Get-TypeByFolder $seg[1])) {
                $name = $seg[2] -replace '\.xml$', ''
                $key = "ext:${ext}:$type.$name"
                if ($result.Contains($key)) { continue }
                $rootRel = "$ext\$($seg[1])\$name.xml"
                $syn = Get-Synonym (Join-Path $afterRoot $rootRel)
                if (-not $syn) { $syn = Get-Synonym (Join-Path $beforeRoot $rootRel) }
                $result[$key] = "$(Get-KindTitle (Get-ObjectStatus $statuses $rootRel)): $(Format-ObjectTitle $type $name $syn) — $extTitle"
            } elseif (-not $result.Contains("ext:${ext}:props")) {
                $result["ext:${ext}:props"] = "Изменение: свойства — $extTitle"
            }
        } else {
            # cfdump-epf: База\<Имя>.xml и База\<Имя>\... (зарегистрированные), Файлы\... (файлы из папок).
            if ($seg.Count -lt 2) { continue }
            $name = $seg[1] -replace '\.xml$', ''
            $key = "epf:$($seg[0]):$name"
            if ($result.Contains($key)) { continue }
            $rootRel = "$($seg[0])\$name.xml"
            $xmlFile = if (Test-Path -LiteralPath (Join-Path $afterRoot $rootRel)) { Join-Path $afterRoot $rootRel } else { Join-Path $beforeRoot $rootRel }
            $type = 'ExternalDataProcessor'
            if ((Test-Path -LiteralPath $xmlFile) -and ([IO.File]::ReadAllText($xmlFile) -match '<ExternalReport[\s>]')) { $type = 'ExternalReport' }
            $kindTitle = if ($type -eq 'ExternalReport') { 'отчет' } else { 'обработка' }
            $syn = Get-Synonym $xmlFile
            $title = if ($syn -and $syn -ne $name) { "$kindTitle «$syn» ($name)" } else { "$kindTitle $name" }
            $where = if ($seg[0] -eq 'База') { 'зарегистрирована в базе' } else { 'файл в папке обработок' }
            if ($type -eq 'ExternalReport' -and $seg[0] -eq 'База') { $where = 'зарегистрирован в базе' }
            $result[$key] = "$(Get-KindTitle (Get-ObjectStatus $statuses $rootRel)): $title, $where"
        }
    }
    @($result.Values)
}
# Подпись файла выгрузки для отчёта: «Документ «Авансовый отчет» (АвансовыйОтчет): модуль объекта».
$filePartTitles = @{
    'ObjectModule.bsl' = 'модуль объекта'; 'ManagerModule.bsl' = 'модуль менеджера'; 'Module.bsl' = 'модуль'
    'RecordSetModule.bsl' = 'модуль набора записей'; 'ValueManagerModule.bsl' = 'модуль менеджера значения'
    'CommandModule.bsl' = 'модуль команды'; 'ManagedApplicationModule.bsl' = 'модуль управляемого приложения'
    'OrdinaryApplicationModule.bsl' = 'модуль обычного приложения'; 'SessionModule.bsl' = 'модуль сеанса'
    'ExternalConnectionModule.bsl' = 'модуль внешнего соединения'
}

function Get-FileCaption($sectionKey, $rel, $beforeRoot, $afterRoot) {
    $seg = $rel.Split('\')
    $prefix = ''
    $offset = 0
    if ($sectionKey -eq 'ext') {
        $ext = $seg[0]
        $syn = Get-Synonym (Join-Path $afterRoot "$ext\Configuration.xml")
        if (-not $syn) { $syn = Get-Synonym (Join-Path $beforeRoot "$ext\Configuration.xml") }
        $prefix = if ($syn -and $syn -ne $ext) { "Расширение «$syn» ($ext) — " } else { "Расширение $ext — " }
        $offset = 1
    }
    $rest = @($seg | Select-Object -Skip $offset)
    $obj = ''
    $partStart = 0
    if ($sectionKey -eq 'epf') {
        $name = $rest[1] -replace '\.xml$', ''
        $rootXml = Join-Path $afterRoot "$($rest[0])\$name.xml"
        if (-not (Test-Path -LiteralPath $rootXml)) { $rootXml = Join-Path $beforeRoot "$($rest[0])\$name.xml" }
        $isReport = (Test-Path -LiteralPath $rootXml) -and ([IO.File]::ReadAllText($rootXml) -match '<ExternalReport[\s>]')
        $syn = Get-Synonym $rootXml
        $kind = if ($isReport) { 'Отчет' } else { 'Обработка' }
        $obj = if ($syn -and $syn -ne $name) { "$kind «$syn» ($name)" } else { "$kind $name" }
        $partStart = 2
    } elseif ($rest.Count -ge 2 -and ($type = Get-TypeByFolder $rest[0])) {
        $name = $rest[1] -replace '\.xml$', ''
        $xmlRel = (@($seg | Select-Object -First $offset) + @($rest[0], "$name.xml")) -join '\'
        $syn = Get-Synonym (Join-Path $afterRoot $xmlRel)
        if (-not $syn) { $syn = Get-Synonym (Join-Path $beforeRoot $xmlRel) }
        $obj = Format-ObjectTitle $type $name $syn
        $partStart = 2
    } else {
        $obj = if ($sectionKey -eq 'ext') { 'свойства и модули расширения' } else { 'Конфигурация' }
        $partStart = 0
    }
    $parts = @($rest | Select-Object -Skip $partStart)
    $leaf = $rel.Split('\')[-1]
    $part = if ($partStart -gt 0 -and $parts.Count -eq 0) { 'свойства и состав объекта' }
            else {
                $p = @()
                for ($i = 0; $i -lt $parts.Count; $i++) {
                    switch ($parts[$i]) {
                        'Forms' { if ($i + 1 -lt $parts.Count) { $p += "форма $($parts[$i + 1] -replace '\.xml$', '')"; $i++ } }
                        'Templates' { if ($i + 1 -lt $parts.Count) { $p += "макет $($parts[$i + 1] -replace '\.xml$', '')"; $i++ } }
                        'Commands' { if ($i + 1 -lt $parts.Count) { $p += "команда $($parts[$i + 1] -replace '\.xml$', '')"; $i++ } }
                        'Help' { $p += 'справка' }
                    }
                }
                if ($filePartTitles.ContainsKey($leaf)) { $p += $filePartTitles[$leaf] }
                elseif ($leaf -eq 'Form.xml') { $p += 'элементы и реквизиты' }
                elseif ($leaf -eq 'Template.xml') { $p += 'содержимое' }
                elseif ($leaf -eq 'Configuration.xml') { $p += 'свойства' }
                if ($p) { $p -join ': ' } else { $rel }
            }
    "$prefix${obj}: $part"
}

# HTML-отчёт по записи журнала для формы «История изменений»: события, объекты, изменения кода и метаданных.
function New-ChangeReportHtml($title, $eventLines, $objects, $fileLines, $sectionKey, $beforeRoot, $afterRoot) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append([AI1C.ChangeReport]::PageStart($title)).Append([AI1C.ChangeReport]::Tools())
    [void]$sb.Append('<div class="fh" onclick="t(this)"><span class="ar">&#9662;</span> Кто и когда (журнал регистрации)</div><div class="fb ev">')
    [void]$sb.Append($(if ($eventLines) { [AI1C.ChangeReport]::H(($eventLines -join "`n")) } else { 'В журнале регистрации событий не найдено (например, изменён файл обработки в папке).' }))
    [void]$sb.Append('</div>')
    if ($objects) {
        [void]$sb.Append('<div class="fh" onclick="t(this)"><span class="ar">&#9662;</span> Что изменено</div><div class="fb"><ul class="list">')
        foreach ($o in $objects) { [void]$sb.Append('<li>').Append([AI1C.ChangeReport]::H($o)).Append('</li>') }
        [void]$sb.Append('</ul></div>')
    }
    # Сначала модули, потом описания объектов, форм и макетов.
    $entries = @($fileLines | ForEach-Object { if ($_ -match '^\s*(.+?) — (\S+)\s*$') { [pscustomobject]@{ rel = $Matches[1]; status = $Matches[2] } } })
    $entries = @($entries | Sort-Object @{ e = { if ($_.rel -like '*.bsl') { 0 } else { 1 } } }, rel)
    foreach ($e in $entries) {
        if ((Split-Path $e.rel -Leaf) -eq 'ConfigDumpInfo.xml') { continue }
        $caption = Get-FileCaption $sectionKey $e.rel $beforeRoot $afterRoot
        [void]$sb.Append([AI1C.ChangeReport]::FileSection($caption, $e.rel, $e.status, (Join-Path $beforeRoot $e.rel), (Join-Path $afterRoot $e.rel)))
        if ($sb.Length -gt 2000000) { [void]$sb.Append('<div class="note">Остальные изменения не показаны — их слишком много.</div>'); break }
    }
    [void]$sb.Append([AI1C.ChangeReport]::PageEnd())
    $sb.ToString()
}
function Get-ChangesDir($base) {
    $dir = Join-Path (Get-PrivateDir $base) 'changes'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $dir
}

function Clear-Dir($dir) {
    if (Test-Path $dir) { [IO.Directory]::Delete($dir, $true) }
}

# До выгрузки -update: какие объекты основной конфигурации изменились и их прежние файлы.
function Save-MainBefore($base, $fileOverride, $dumpDir, $log) {
    $changes = Get-ChangesDir $base
    Clear-Dir (Join-Path $changes 'main-before')
    Remove-Item (Join-Path $changes 'main-objects.txt') -ErrorAction SilentlyContinue
    if (-not (Test-Path (Join-Path $dumpDir 'ConfigDumpInfo.xml'))) { return }

    $listFile = Join-Path $changes 'getchanges.txt'
    if (Test-Path $listFile) { Remove-Item $listFile }
    if (-not (Start-Designer $base $fileOverride "/DumpConfigToFiles `"$dumpDir`" -getChanges `"$listFile`"" $log 3600)) { return }
    if (-not (Test-Path $listFile)) { return }
    $objects = @(Get-Content $listFile -Encoding UTF8 | Where-Object { $_ -match '^\s*\w+:\s*\S+' -and $_ -notmatch 'FullDump' } | ForEach-Object { $_.Trim() })
    if (-not $objects) { return }
    [IO.File]::WriteAllLines((Join-Path $changes 'main-objects.txt'), $objects, $utf8)
    $paths = @($objects | ForEach-Object { if ($_ -match ':\s*(\S+)\s*$') { Get-ObjectPaths $Matches[1] } } | Sort-Object -Unique)
    Copy-Paths $dumpDir $paths (Join-Path $changes 'main-before')
}

# Вместо удаления прежней выгрузки расширений или обработок — откладываем её для сравнения.
function Save-DumpBefore($base, $dumpDir, $name) {
    $target = Join-Path (Get-ChangesDir $base) $name
    Clear-Dir $target
    if (Test-Path $dumpDir) { Move-Item $dumpDir $target }
}

function Get-EventGroup($e) {
    switch -regex ([string]$e.event) {
        'ConfigExtension|DBConfigExtension' { return 'ext' }
        'ConfigUpdate|DBConfigUpdate' { return 'main' }
        '_\$Data\$_' { return 'epf' }
    }
    'other'
}

function Format-Event($e, $pii) {
    $who = if ($e.user) { $pii.Token('РАЗРАБОТЧИК', [string]$e.user) } else { 'пользователь не указан' }
    $parts = @("$($e.date) — $who — $($e.eventPresentation)")
    if ($e.data) { $parts += "«$($pii.Protect([string]$e.data))»" }
    if ($e.comment) { $parts += $pii.Protect(([string]$e.comment -replace '\s+', ' ').Trim()) }
    if ($e.computer) { $parts += "компьютер $($e.computer)" }
    $parts -join ', '
}

# Сравнивает отложенные выгрузки с новыми и записывает журнал. Вызывается после Protect-Dump.
# Возвращает записи для 1С: Дата, Раздел, Авторы, Объекты, События, Изменения (с настоящими данными).
function Write-ChangeHistory($base, $workspace, $events) {
    $changes = Get-ChangesDir $base
    $events = @($events | Where-Object { $_ })
    $sections = @(
        @{ key = 'main'; title = 'Конфигурация'; before = Join-Path $changes 'main-before'; after = Join-Path $changes 'main-after'; dump = Join-Path $workspace 'cfdump' }
        @{ key = 'ext'; title = 'Расширения'; before = Join-Path $changes 'ext-before'; dump = Join-Path $workspace 'cfdump-ext' }
        @{ key = 'epf'; title = 'Внешние обработки и отчёты'; before = Join-Path $changes 'epf-before'; dump = Join-Path $workspace 'cfdump-epf' }
    )
    $historyDir = Join-Path $workspace 'change-history'
    $records = @()
    $pii = Get-Anonymizer $base
    $stamp = Get-Date

    foreach ($s in $sections) {
        $result = $null
        $objects = @()
        if ($s.key -eq 'main') {
            $objectsFile = Join-Path $changes 'main-objects.txt'
            if (Test-Path $objectsFile) {
                $rawObjects = @(Get-Content $objectsFile -Encoding UTF8)
                $objects = Format-ChangedObjects $rawObjects @($s.dump, $s.before)
                $paths = @($rawObjects | ForEach-Object { if ($_ -match ':\s*(\S+)\s*$') { Get-ObjectPaths $Matches[1] } } | Sort-Object -Unique)
                Clear-Dir $s.after
                Copy-Paths $s.dump $paths $s.after
                $result = Compare-Snapshots $s.before $s.after
            }
        } elseif (Test-Path $s.before) {
            $result = Compare-Snapshots $s.before $s.dump
            $objects = @(Format-ChangedFiles $result.files $s.key $s.before $s.dump)
        }
        $sectionEvents = @($events | Where-Object { (Get-EventGroup $_) -eq $s.key })
        $hasChanges = $result -and $result.files
        if (-not $hasChanges -and -not $sectionEvents) { continue }
        if (-not $hasChanges) {
            # Событие в журнале есть, а в выгрузке ничего не поменялось: называем, что известно из журнала.
            $objects = switch ($s.key) {
                'ext' { @('изменений в коде и метаданных расширений нет (расширение применено или установлено повторно)') }
                'epf' { @($sectionEvents | Where-Object { $_.data } | ForEach-Object { "«$($_.data)» — изменены настройки регистрации (сам файл не менялся)" } | Sort-Object -Unique) }
                default { @('изменений в коде и метаданных нет (конфигурация сохранена или обновлена без изменений)') }
            }
        }

        $pii.Begin()
        try {
            $eventLines = @($sectionEvents | ForEach-Object { Format-Event $_ $pii })
            $authors = @($sectionEvents | Where-Object { $_.user } | ForEach-Object { [string]$_.user } | Sort-Object -Unique)
            $authorTokens = @($authors | ForEach-Object { $pii.Token('РАЗРАБОТЧИК', $_) })
            $diff = if ($hasChanges) { $result.diff } else { '' }

            # Для модели — в рабочую папку, с метками вместо имён.
            $name = '{0:yyyyMMdd-HHmmss}-{1}' -f $stamp, $s.key
            $dir = Join-Path $historyDir $name
            New-Item -ItemType Directory -Force $dir | Out-Null
            $info = @(
                "Раздел: $($s.title)"
                "Обнаружено: $($stamp.ToString('dd.MM.yyyy HH:mm')) (изменения с прошлого обновления выгрузки)"
                "Кто вносил изменения (журнал регистрации): $(if ($authorTokens) { $authorTokens -join ', ' } else { 'в журнале не найдено' })"
                ''
                'События журнала регистрации:'
                $(if ($eventLines) { $eventLines | ForEach-Object { "  $_" } } else { '  нет' })
                ''
                'Изменённые объекты и файлы (подробности — в changes.diff):'
                $(if ($objects) { $objects | ForEach-Object { "  $_" } })
                $(if ($hasChanges) { $result.files } else { '  изменений в коде и метаданных не найдено' })
            ) -join "`r`n"
            [IO.File]::WriteAllText((Join-Path $dir 'info.txt'), $info, $utf8)
            if ($diff) { [IO.File]::WriteAllText((Join-Path $dir 'changes.diff'), $diff, $utf8) }
            $line = "$($stamp.ToString('dd.MM.yyyy HH:mm')) · $($s.title) · кто: $(if ($authorTokens) { $authorTokens -join ', ' } else { 'не найдено в журнале' }) · объекты: $(if ($objects) { (@($objects | Select-Object -First 20) -join ', ') } else { '—' }) · папка $name"
            if (-not (Test-Path (Join-Path $historyDir 'changes.txt'))) {
                [IO.File]::WriteAllText((Join-Path $historyDir 'changes.txt'), "Журнал изменений базы: по строке на обнаруженное изменение, от старых к новым. Подробности — в папке, указанной в конце строки (info.txt, changes.diff).`r`n", $utf8)
            }
            [IO.File]::AppendAllText((Join-Path $historyDir 'changes.txt'), $line + "`r`n", $utf8)

            # Для 1С — с настоящими значениями.
            $diffFor1C = $pii.Restore($diff)
            if ($diffFor1C.Length -gt $maxChangeDiffChars) { $diffFor1C = $diffFor1C.Substring(0, $maxChangeDiffChars) + "`n... (изменения обрезаны, полностью — в папке $name)" }
            $afterRoot = if ($s.key -eq 'main') { $s.after } else { $s.dump }
            $html = New-ChangeReportHtml "$($s.title) — $($stamp.ToString('dd.MM.yyyy HH:mm'))" $eventLines $objects $(if ($hasChanges) { $result.files } else { @() }) $s.key $s.before $afterRoot
            $records += [ordered]@{
                date    = $stamp.ToString('yyyy-MM-ddTHH:mm:ss')
                section = $s.title
                authors = ($authors -join ', ')
                objects = ($objects -join "`n")
                events  = $pii.Restore(($eventLines -join "`n"))
                diff    = $diffFor1C
                html    = $pii.Restore($html)
            }
        } finally {
            $pii.End()
        }
    }

    foreach ($d in 'main-before', 'main-after', 'ext-before', 'epf-before') { Clear-Dir (Join-Path $changes $d) }
    Remove-Item (Join-Path $changes 'main-objects.txt') -ErrorAction SilentlyContinue
    if ($records) { Write-Host "Журнал изменений: записей $($records.Count) ($(($records | ForEach-Object { $_.section }) -join ', '))" -ForegroundColor DarkGray }
    $records
}
