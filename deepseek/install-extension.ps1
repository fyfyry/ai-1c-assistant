# Устанавливает (или обновляет) расширение ИИ-помощника DeepSeek (ИИПомощникDeepSeek) в базу, сразу делает первую выгрузку
# конфигурации и добавляет базу в bases.json, если её там ещё нет.
#   Новая файловая база:  install-extension.ps1 -File "D:\Базы\ERP" -User Администратор [-Password ...] [-Name ERP] [-EpfFolders "D:\Обработки"]
#   Новая серверная база: install-extension.ps1 -Server localhost -Ref erp -User Администратор [-Password ...]
#   База из bases.json:   install-extension.ps1 -Base "БГУ демо"
#   Хранилище конфигурации (для новой или уже подключённой базы):
#     ... -RepoPath "D:\Хранилища\ERP" (или tcp://сервер/ERP) -RepoUser ИИПомощник [-RepoPassword ...] [-RepoDepth 20]
# База должна быть свободна: закройте Конфигуратор и сеансы 1С:Предприятия.
param(
    [string]$Base,
    [string]$File,
    [string]$Server,
    [string]$Ref,
    [string]$User = '',
    [string]$Password = '',
    [string]$Name,
    [string[]]$EpfFolders = @(),
    [string]$RepoPath,
    [string]$RepoUser = '',
    [string]$RepoPassword = '',
    [int]$RepoDepth = 20
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'ai-common.ps1')

if ($Base) {
    $baseInfo = Find-Base $Base
    $isNew = $false
} else {
    if ($File) { $File = (Resolve-Path $File).Path.TrimEnd('\') }
    elseif (-not ($Server -and $Ref)) { throw 'Укажите -Base, или -File, или -Server и -Ref' }

    # Та же база уже может быть в bases.json под другим именем.
    $baseInfo = Get-Bases | Where-Object {
        ($File -and $_.file -and $_.file.TrimEnd('\') -eq $File) -or
        (-not $File -and $_.server -eq $Server -and $_.ref -eq $Ref)
    } | Select-Object -First 1
    $isNew = -not $baseInfo
    if ($isNew) {
        if (-not $Name) { $Name = if ($File) { Split-Path $File -Leaf } else { $Ref } }
        $baseInfo = [ordered]@{ name = $Name }
        if ($File) { $baseInfo.file = $File } else { $baseInfo.server = $Server; $baseInfo.ref = $Ref }
        $baseInfo.user = $User
        $baseInfo.password = $Password
        $baseInfo.epfFolders = @($EpfFolders)
        $baseInfo = [pscustomobject]$baseInfo
        if (Get-Bases | Where-Object { $_.name -eq $baseInfo.name }) {
            throw "В bases.json уже есть база с именем «$($baseInfo.name)». Задайте другое имя параметром -Name."
        }
    }
}
if ($RepoPath) {
    $repo = [pscustomobject]@{ path = $RepoPath; user = $RepoUser; password = $RepoPassword; depth = $RepoDepth }
    $baseInfo | Add-Member -NotePropertyName repository -NotePropertyValue $repo -Force
}
"База: $($baseInfo.name)$(if ($isNew) { ' (новая)' })"
$exe = Find-1C
$work = Join-Path $env:TEMP 'ai-1c-install'
if (Test-Path $work) { [IO.Directory]::Delete($work, $true) }
New-Item -ItemType Directory -Force $work | Out-Null
$log = Join-Path $work 'install.log'

function Invoke-Designer($argString, $title) {
    if (Test-Path $log) { Remove-Item $log }
    $t = Get-Date
    $p = Start-Process $exe -ArgumentList "$(Get-ConnArgs $baseInfo) $argString /Out `"$log`"" -Wait -PassThru
    $text = Read-Log $log
    '{0}: код {1}, {2} с' -f $title, $p.ExitCode, [int]((Get-Date) - $t).TotalSeconds
    if ($text) { $text }
    if ($text -match 'ОбъектРасширяемойКонфигурации') {
        'Подсказка: основная конфигурация базы отличается от конфигурации БД. Откройте базу в Конфигураторе,'
        'выполните «Обновить конфигурацию базы данных» (F7) и запустите установку ещё раз.'
    }
    if ($p.ExitCode -ne 0) { throw "$title не выполнено" }
}

function Save-Xml($xml, $path) {
    $settings = New-Object Xml.XmlWriterSettings
    $settings.Encoding = New-Object Text.UTF8Encoding $true
    $settings.Indent = $true
    $settings.IndentChars = "`t"
    $writer = [Xml.XmlWriter]::Create($path, $settings)
    $xml.Save($writer)
    $writer.Close()
}

# 1. Узнаём основной язык конфигурации базы: расширение должно заимствовать именно его,
#    с тем же внутренним идентификатором, иначе 1С расширение не примет.
$probe = Join-Path $work 'probe'
$list = Join-Path $work 'list.txt'
[IO.File]::WriteAllText($list, "Configuration`r`n", (New-Object Text.UTF8Encoding $true))
Invoke-Designer "/DumpConfigToFiles `"$probe`" -listFile `"$list`"" 'Чтение свойств конфигурации'
$cfg = [xml](Get-Content (Join-Path $probe 'Configuration.xml') -Raw -Encoding UTF8)
$languageName = ([string]$cfg.MetaDataObject.Configuration.Properties.DefaultLanguage) -replace '^Language\.', ''
"Конфигурация: $($cfg.MetaDataObject.Configuration.Properties.Name), основной язык: $languageName"

[IO.File]::WriteAllText($list, "Language.$languageName`r`n", (New-Object Text.UTF8Encoding $true))
Invoke-Designer "/DumpConfigToFiles `"$probe`" -listFile `"$list`"" 'Чтение языка'
$lang = [xml](Get-Content (Join-Path $probe "Languages\$languageName.xml") -Raw -Encoding UTF8)
$langUuid = $lang.MetaDataObject.Language.uuid
$langCode = [string]$lang.MetaDataObject.Language.Properties.LanguageCode

# 2. Копия исходников расширения, настроенная на язык этой базы.
$ext = Join-Path $work 'ext'
Copy-Item (Join-Path $PSScriptRoot 'ext') $ext -Recurse
$langFile = Join-Path $ext 'Languages\Русский.xml'
$extLang = [xml](Get-Content $langFile -Raw -Encoding UTF8)
$props = $extLang.MetaDataObject.Language.Properties
$props.Name = $languageName
$props.ExtendedConfigurationObject = $langUuid
$props.LanguageCode = $langCode
Remove-Item $langFile
Save-Xml $extLang (Join-Path $ext "Languages\$languageName.xml")

$extCfgFile = Join-Path $ext 'Configuration.xml'
$extCfg = [xml](Get-Content $extCfgFile -Raw -Encoding UTF8)
$extCfg.MetaDataObject.Configuration.Properties.DefaultLanguage = "Language.$languageName"
# Контролируемые свойства корня: 1С требует, чтобы в расширении они совпадали с расширяемой конфигурацией.
foreach ($prop in 'InterfaceCompatibilityMode', 'ScriptVariant', 'DefaultRunMode') {
    $value = [string]$cfg.MetaDataObject.Configuration.Properties.$prop
    if ($value) { $extCfg.MetaDataObject.Configuration.Properties.$prop = $value }
}
$extCfg.MetaDataObject.Configuration.ChildObjects.Language = $languageName
Save-Xml $extCfg $extCfgFile

# 3. Загрузка, обновление БД и проверка модулей.
Invoke-Designer "/LoadConfigFromFiles `"$ext`" -Extension ИИПомощникDeepSeek" 'Загрузка расширения'
Invoke-Designer '/UpdateDBCfg -Extension ИИПомощникDeepSeek' 'Обновление БД'
Invoke-Designer '/CheckModules -ThinClient -Server -Extension ИИПомощникDeepSeek' 'Проверка модулей'

# 4. Первая выгрузка — сразу при установке, без ограничения по времени: у больших конфигураций
#    (ERP) полная выгрузка идёт час и больше, а потом мост выгружает только изменения за секунды.
$workspace = Get-Workspace $baseInfo
$dumpDir = Join-Path $workspace 'cfdump'
# Если эта база уже подключена к ИИ-помощнику на Claude (папка уровнем выше), берём его выгрузку:
# скопировать её намного быстрее, чем выгружать большую конфигурацию заново.
$parentBases = Join-Path (Split-Path $toolRoot) 'bases.json'
if (-not (Test-Path (Join-Path $dumpDir 'ConfigDumpInfo.xml')) -and (Test-Path $parentBases)) {
    $twin = (Get-Content $parentBases -Raw -Encoding UTF8 | ConvertFrom-Json).bases | Where-Object {
        ($baseInfo.file -and $_.file -and $_.file.TrimEnd('\') -eq $baseInfo.file.TrimEnd('\')) -or
        ($baseInfo.server -and $_.server -eq $baseInfo.server -and $_.ref -eq $baseInfo.ref)
    } | Select-Object -First 1
    $twinDump = if ($twin) { Join-Path (Join-Path (Join-Path (Split-Path $toolRoot) 'workspaces') (Get-SafeName $twin.name)) 'cfdump' }
    if ($twinDump -and (Test-Path (Join-Path $twinDump 'ConfigDumpInfo.xml'))) {
        'Копирую готовую выгрузку конфигурации из ИИ-помощника на Claude...'
        Copy-Item $twinDump $dumpDir -Recurse
        # Метки обезличивания в скопированных модулях — из таблицы той папки, её тоже берём.
        $twinMap = Join-Path (Join-Path (Join-Path (Split-Path $toolRoot) 'private') (Get-SafeName $twin.name)) 'pii-map.txt'
        if (Test-Path $twinMap) { Copy-Item $twinMap (Join-Path (Get-PrivateDir $baseInfo) 'pii-map.txt') -Force }
        Copy-Item (Join-Path (Join-Path (Join-Path (Split-Path $toolRoot) 'private') (Get-SafeName $twin.name)) 'dump-protected.txt') (Get-PrivateDir $baseInfo) -ErrorAction SilentlyContinue
    }
}
if (Test-Path (Join-Path $dumpDir 'ConfigDumpInfo.xml')) {
    Invoke-Designer "/DumpConfigToFiles `"$dumpDir`" -update" 'Обновление выгрузки конфигурации'
} else {
    'Полная выгрузка конфигурации: у больших конфигураций это может занять час и больше, не закрывайте окно...'
    Invoke-Designer "/DumpConfigToFiles `"$dumpDir`"" 'Выгрузка конфигурации'
}
$extDumpDir = Join-Path $workspace 'cfdump-ext'
if (Test-Path $extDumpDir) { [IO.Directory]::Delete($extDumpDir, $true) }
Invoke-Designer "/DumpConfigToFiles `"$extDumpDir`" -AllExtensions" 'Выгрузка расширений'

# 5. Персональные данные в модулях заменяем метками сразу, чтобы первое открытие чата не ждало.
'Обезличиваю модули конфигурации: при первой установке это занимает от минуты до 15 минут, окно не закрывайте...'
$protected = Protect-Dump $baseInfo $workspace
"Обезличено модулей: $protected"

# 6. Новую базу добавляем в bases.json только после успешной установки; запущенный мост подхватит её сам.
if ($isNew) {
    Save-Bases (@(Get-Bases) + $baseInfo)
    "База «$($baseInfo.name)» добавлена в bases.json."
} elseif ($RepoPath) {
    Save-Bases (@(Get-Bases | ForEach-Object { if ($_.name -eq $baseInfo.name) { $baseInfo } else { $_ } }))
    "Хранилище конфигурации записано в bases.json."
}

[IO.Directory]::Delete($work, $true)
"Готово: расширение ИИ-помощника установлено в базу «$($baseInfo.name)», выгрузка готова."
"Внешние обработки мост разберёт при первом открытии чата. Если мост ещё не запущен — запустите ai-bridge.cmd."
if ($baseInfo.repository -and $baseInfo.repository.path) {
    Start-RepoSync $baseInfo
    "История хранилища загружается в фоне (журнал — private\$(Get-SafeName $baseInfo.name)\repo-sync.log)."
}
''
'Если при открытии чата 1С напишет, что расширение работает в безопасном режиме: откройте'
'«Администрирование — Печатные формы, отчеты и обработки — Расширения» (или «Все функции — Стандартные —'
'Управление расширениями конфигурации»), снимите у ИИПомощникDeepSeek флажок «Безопасный режим» и перезапустите 1С.'
