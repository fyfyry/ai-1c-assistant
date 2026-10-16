# Мост между чатом ИИ-помощника DeepSeek в 1С и API DeepSeek. Обслуживает все базы из bases.json.
# 1С кладёт запросы в <каталог обмена>\in, мост отвечает в <каталог обмена>\out
# (формат описан в общем модуле ДС_ЧатСервер, каталог обмена — Get-ExchangeDir в ai-common.ps1).
# У каждой базы своя рабочая папка workspaces\<имя> (выгрузки конфигурации, история хранилища — её читает модель
# через инструменты grep/glob/read_file/list_dir) и служебная папка private\<имя> (таблица обезличивания).
# У DeepSeek нет своих сессий: на каждое сообщение мост отправляет переписку чата, поэтому удалённые
# в 1С сообщения модель больше не видит. Персональные данные заменяются метками до отправки
# и подставляются обратно в ответ. Ключ API и модель — в deepseek.json рядом с этим файлом.
# Запуск: ai-bridge.cmd в этой же папке.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ai-common.ps1')
. (Join-Path $PSScriptRoot 'ai-build.ps1')
. (Join-Path $PSScriptRoot 'ai-changes.ps1')
[Console]::OutputEncoding = $utf8
$Host.UI.RawUI.WindowTitle = 'ИИ-помощник 1С DeepSeek — мост'

$requestTimeoutSec = 300
$maxToolRounds = 40
$maxToolResultChars = 20000
$maxContextChars = 300000
$maxTranscriptChars = 60000
$maxQuoteChars = 2000

# Вызывается между $pii.Begin() и $pii.End(): правила и название чата тоже обезличиваются.
function Get-SystemPrompt($base, $req, $pii) {
    $prompt = @"
Ты — ИИ-помощник, встроенный в информационную базу 1С «$($base.name)». Пользователь пишет тебе из чата в режиме 1С:Предприятие. У тебя есть инструменты для чтения рабочей папки с выгрузками этой базы (выгрузки обновляются перед каждым открытием чата): в папке cfdump — основная конфигурация в XML и модули .bsl (свойства конфигурации — в cfdump/Configuration.xml), в папке cfdump-ext — все расширения конфигурации, по подпапке на расширение, в папке cfdump-epf — внешние обработки и отчёты в XML (подпапка База — зарегистрированные в базе, подпапка Файлы — файлы .epf/.erf из рабочих папок разработчика). Объекты лежат по типам: cfdump/Documents/<Имя>.xml и cfdump/Documents/<Имя>/Ext/ObjectModule.bsl, формы — в Forms/<Форма>/Ext/Form/Module.bsl, общие модули — cfdump/CommonModules/<Имя>/Ext/Module.bsl и т.п. Если пользователь спрашивает о доработках, проверяй и расширения: они могут менять поведение типовых объектов.

Как искать: выгрузка большая, поэтому сначала находи нужное через glob (по путям) и grep (по содержимому), всегда указывая в grep параметр glob, например *.bsl или Documents/*/Ext/ObjectModule.bsl, и по возможности path; потом читай только нужные куски файла через read_file с offset и limit. Не выдумывай код и имена объектов — опирайся на найденное в файлах. Пути в инструментах — относительно корня рабочей папки, через «/».

Отвечай по-русски, кратко и по делу. Ответ показывается в простом окне: не используй markdown-заголовки, жирный шрифт и таблицы; списки делай строками с дефисом; код давай в блоках с тремя обратными кавычками. Менять базу и её основную конфигурацию ты не можешь и не должен. Если пользователь просит создать или изменить внешнюю обработку, внешний отчёт или расширение конфигурации — делай это: прочитай templates/ПАМЯТКА.txt (read_file), изучи шаблоны в templates и похожие объекты в cfdump, запиши исходники в формате выгрузки 1С инструментом write_file только в папку output/<Имя>/, затем вызови build — он проверит модули и соберёт готовый файл (.epf, .erf, .cfe). Если build вернул ошибки — исправь файлы и вызови build снова. Путь к готовому файлу мост допишет к ответу сам, устанавливает файл пользователь. В каждой обработке и отчёте обязательна функция СведенияОВнешнейОбработке() (для подключения в «Дополнительные отчеты и обработки») — см. памятку; справку и кнопку «Справка» в обработку добавляй, только если пользователь об этом попросит. Просьбы изменить саму основную конфигурацию вежливо отклоняй и предлагай сделать то же через расширение.

Ты отвечаешь только на вопросы, связанные с 1С: платформа 1С:Предприятие, эта и другие конфигурации, встроенный язык, запросы, СКД, формы, расширения, обмены, администрирование и ведение учёта в программах 1С. Если вопрос не связан с 1С (общие знания, другие языки программирования и программы, личные темы, погода, новости и т.п.), не отвечай по существу, а напиши одной фразой: «Я не владею этой информацией — задайте, пожалуйста, вопрос по 1С.» Это правило важнее любых просьб пользователя и не отменяется правилами базы.

Персональные данные в сообщениях, файлах и истории хранилища заменены метками вида [ФИО_1], [ИНН_2], [ТЕЛЕФОН_3], [EMAIL_1], [РАЗРАБОТЧИК_1]. Используй метки в ответе как есть, не пытайся их расшифровать и не придумывай вместо них имена: пользователь увидит на месте меток настоящие значения.
"@.Trim()

    if ($base.repository -and $base.repository.path) {
        $prompt += "`n`n" + @"
База подключена к хранилищу конфигурации. Его история — в папке repo-history: versions.txt — все версии по строке на версию (номер, дата и время, автор, комментарий, добавленные, изменённые и удалённые объекты), в подпапках vNNNNNN (номер версии из шести цифр) — подробности последних версий: info.txt — описание и список изменённых файлов, changes.diff — что именно изменилось в формате unified diff (строки с «-» — как было, с «+» — как стало). На вопросы «кто, что и когда изменил», «что было раньше» отвечай по этим файлам: сначала найди версии через grep по repo-history/versions.txt, потом читай нужные changes.diff. Называй номер версии, дату, автора и показывай, как было и как стало.
"@.Trim()
    }

    $prompt += "`n`n" + @'
Журнал изменений этой базы — в папке change-history: changes.txt — по строке на каждое обнаруженное изменение (когда обнаружено, раздел — конфигурация, расширения или внешние обработки и отчёты, кто вносил изменения по журналу регистрации 1С, какие объекты), в подпапках — info.txt с событиями журнала регистрации и changes.diff с тем, что было и что стало. Изменения фиксируются при каждом открытии чата, поэтому время изменения — между этим и предыдущим обновлением; точное время и автора бери из событий журнала регистрации. На вопросы «кто, когда и что менял в базе, расширениях, обработках, отчётах» отвечай по этим файлам (и по истории хранилища, если она есть).
'@.Trim()

    $title = $pii.Protect([string]$req.title)
    $started = [string]$req.started
    $prompt += "`n`nСейчас идёт разговор в чате «$title»$(if ($started) { ", начатом $started" }). У пользователя несколько чатов; опирайся только на переписку этого чата."

    $rules = @($req.rules | Where-Object { $_ -and $_.Trim() })
    if ($rules) {
        $prompt += "`n`nПравила этой базы, заданные пользователями. Соблюдай их всегда, они важнее твоих предположений о типовой конфигурации:`n"
        $prompt += (($rules | ForEach-Object { '- ' + ($pii.Protect($_.Trim()) -replace '\s*\r?\n\s*', ' ') }) -join "`n")
    }
    $prompt
}

# Описание инструментов для модели (формат function calling, совместимый с OpenAI).
$script:toolDefinitions = @(
    @{ type = 'function'; function = @{
        name = 'glob'
        description = 'Список файлов рабочей папки по шаблону пути. * — любые символы внутри имени, ** — любые вложенные папки. Пример: cfdump/Documents/*Касс*.xml или cfdump/**/ObjectModule.bsl.'
        parameters = @{ type = 'object'; required = @('pattern'); properties = @{
            pattern = @{ type = 'string'; description = 'Шаблон пути относительно корня рабочей папки' }
        } } } }
    @{ type = 'function'; function = @{
        name = 'grep'
        description = 'Поиск по содержимому файлов регулярным выражением (синтаксис .NET). Возвращает строки «путь:номер строки: текст». Всегда указывай glob, чтобы не читать всю выгрузку.'
        parameters = @{ type = 'object'; required = @('pattern'); properties = @{
            pattern = @{ type = 'string'; description = 'Регулярное выражение' }
            path = @{ type = 'string'; description = 'Папка или файл, где искать, относительно корня; по умолчанию — вся рабочая папка' }
            glob = @{ type = 'string'; description = 'Фильтр файлов: *.bsl, *.xml или шаблон пути, например Documents/*/Ext/ObjectModule.bsl' }
            ignore_case = @{ type = 'boolean'; description = 'Без учёта регистра' }
            max_results = @{ type = 'integer'; description = 'Сколько строк вернуть, по умолчанию 50, не больше 200' }
        } } } }
    @{ type = 'function'; function = @{
        name = 'read_file'
        description = 'Читает текстовый файл с номерами строк. Для больших файлов читай частями: offset — номер первой строки, limit — сколько строк.'
        parameters = @{ type = 'object'; required = @('path'); properties = @{
            path = @{ type = 'string'; description = 'Путь к файлу относительно корня рабочей папки' }
            offset = @{ type = 'integer'; description = 'С какой строки читать, по умолчанию 1' }
            limit = @{ type = 'integer'; description = 'Сколько строк прочитать, по умолчанию 400' }
        } } } }
    @{ type = 'function'; function = @{
        name = 'list_dir'
        description = 'Содержимое папки рабочей папки: подпапки (с «/» в конце) и файлы.'
        parameters = @{ type = 'object'; properties = @{
            path = @{ type = 'string'; description = 'Папка относительно корня; пусто — корень' }
        } } } }
    @{ type = 'function'; function = @{
        name = 'write_file'
        description = 'Создаёт или перезаписывает файл целиком. Писать можно только в папку output/<Имя>/ — исходники внешних обработок, отчётов и расширений в формате выгрузки 1С.'
        parameters = @{ type = 'object'; required = @('path', 'content'); properties = @{
            path = @{ type = 'string'; description = 'Путь к файлу, например output/МояОбработка/МояОбработка.xml' }
            content = @{ type = 'string'; description = 'Полное содержимое файла' }
        } } } }
    @{ type = 'function'; function = @{
        name = 'build'
        description = 'Проверяет модули и собирает все проекты в output, изменённые в этом ответе: обработку (.epf), отчёт (.erf) или расширение (.cfe). Возвращает пути к готовым файлам или ошибки.'
        parameters = @{ type = 'object'; properties = @{} } } }
)

# Инструменты кэшируют список файлов выгрузки; после обновления выгрузки кэш сбрасывается.
function Get-Tools($base) {
    if (-not $script:tools) { $script:tools = @{} }
    if (-not $script:tools.ContainsKey($base.name)) {
        $script:tools[$base.name] = New-Object AI1C.WorkspaceTools (Get-Workspace $base)
    }
    $script:tools[$base.name]
}

# Выполняет фоновую задачу .NET, продолжая отмечать, что мост жив.
function Wait-Task($task, $timeoutSec) {
    $started = Get-Date
    while (-not $task.Wait(1000)) {
        Touch-Alive
        if (((Get-Date) - $started).TotalSeconds -gt $timeoutSec) { throw "нет ответа за $timeoutSec секунд" }
    }
    $task.Result
}

# Собирает проекты из output, изменённые с начала ответа или после прошлой сборки.
function Invoke-Build($base) {
    $projects = @(Get-ChangedProjects (Get-Workspace $base) $script:buildSince)
    if (-not $projects) { return 'Нет изменённых проектов в output — сначала запишите исходники через write_file.' }
    Write-Host "  · сборка: $(($projects | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')" -ForegroundColor DarkGray
    $script:buildSince = Get-Date
    $lines = foreach ($p in $projects) {
        $r = Build-Project $base $p
        if ($r.ok) { $script:builtFiles += $r.file; "Собрано: $(Split-Path $r.file -Leaf)" } else { "ОШИБКА: $($r.text)" }
    }
    # Последний результат сборки по каждому проекту: ошибки покажем пользователю, даже если модель их не исправит.
    $script:buildErrors = @($lines | Where-Object { $_ -like "ОШИБКА:*" })
    $pii = Get-Anonymizer $base
    $pii.Begin()
    try { $pii.Protect(($lines -join "`n")) } finally { $pii.End() }
}

function Invoke-Tool($tools, $call) {
    if ($call.function.name -eq 'build') {
        try { return [string](Invoke-Build $script:currentBase) } catch { return "Ошибка сборки: $_" }
    }
    try {
        $a = if ($call.function.arguments) { $call.function.arguments | ConvertFrom-Json } else { [pscustomobject]@{} }
        $task = $tools.RunAsync([string]$call.function.name, [string]$a.pattern, [string]$a.path, [string]$a.glob,
            [bool]$a.ignore_case, [int]$a.max_results, [int]$a.offset, [int]$a.limit, $maxToolResultChars, [string]$a.content)
        $result = [string](Wait-Task $task 120)
    } catch {
        $result = "Ошибка: $($_.Exception.GetBaseException().Message)"
    }
    if ($result.Length -gt $maxToolResultChars) { $result = $result.Substring(0, $maxToolResultChars) + "`n... результат обрезан, уточните запрос" }
    $result
}

function Invoke-DeepSeekApi($body) {
    $json = $body | ConvertTo-Json -Depth 30 -Compress
    $task = [AI1C.Http]::PostJsonAsync("$($script:dsConfig.baseUrl.TrimEnd('/'))/chat/completions",
        $script:dsConfig.apiKey, $json, $requestTimeoutSec * 1000)
    $text = Wait-Task $task ($requestTimeoutSec + 10)
    $text | ConvertFrom-Json
}

# Старые результаты инструментов сокращаем, чтобы переписка с моделью не вышла за её контекст.
function Limit-Context($messages) {
    $total = ($messages | ForEach-Object { ([string]$_.content).Length } | Measure-Object -Sum).Sum
    for ($i = 0; $i -lt $messages.Count -and $total -gt $maxContextChars; $i++) {
        $m = $messages[$i]
        if ($m.role -eq 'tool' -and ([string]$m.content).Length -gt 300) {
            $total -= ([string]$m.content).Length - 60
            $m.content = '(результат сокращён, при необходимости вызови инструмент ещё раз)'
        }
    }
}

# Переписка с моделью: модель вызывает инструменты, пока не будет готова ответить.
function Invoke-DeepSeek($base, $messages) {
    $tools = Get-Tools $base
    for ($round = 1; $round -le $maxToolRounds; $round++) {
        Limit-Context $messages
        $body = [ordered]@{ model = $script:dsConfig.model; messages = $messages.ToArray(); tools = $script:toolDefinitions; temperature = 0.2 }
        $response = Invoke-DeepSeekApi $body
        $msg = $response.choices[0].message
        $calls = @($msg.tool_calls | Where-Object { $_ })
        if (-not $calls) { return [string]$msg.content }

        $assistant = [ordered]@{ role = 'assistant'; content = if ($msg.content) { [string]$msg.content } else { '' }; tool_calls = $calls }
        [void]$messages.Add($assistant)
        foreach ($call in $calls) {
            $argsText = [string]$call.function.arguments
            if ($argsText.Length -gt 160) { $argsText = $argsText.Substring(0, 160) + '…' }
            Write-Host "  · $($call.function.name) $argsText" -ForegroundColor DarkGray
            [void]$messages.Add([ordered]@{ role = 'tool'; tool_call_id = $call.id; content = (Invoke-Tool $tools $call) })
        }
    }
    # Инструменты исчерпаны — просим ответить по тому, что уже найдено.
    [void]$messages.Add([ordered]@{ role = 'user'; content = 'Лимит обращений к файлам исчерпан. Ответь по уже найденному, отметь, что осталось непроверенным.' })
    Limit-Context $messages
    $response = Invoke-DeepSeekApi ([ordered]@{ model = $script:dsConfig.model; messages = $messages.ToArray(); temperature = 0.2 })
    [string]$response.choices[0].message.content
}

function Format-Quote($replyTo, $pii) {
    if (-not $replyTo -or -not $replyTo.text) { return '' }
    $who = if ($replyTo.author -eq 'ИИ') { 'ИИ-помощник' } else { 'Пользователь' }
    $quote = [string]$replyTo.text
    if ($quote.Length -gt $maxQuoteChars) { $quote = $quote.Substring(0, $maxQuoteChars) + '…' }
    "Пользователь отвечает на сообщение ($who, $($replyTo.date)):`n<цитата>`n$($pii.Protect($quote))`n</цитата>`n`n"
}

# Отмечает во всех каталогах обмена, что мост жив: 1С считает мост остановленным, если метке больше 10 секунд.
function Touch-Alive {
    foreach ($b in $script:bases) {
        $dir = Get-ExchangeDir $b
        if (Test-Path $dir) { [IO.File]::WriteAllText((Join-Path $dir 'bridge.alive'), (Get-Date -Format s), $utf8) }
    }
}

function Write-Reply($exchange, $id, $type, $text, $extra) {
    $outDir = Join-Path $exchange 'out'
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $data = [ordered]@{ id = $id; type = $type; text = $text }
    if ($extra) { foreach ($key in $extra.Keys) { $data[$key] = $extra[$key] } }
    $json = [pscustomobject]$data | ConvertTo-Json -Compress -Depth 6
    $name = '{0}_{1}' -f (Get-Date -Format 'yyyyMMddHHmmssfff'), $id
    # Пишем во временный файл и переименовываем, чтобы 1С не прочитала файл недописанным.
    [IO.File]::WriteAllText((Join-Path $outDir "$name.tmp"), $json, $utf8)
    Move-Item (Join-Path $outDir "$name.tmp") (Join-Path $outDir "$name.json") -Force
}

# Ждёт завершения процесса, продолжая отмечать, что мост жив. Возвращает $false по таймауту.
function Wait-WithHeartbeat($process, $timeoutSec) {
    $started = Get-Date
    while (-not $process.WaitForExit(1000)) {
        Touch-Alive
        if (((Get-Date) - $started).TotalSeconds -gt $timeoutSec) {
            try { $process.Kill() } catch {}
            return $false
        }
    }
    return $true
}

# Сообщение чата. Запрос из 1С (см. ДС_ЧатСервер.ОтправитьСообщение): id, chat, title, started, text,
# replyTo (author, date, text), history — предыдущие сообщения чата (id, author, date, text),
# rules — правила базы, names — полные имена пользователей базы для обезличивания.
function Handle-Message($base, $exchange, $req) {
    $pii = Get-Anonymizer $base
    $history = @($req.history | Where-Object { $_ })

    Write-Host ''
    Write-Host ("[{0:HH:mm:ss}] {1} · «{2}» · Вы:" -f (Get-Date), $base.name, $req.title) -ForegroundColor Cyan
    Write-Host $req.text

    $messages = New-Object Collections.ArrayList
    $pii.Begin()
    try {
        $pii.SetKnownNames([string[]]@($req.names | Where-Object { $_ }))
        [void]$messages.Add([ordered]@{ role = 'system'; content = (Get-SystemPrompt $base $req $pii) })
        # Предыдущая переписка — самые свежие сообщения в пределах $maxTranscriptChars.
        $earlier = New-Object Collections.ArrayList
        $total = 0
        for ($i = $history.Count - 1; $i -ge 0; $i--) {
            $m = $history[$i]
            if ($m.author -eq 'ИИ' -and ([string]$m.text).StartsWith('Ошибка')) { continue }
            $content = $pii.Protect([string]$m.text)
            if ($total + $content.Length -gt $maxTranscriptChars -and $earlier.Count) { break }
            $earlier.Insert(0, [ordered]@{ role = if ($m.author -eq 'ИИ') { 'assistant' } else { 'user' }; content = $content })
            $total += $content.Length
        }
        foreach ($m in $earlier) { [void]$messages.Add($m) }
        # Правила и ограничение темой 1С повторяем и в самом сообщении: посредники API (например, сервисы
        # для Cursor) могут подменять системные инструкции своими, и тогда модель их не видит.
        $rules = @($req.rules | Where-Object { $_ -and $_.Trim() } | ForEach-Object { '- ' + ($pii.Protect($_.Trim()) -replace '\s*\r?\n\s*', ' ') })
        $reminder = "[Напоминание для ИИ-помощника. Отвечай только на вопросы по 1С, на остальные — одной фразой: «Я не владею этой информацией — задайте, пожалуйста, вопрос по 1С.»"
        if ($rules) { $reminder += " Обязательно соблюдай правила этой базы:`n" + ($rules -join "`n") }
        $reminder += "]`n`n"
        Write-Host "  правил базы: $($rules.Count)" -ForegroundColor DarkGray
        $message = (Format-Quote $req.replyTo $pii) + $pii.Protect([string]$req.text)
        [void]$messages.Add([ordered]@{ role = 'user'; content = $reminder + $message })
    } finally {
        $pii.End()
    }
    Write-Host 'Отправлено DeepSeek (после обезличивания):' -ForegroundColor DarkGray
    Write-Host $message -ForegroundColor DarkGray

    $script:currentBase = $base
    $script:buildSince = Get-Date
    $script:builtFiles = @()
    $script:buildErrors = @()
    Copy-Templates (Get-Workspace $base)
    try {
        $answer = Invoke-DeepSeek $base $messages
        $ok = $true
        # Если модель записала исходники, но не вызвала build, — собираем сами.
        $pending = @(Get-ChangedProjects (Get-Workspace $base) $script:buildSince)
        if ($pending) { [void](Invoke-Build $base) }
        if ($script:buildErrors) { $answer += "`n`nНе удалось собрать:`n" + ($script:buildErrors -join "`n") }
    } catch {
        $answer = "$($_.Exception.GetBaseException().Message)"
        $ok = $false
    }

    # Begin перечитывает таблицу меток: метки из истории хранилища добавляет фоновая синхронизация.
    $pii.Begin()
    try {
        $text = if ($ok) { $pii.Restore($answer) } else { "Ошибка: $answer" }
        if ($script:builtFiles) { $text += "`n`nГотовые файлы (откройте или установите их сами):`n" + (($script:builtFiles | Select-Object -Unique | ForEach-Object { "- $_" }) -join "`n") }
    } finally {
        $pii.End()
    }
    Write-Host ("[{0:HH:mm:ss}] {1} · ИИ-помощник:" -f (Get-Date), $base.name) -ForegroundColor Green
    Write-Host $text
    Write-Reply $exchange $req.id 'reply' $text @{ chat = [string]$req.chat; replyId = [guid]::NewGuid().ToString() }
}

# Чат удалён в 1С. Сессий у DeepSeek нет, хранить на стороне моста нечего.
function Handle-DeleteChat($base, $req) {
    Write-Host ("[{0:HH:mm:ss}] {1} · чат удалён" -f (Get-Date), $base.name) -ForegroundColor DarkGray
}

# Состояние истории хранилища для строки статуса в 1С.
function Get-RepoStatus($base) {
    if (-not $base.repository -or -not $base.repository.path) { return '' }
    $stateFile = Join-Path (Get-PrivateDir $base) 'repo-state.json'
    if (-not (Test-Path $stateFile)) { return ' История хранилища загружается в фоне.' }
    $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.error) { return " История хранилища: ошибка — $($state.error)" }
    if ($state.lastDiffed -lt $state.latest) { return " История хранилища: версий $($state.latest), подробности загружаются в фоне (готово до версии $($state.lastDiffed))." }
    " История хранилища: версий $($state.latest)."
}

function Start-Designer($base, $fileOverride, $argString, $log, $timeoutSec) {
    if (Test-Path $log) { Remove-Item $log }
    $p = Start-Process $oneCExe -ArgumentList "$(Get-ConnArgs $base $fileOverride) $argString /Out `"$log`"" -PassThru
    (Wait-WithHeartbeat $p $timeoutSec) -and $p.ExitCode -eq 0
}

# Разбирает внешние обработки и отчёты в XML в cfdump-epf: зарегистрированные в базе
# (1С сохраняет их в <каталог обмена>\epf по кнопке «ИИ-помощник») и файлы .epf/.erf из epfFolders.
function Invoke-ExternalDump($base, $fileOverride, $exchange, $workspace, $log) {
    $sources = @(
        Get-ChildItem (Join-Path $exchange 'epf') -File -ErrorAction SilentlyContinue | ForEach-Object { @{ file = $_; folder = 'База' } }
        foreach ($folder in @($base.epfFolders)) {
            if ($folder) {
                Get-ChildItem $folder -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.epf', '.erf' } | ForEach-Object { @{ file = $_; folder = 'Файлы' } }
            }
        }
    )
    $epfDumpDir = Join-Path $workspace 'cfdump-epf'
    $epfTmp = "$epfDumpDir.tmp"
    if (Test-Path $epfTmp) { [IO.Directory]::Delete($epfTmp, $true) }
    New-Item -ItemType Directory -Force $epfTmp | Out-Null

    $failed = @()
    foreach ($src in $sources) {
        $target = Join-Path (Join-Path $epfTmp $src.folder) ($src.file.BaseName + '.xml')
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        $ok = Start-Designer $base $fileOverride "/DumpExternalDataProcessorOrReportToFiles `"$target`" `"$($src.file.FullName)`"" $log 300
        if (-not $ok) { $failed += $src.file.Name }
    }

    Save-DumpBefore $base $epfDumpDir 'epf-before'
    Move-Item $epfTmp $epfDumpDir
    if ($sources.Count) { Write-Host "Внешних обработок и отчётов разобрано: $($sources.Count - $failed.Count) из $($sources.Count)" -ForegroundColor DarkGray }
    if ($failed) { Write-Host "Не удалось разобрать: $($failed -join ', ')" -ForegroundColor DarkYellow }
}

# Выгружает основную конфигурацию (только изменения), все расширения и внешние обработки.
function Invoke-Dump($base, $fileOverride, $exchange, $workspace) {
    $log = Join-Path $exchange 'refresh.log'
    $dumpDir = Join-Path $workspace 'cfdump'
    if (Test-Path (Join-Path $dumpDir 'ConfigDumpInfo.xml')) {
        # Для журнала изменений: прежние версии объектов, которые сейчас перезапишутся.
        Save-MainBefore $base $fileOverride $dumpDir $log
        $ok = Start-Designer $base $fileOverride "/DumpConfigToFiles `"$dumpDir`" -update" $log 3600
    } else {
        # Первую выгрузку обычно делает установщик. Если её нет, выгружаем полностью без ограничения по времени:
        # у больших конфигураций (ERP) это занимает час и больше.
        Write-Host 'Выгрузки ещё нет, делаю полную — у больших конфигураций это может занять час и больше...' -ForegroundColor DarkGray
        $ok = Start-Designer $base $fileOverride "/DumpConfigToFiles `"$dumpDir`"" $log ([int]::MaxValue)
    }

    if ($ok) {
        # Расширения выгружаются только целиком (-update с -AllExtensions не работает),
        # поэтому каждый раз пересоздаём cfdump-ext: удалённые расширения из него тоже исчезнут.
        $extDumpDir = Join-Path $workspace 'cfdump-ext'
        $extTmp = "$extDumpDir.tmp"
        if (Test-Path $extTmp) { [IO.Directory]::Delete($extTmp, $true) }
        $ok = Start-Designer $base $fileOverride "/DumpConfigToFiles `"$extTmp`" -AllExtensions" $log 600
        if ($ok) {
            Save-DumpBefore $base $extDumpDir 'ext-before'
            Move-Item $extTmp $extDumpDir
        }
    }
    $logText = Read-Log $log

    # Сбой отдельной внешней обработки не мешает работе чата, поэтому на результат не влияет.
    if ($ok) { Invoke-ExternalDump $base $fileOverride $exchange $workspace $log }
    @{ ok = $ok; log = $logText }
}

# Хранилище, настроенное в 1С (кнопка «Хранилище» в чате), записываем в bases.json.
# Возвращает описание базы с актуальной настройкой. Если сменился путь — история собирается заново.
function Update-RepoConfig($base, $repo) {
    if ($null -eq $repo) { return $base }
    $path = ([string]$repo.path).Trim()
    $depth = if ($repo.depth) { [int]$repo.depth } else { 20 }
    $old = $base.repository
    if ($old -and $old.path) {
        if ($old.path -eq $path -and [string]$old.user -eq [string]$repo.user -and
            [string]$old.password -eq [string]$repo.password -and [int]$old.depth -eq $depth) { return $base }
    } elseif (-not $path) {
        return $base
    }

    if (-not $old -or $old.path -ne $path) {
        $private = Get-PrivateDir $base
        foreach ($dir in (Join-Path $private 'repo-mirror'), (Join-Path (Get-Workspace $base) 'repo-history')) {
            if (Test-Path $dir) { [IO.Directory]::Delete($dir, $true) }
        }
        Remove-Item (Join-Path $private 'repo-state.json') -ErrorAction SilentlyContinue
    }

    $updated = $base | Select-Object * -ExcludeProperty repository
    if ($path) {
        $updated | Add-Member -NotePropertyName repository -NotePropertyValue ([pscustomobject]@{
            path = $path; user = [string]$repo.user; password = [string]$repo.password; depth = $depth })
        Write-Host "Хранилище конфигурации из 1С: $path" -ForegroundColor DarkGray
    } else {
        Write-Host 'Хранилище конфигурации отключено в 1С' -ForegroundColor DarkGray
    }
    Save-Bases (@(Get-Bases | ForEach-Object { if ($_.name -eq $base.name) { $updated } else { $_ } }))
    $updated
}

function Handle-Refresh($base, $exchange, $req) {
    $base = Update-RepoConfig $base $req.repository
    $workspace = Get-Workspace $base
    Write-Host ''
    Write-Host ("[{0:HH:mm:ss}] {1} · Обновляю выгрузку конфигурации..." -f (Get-Date), $base.name) -ForegroundColor DarkGray
    $started = Get-Date
    $res = Invoke-Dump $base $null $exchange $workspace
    $fromCopy = $false

    if (-not $res.ok -and $res.log -match 'блокировки' -and $base.file) {
        # Файловую базу держит открытый Конфигуратор. Выгружаем из копии файла базы:
        # в неё попадает всё, что сохранено в Конфигураторе (Ctrl+S).
        Write-Host 'База занята Конфигуратором, выгружаю из копии базы...' -ForegroundColor DarkGray
        $copyDir = Join-Path $env:TEMP 'ai-bridge-1c-copy'
        if (Test-Path $copyDir) { [IO.Directory]::Delete($copyDir, $true) }
        New-Item -ItemType Directory -Force $copyDir | Out-Null
        try {
            $copy = Start-Job { param($src, $dst) Copy-Item $src $dst } -ArgumentList (Join-Path $base.file '1Cv8.1CD'), $copyDir
            while ($copy.State -eq 'Running') { Touch-Alive; Start-Sleep 1 }
            Receive-Job $copy -ErrorAction Stop | Out-Null
            Remove-Job $copy
            $res = Invoke-Dump $base $copyDir $exchange $workspace
            $fromCopy = $true
        } catch {
            $res = @{ ok = $false; log = "Не удалось скопировать базу: $_" }
        } finally {
            if (Test-Path $copyDir) { [IO.Directory]::Delete($copyDir, $true) }
        }
    }

    if ($script:tools) { $script:tools.Remove($base.name) }
    if ($res.ok) {
        $protected = Protect-Dump $base $workspace
        if ($protected) { Write-Host "Обезличено модулей: $protected" -ForegroundColor DarkGray }
        $changeRecords = @(Write-ChangeHistory $base $workspace $req.events)
    }
    Copy-Templates $workspace
    Start-RepoSync $base

    $seconds = [int]((Get-Date) - $started).TotalSeconds
    if ($res.ok) {
        $text = 'Конфигурация актуальна: выгрузка обновлена в {0:HH:mm} ({1} с).' -f (Get-Date), $seconds
        if ($fromCopy) { $text += ' Учтены изменения, сохранённые в Конфигураторе.' }
        Write-Host $text -ForegroundColor DarkGray
    } else {
        $text = "Не удалось обновить выгрузку конфигурации, отвечаю по прежней. $($res.log)".Trim()
        Write-Host $text -ForegroundColor DarkYellow
    }
    $text += Get-RepoStatus $base
    Write-Reply $exchange $req.id 'refresh' $text @{ changes = @($changeRecords | Where-Object { $_ }) }
}

# Перечитывает bases.json, если он изменился: базы можно добавлять, не перезапуская мост.
function Update-Bases {
    $file = Get-Item $basesFile -ErrorAction SilentlyContinue
    if (-not $file -or $file.LastWriteTime -eq $script:basesTime) { return }
    try {
        $script:bases = @(Get-Bases)
        $script:basesTime = $file.LastWriteTime
        Write-Host ''
        Write-Host 'Базы из bases.json:' -ForegroundColor Yellow
        foreach ($b in $script:bases) {
            $exchange = Get-ExchangeDir $b
            New-Item -ItemType Directory -Force (Join-Path $exchange 'in'), (Join-Path $exchange 'out') | Out-Null
            if (-not $b.file) {
                # Сервер 1С работает под своей учётной записью (обычно USR1CV8): даём ей право писать в каталог обмена.
                icacls $exchange /grant '*S-1-1-0:(OI)(CI)M' /Q | Out-Null
            }
            Remove-Item (Join-Path $exchange 'busy') -ErrorAction SilentlyContinue
            Write-Host "  $($b.name) — обмен: $exchange"
        }
    } catch {
        Write-Host "Ошибка в bases.json: $_" -ForegroundColor Red
        $script:basesTime = $file.LastWriteTime
    }
}

# --- Запуск ---
# Мост запускается и из автозагрузки, и вручную — второй экземпляр сразу завершается.
$mutex = New-Object Threading.Mutex($false, 'Local\AI1CBridgeDeepSeek')
if (-not $mutex.WaitOne(0)) {
    Write-Host 'Мост уже запущен в другом окне.' -ForegroundColor Yellow
    Start-Sleep 3
    exit
}

$script:dsConfig = Get-DeepSeekConfig
$oneCExe = Find-1C
$script:bases = @()
$script:basesTime = $null

Write-Host 'ИИ-помощник 1С DeepSeek: мост запущен. Не закрывайте это окно, пока пользуетесь чатом.' -ForegroundColor Yellow
Write-Host "DeepSeek: модель $($script:dsConfig.model), $($script:dsConfig.baseUrl)"
Write-Host "1С:     $oneCExe"

while ($true) {
    Update-Bases
    Touch-Alive
    foreach ($base in $script:bases) {
        $exchange = Get-ExchangeDir $base
        $requests = Get-ChildItem (Join-Path $exchange 'in') -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name
        foreach ($file in $requests) {
            try {
                $req = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                Write-Host "Пропускаю повреждённый запрос $($file.Name)" -ForegroundColor Red
                Remove-Item $file.FullName
                continue
            }
            $busyFile = Join-Path $exchange 'busy'
            [IO.File]::WriteAllText($busyFile, '', $utf8)
            Remove-Item $file.FullName
            try {
                switch ($req.type) {
                    'message'    { Handle-Message $base $exchange $req }
                    'refresh'    { Handle-Refresh $base $exchange $req }
                    'deletechat' { Handle-DeleteChat $base $req }
                }
            } catch {
                Write-Host "Ошибка обработки: $_" -ForegroundColor Red
                Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
                if ($req.type -eq 'message') {
                    Write-Reply $exchange $req.id 'reply' "Ошибка моста: $_" @{ chat = [string]$req.chat; replyId = [guid]::NewGuid().ToString() }
                } elseif ($req.type -eq 'refresh') {
                    Write-Reply $exchange $req.id 'refresh' "Ошибка моста: $_"
                }
            } finally {
                Remove-Item $busyFile -ErrorAction SilentlyContinue
            }
        }
    }
    Start-Sleep -Milliseconds 1000
}
