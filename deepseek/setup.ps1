# Мастер установки ИИ-помощника 1С DeepSeek: проверяет 1С и ключ API DeepSeek, подключает выбранную базу,
# ставит мост в автозагрузку Windows и запускает его. Запуск: setup.cmd.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ai-common.ps1')
[Console]::OutputEncoding = $utf8
$Host.UI.RawUI.WindowTitle = 'ИИ-помощник 1С DeepSeek — установка'

# Файлы из интернета или из архива Windows помечает как скачанные — снимаем пометку.
Get-ChildItem $toolRoot -Recurse -File | Unblock-File

function Write-Step($text) { Write-Host ''; Write-Host $text -ForegroundColor Yellow }
function Write-Ok($text) { Write-Host "  ✓ $text" -ForegroundColor Green }

# Пробный запрос к API: проверяет ключ, модель и адрес. Возвращает пояснение ошибки или пустую строку.
function Test-DeepSeekKey($config) {
    $body = @{ model = $config.model; max_tokens = 5; messages = @(@{ role = 'user'; content = 'Ответь одним словом: ок' }) } | ConvertTo-Json -Depth 5 -Compress
    try {
        [void][AI1C.Http]::PostJson("$($config.baseUrl.TrimEnd('/'))/chat/completions", $config.apiKey, $body, 60000)
        return ''
    } catch {
        $message = "$($_.Exception.GetBaseException().Message)"
    }
    $hint = switch -regex ($message) {
        'HTTP 401' { 'ключ не принят. Проверьте, что он скопирован целиком и выдан на platform.deepseek.com (раздел API keys). Если ключ от другого сервиса-посредника, укажите ниже его адрес API.' }
        'HTTP 402' { 'на счёте DeepSeek недостаточно средств — пополните баланс на platform.deepseek.com.' }
        'HTTP 404' { 'по этому адресу нет API в формате DeepSeek/OpenAI — проверьте адрес API.' }
        'model' { 'такой модели нет у этого ключа.' }
        'HTTP 400' { 'запрос не принят — возможно, неверное имя модели.' }
        'HTTP 429' { 'слишком много запросов или исчерпан лимит, попробуйте позже.' }
        'remote name could not be resolved|Unable to connect|не удается|timed out|тайм' { 'нет связи с сервером API — проверьте интернет, прокси и адрес API.' }
        default { '' }
    }
    if ($hint) { "$hint`n  Ответ сервера: $message" } else { $message }
}
# Модели, доступные по ключу (GET /models, формат OpenAI). Модели DeepSeek — в начале списка.
function Get-AvailableModels($config) {
    try {
        $r = [AI1C.Http]::Get("$($config.baseUrl.TrimEnd('/'))/models", $config.apiKey, 30000) | ConvertFrom-Json
    } catch {
        Write-Host "  Не удалось получить список моделей: $($_.Exception.GetBaseException().Message)" -ForegroundColor DarkYellow
        return @()
    }
    $ids = @($r.data | ForEach-Object { [string]$_.id } | Where-Object { $_ } | Sort-Object -Unique)
    # Рассуждающие модели (r1, reasoner, think) хуже работают с инструментами — ставим их после обычных.
    $ds = @($ids | Where-Object { $_ -match 'deepseek' })
    @($ds | Where-Object { $_ -notmatch 'r1|reason|think' }) + @($ds | Where-Object { $_ -match 'r1|reason|think' }) + @($ids | Where-Object { $_ -notmatch 'deepseek' })
}

# Показывает модели и спрашивает номер или имя. Пустой ответ — первая модель списка.
function Select-Model($models) {
    for ($i = 0; $i -lt $models.Count; $i++) { Write-Host ("  {0,3}. {1}" -f ($i + 1), $models[$i]) }
    $answer = (Read-Host '  Номер модели (Enter — 1)').Trim()
    if (-not $answer) { return $models[0] }
    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $models.Count) { return $models[$n - 1] }
    $answer
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
    $link = $shell.CreateShortcut((Join-Path $startup 'ИИ-помощник 1С DeepSeek — мост.lnk'))
    $link.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $link.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$(Join-Path $toolRoot 'ai-bridge.ps1')`""
    $link.WorkingDirectory = $toolRoot
    $link.Description = 'Мост между чатом ИИ-помощника в 1С и DeepSeek'
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
Write-Host 'Установка ИИ-помощника 1С DeepSeek' -ForegroundColor Cyan
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

    Write-Step '2. DeepSeek'
    $config = $null
    try { $config = Get-DeepSeekConfig } catch {}
    while ($true) {
        if (-not $config) {
            Write-Host '  Нужен ключ API DeepSeek (platform.deepseek.com → API keys). Ключ сохранится в deepseek.json в этой папке.'
            Write-Host '  Вставить ключ: правой кнопкой мыши в окне или Ctrl+V. Символы на экране не появятся — так и должно быть.'
            $secure = Read-Host '  Ключ API' -AsSecureString
            $raw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
            # При копировании из браузера к ключу иногда прилипают пробелы, переводы строк и невидимые символы.
            $key = -join ($raw.ToCharArray() | Where-Object { [int]$_ -gt 32 -and [int]$_ -lt 127 })
            if (-not $key) { Write-Host '  Ключ не вставился — попробуйте вставить правой кнопкой мыши.' -ForegroundColor Red; continue }
            Write-Host ("  Принят ключ: {0}… ({1} символов)" -f $key.Substring(0, [Math]::Min(6, $key.Length)), $key.Length)
            if ($key.Length -ne $raw.Trim().Length) { Write-Host '  Из ключа убраны пробелы и невидимые символы.' -ForegroundColor DarkGray }
            $url = (Read-Host '  Адрес API (Enter — https://api.deepseek.com)').Trim()
            $model = (Read-Host '  Модель (Enter — выбрать из списка доступных по ключу)').Trim()
            $config = [pscustomobject]@{
                apiKey  = $key
                model   = $model
                baseUrl = $(if ($url) { $url.TrimEnd('/') } else { 'https://api.deepseek.com' })
            }
        }
        if (-not $config.model) {
            $models = Get-AvailableModels $config
            if ($models) { Write-Host '  Доступные по вашему ключу модели:'; $config.model = Select-Model $models }
            else { $config.model = 'deepseek-chat' }
        }
        Write-Host "  Проверяю ключ: $($config.baseUrl), модель $($config.model)..."
        $problem = Test-DeepSeekKey $config
        if (-not $problem) { break }
        Write-Host "  DeepSeek не принял запрос: $problem" -ForegroundColor DarkYellow
        if ($problem -match 'model' -and $problem -notmatch 'HTTP 401') {
            # Ключ и адрес верные, не подошло имя модели: предлагаем выбрать из тех, что доступны по ключу.
            $models = Get-AvailableModels $config
            if ($models) {
                Write-Host '  Доступные по вашему ключу модели:'
                $config.model = Select-Model $models
                continue
            }
        }
        $config = $null
    }    Save-DeepSeekConfig $config
    Write-Ok "ключ работает, модель $($config.model)"
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
    Write-Ok 'запущен (свёрнутое окно «ИИ-помощник 1С DeepSeek — мост»)'

    Write-Host ''
    Write-Host 'Готово! Откройте базу в 1С:Предприятии и нажмите раздел «ИИ-помощник DeepSeek».' -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "Установка прервана: $_" -ForegroundColor Red
}
