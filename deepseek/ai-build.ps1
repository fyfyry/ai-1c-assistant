# Сборка внешних обработок, отчётов и расширений, которые помощник пишет в папку output рабочей папки.
# Подключается в мосте через dot-source (нужны Wait-WithHeartbeat и Touch-Alive моста).
#
# Как устроено:
#   - помощник кладёт исходники в формате выгрузки 1С в output\<Имя>\ — так же, как они лежат
#     в cfdump-epf и cfdump-ext; шаблоны — в папке templates рабочей папки;
#   - для сборки и проверки держим служебную базу private\<база>\build-ib с копией основной
#     конфигурации (рабочая база не меняется); её пересоздаём, когда меняется конфигурация;
#   - обработка и отчёт: синтаксис модулей проверяем, временно загрузив их в служебную базу как
#     обычную обработку/отчёт в расширении «ПроверкаИИ», затем собираем .epf/.erf;
#   - расширение: загружаем в служебную базу, проверяем модули и выгружаем в .cfe;
#   - готовые файлы — в папке «Готовые файлы\<база>» рядом с мостом.

. (Join-Path $PSScriptRoot 'ai-registration.ps1')

$buildCheckExtension = 'ПроверкаИИ'

function Get-BuildDir($base) { Join-Path (Get-PrivateDir $base) 'build' }

function Get-ResultDir($base) {
    $dir = Join-Path (Join-Path $toolRoot 'Готовые файлы') (Get-SafeName $base.name)
    New-Item -ItemType Directory -Force $dir | Out-Null
    $dir
}

# Шаблоны для помощника: копируем из папки пакета в рабочую папку базы.
function Copy-Templates($workspace) {
    $src = Join-Path $toolRoot 'templates'
    if (-not (Test-Path $src)) { return }
    $dst = Join-Path $workspace 'templates'
    if (Test-Path $dst) { [IO.Directory]::Delete($dst, $true) }
    Copy-Item $src $dst -Recurse
    New-Item -ItemType Directory -Force (Join-Path $workspace 'output') | Out-Null
}

# Конфигуратор на служебной базе (в ней нет пользователей).
function Invoke-BuildDesigner($base, $argString, $timeoutSec) {
    $dir = Get-BuildDir $base
    $log = Join-Path $dir 'designer.log'
    if (Test-Path $log) { Remove-Item $log }
    $p = Start-Process $oneCExe -ArgumentList "DESIGNER /F `"$(Join-Path $dir 'ib')`" /DisableStartupDialogs /DisableStartupMessages $argString /Out `"$log`"" -PassThru -WindowStyle Hidden
    $ok = (Wait-WithHeartbeat $p $timeoutSec) -and $p.ExitCode -eq 0
    @{ ok = $ok; log = (Read-Log $log) }
}

# Служебная база с копией основной конфигурации. Пересоздаётся, если выгрузка конфигурации новее.
function Initialize-BuildBase($base) {
    $dir = Get-BuildDir $base
    $ib = Join-Path $dir 'ib'
    $stampFile = Join-Path $dir 'config-stamp.txt'
    $dumpInfo = Join-Path (Join-Path (Get-Workspace $base) 'cfdump') 'ConfigDumpInfo.xml'
    if (-not (Test-Path $dumpInfo)) { throw 'Нет выгрузки конфигурации — откройте чат, чтобы мост её сделал.' }
    $stamp = (Get-Item $dumpInfo).LastWriteTimeUtc.Ticks.ToString()
    if ((Test-Path (Join-Path $ib '1Cv8.1CD')) -and (Test-Path $stampFile) -and ([IO.File]::ReadAllText($stampFile).Trim() -eq $stamp)) { return }

    Write-Host 'Готовлю служебную базу для сборки (копия конфигурации, один раз после её изменения)...' -ForegroundColor DarkGray
    if (Test-Path $dir) { [IO.Directory]::Delete($dir, $true) }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $p = Start-Process $oneCExe -ArgumentList "CREATEINFOBASE File=`"$ib`"" -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) { throw 'Не удалось создать служебную базу для сборки.' }

    # Конфигурацию берём из рабочей базы (.cf). Если базу держит открытый Конфигуратор — из копии
    # её файла; если и это не вышло — из XML-выгрузки (дольше, зато работает всегда).
    $cf = Join-Path $dir 'main.cf'
    $log = Join-Path $dir 'dumpcfg.log'
    $loaded = $false
    if (Start-Designer $base $null "/DumpCfg `"$cf`"" $log 3600) {
        $loaded = $true
    } elseif ($base.file) {
        $copyDir = Join-Path $dir 'copy'
        New-Item -ItemType Directory -Force $copyDir | Out-Null
        $copy = Start-Job { param($src, $dst) Copy-Item $src $dst } -ArgumentList (Join-Path $base.file '1Cv8.1CD'), $copyDir
        while ($copy.State -eq 'Running') { Touch-Alive; Start-Sleep 1 }
        Remove-Job $copy -Force
        $loaded = Start-Designer $base $copyDir "/DumpCfg `"$cf`"" $log 3600
        [IO.Directory]::Delete($copyDir, $true)
    }
    if ($loaded) {
        $r = Invoke-BuildDesigner $base "/LoadCfg `"$cf`"" 3600
    } else {
        $r = Invoke-BuildDesigner $base "/LoadConfigFromFiles `"$(Split-Path $dumpInfo)`"" 7200
    }
    if (Test-Path $cf) { Remove-Item $cf }
    if (-not $r.ok) { throw "Не удалось загрузить конфигурацию в служебную базу: $($r.log)" }
    [IO.File]::WriteAllText($stampFile, $stamp, $utf8)
}

# Проекты в output, изменённые после $since: папки с корневым XML обработки/отчёта или с Configuration.xml.
function Get-ChangedProjects($workspace, $since) {
    $output = Join-Path $workspace 'output'
    if (-not (Test-Path $output)) { return @() }
    foreach ($dir in Get-ChildItem $output -Directory) {
        $changed = Get-ChildItem $dir.FullName -Recurse -File | Where-Object { $_.LastWriteTime -ge $since } | Select-Object -First 1
        if ($changed) { $dir.FullName }
    }
}

# Тип проекта: ExternalDataProcessor, ExternalReport или Extension; корневой файл и имя.
function Get-ProjectInfo($projectDir) {
    $cfg = Join-Path $projectDir 'Configuration.xml'
    if (Test-Path $cfg) {
        [xml]$x = Get-Content $cfg -Raw -Encoding UTF8
        return @{ kind = 'Extension'; root = $cfg; name = [string]$x.MetaDataObject.Configuration.Properties.Name }
    }
    foreach ($xml in Get-ChildItem $projectDir -Filter *.xml -File) {
        $head = [IO.File]::ReadAllText($xml.FullName, [Text.Encoding]::UTF8)
        if ($head -match '<ExternalDataProcessor[\s>]') { return @{ kind = 'ExternalDataProcessor'; root = $xml.FullName; name = $xml.BaseName } }
        if ($head -match '<ExternalReport[\s>]') { return @{ kind = 'ExternalReport'; root = $xml.FullName; name = $xml.BaseName } }
    }
    $null
}

function Save-XmlFile($xml, $path) {
    $settings = New-Object Xml.XmlWriterSettings
    $settings.Encoding = New-Object Text.UTF8Encoding $true
    $settings.Indent = $true
    $settings.IndentChars = "`t"
    $writer = [Xml.XmlWriter]::Create($path, $settings)
    $xml.Save($writer)
    $writer.Close()
}

# Свойства, которые у расширения обязаны совпадать с основной конфигурацией: язык и режимы.
# Помощник может их не угадать — подставляем из выгрузки рабочей базы.
function Repair-ExtensionSources($base, $projectDir) {
    $dump = Join-Path (Get-Workspace $base) 'cfdump'
    [xml]$main = Get-Content (Join-Path $dump 'Configuration.xml') -Raw -Encoding UTF8
    $langName = ([string]$main.MetaDataObject.Configuration.Properties.DefaultLanguage) -replace '^Language\.', ''
    [xml]$lang = Get-Content (Join-Path $dump "Languages\$langName.xml") -Raw -Encoding UTF8

    $cfgFile = Join-Path $projectDir 'Configuration.xml'
    [xml]$ext = Get-Content $cfgFile -Raw -Encoding UTF8
    $props = $ext.MetaDataObject.Configuration.Properties
    foreach ($prop in 'InterfaceCompatibilityMode', 'ScriptVariant', 'DefaultRunMode') {
        $value = [string]$main.MetaDataObject.Configuration.Properties.$prop
        if ($value -and $props.$prop -ne $null) { $props.$prop = $value }
    }
    $props.DefaultLanguage = "Language.$langName"
    $langNodes = @($ext.MetaDataObject.Configuration.ChildObjects.ChildNodes | Where-Object { $_.LocalName -eq 'Language' })
    foreach ($node in $langNodes) {
        $old = Join-Path $projectDir "Languages\$($node.InnerText).xml"
        $node.InnerText = $langName
        $new = Join-Path $projectDir "Languages\$langName.xml"
        if ((Test-Path $old) -and $old -ne $new) { Move-Item $old $new -Force }
        if (Test-Path $new) {
            [xml]$l = Get-Content $new -Raw -Encoding UTF8
            $lp = $l.MetaDataObject.Language.Properties
            $lp.Name = $langName
            if ($lp.ExtendedConfigurationObject -ne $null) { $lp.ExtendedConfigurationObject = [string]$lang.MetaDataObject.Language.uuid }
            if ($lp.LanguageCode -ne $null) { $lp.LanguageCode = [string]$lang.MetaDataObject.Language.Properties.LanguageCode }
            Save-XmlFile $l $new
        }
    }
    Save-XmlFile $ext $cfgFile
}

# Ошибки из журнала проверки модулей — только строки с ошибками, без служебного текста.
function Get-CheckErrors($log) {
    @(($log -split "`r?`n") | Where-Object { $_ -match '\{.*\}|Ошибка|ошибка|Error' -and $_ -notmatch 'не обнаружено' } | Select-Object -First 30) -join "`n"
}

# Проверка синтаксиса обработки/отчёта: копия исходников как обычная обработка/отчёт
# во временном расширении служебной базы, затем /CheckModules.
function Test-ExternalSyntax($base, $info) {
    $tmp = Join-Path (Get-BuildDir $base) 'check'
    if (Test-Path $tmp) { [IO.Directory]::Delete($tmp, $true) }
    $isReport = $info.kind -eq 'ExternalReport'
    $folder = if ($isReport) { 'Reports' } else { 'DataProcessors' }
    $projectDir = Split-Path $info.root
    $name = $info.name

    # Файлы объекта: корневой XML и одноимённая папка.
    New-Item -ItemType Directory -Force (Join-Path $tmp $folder) | Out-Null
    Copy-Item (Join-Path $projectDir $name) (Join-Path (Join-Path $tmp $folder) $name) -Recurse -ErrorAction SilentlyContinue
    $fromType = if ($isReport) { 'ExternalReport' } else { 'ExternalDataProcessor' }
    $toType = if ($isReport) { 'Report' } else { 'DataProcessor' }
    $rootText = [IO.File]::ReadAllText($info.root, [Text.Encoding]::UTF8)
    $rootText = [regex]::Replace($rootText, '(?s)\s*<xr:ContainedObject>.*?</xr:ContainedObject>', '')
    $rootText = $rootText.Replace("<$fromType ", "<$toType ").Replace("</$fromType>", "</$toType>").Replace("${fromType}Object.", "${toType}Object.").Replace("$fromType.", "$toType.")
    if ($rootText -notmatch "${toType}Manager\.") {
        $manager = "<xr:GeneratedType name=`"${toType}Manager.$name`" category=`"Manager`"><xr:TypeId>$([guid]::NewGuid())</xr:TypeId><xr:ValueId>$([guid]::NewGuid())</xr:ValueId></xr:GeneratedType></InternalInfo>"
        $rootText = ([regex]'</InternalInfo>').Replace($rootText, $manager, 1)
    }
    [IO.File]::WriteAllText((Join-Path (Join-Path $tmp $folder) "$name.xml"), $rootText, (New-Object Text.UTF8Encoding $true))
    foreach ($f in Get-ChildItem (Join-Path $tmp $folder) -Recurse -Filter *.xml) {
        $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $n = $t.Replace("cfg:${fromType}Object.", "cfg:${toType}Object.").Replace("$fromType.$name.", "$toType.$name.")
        if ($n -ne $t) { [IO.File]::WriteAllText($f.FullName, $n, (New-Object Text.UTF8Encoding $true)) }
    }

    # Временное расширение из шаблона: язык и режимы подставит Repair-ExtensionSources.
    $tplExt = Join-Path $toolRoot 'templates\Расширение'
    Copy-Item (Join-Path $tplExt 'Configuration.xml') $tmp
    Copy-Item (Join-Path $tplExt 'Languages') $tmp -Recurse
    [xml]$cfg = Get-Content (Join-Path $tmp 'Configuration.xml') -Raw -Encoding UTF8
    $cfg.MetaDataObject.Configuration.Properties.Name = $buildCheckExtension
    $cfg.MetaDataObject.Configuration.Properties.NamePrefix = ''
    $children = $cfg.MetaDataObject.Configuration.ChildObjects
    foreach ($node in @($children.ChildNodes | Where-Object { $_.LocalName -ne 'Language' })) { [void]$children.RemoveChild($node) }
    $el = $cfg.CreateElement($toType, $cfg.DocumentElement.NamespaceURI)
    $el.InnerText = $name
    [void]$children.AppendChild($el)
    Save-XmlFile $cfg (Join-Path $tmp 'Configuration.xml')
    Repair-ExtensionSources $base $tmp

    $r = Invoke-BuildDesigner $base "/LoadConfigFromFiles `"$tmp`" -Extension $buildCheckExtension" 600
    if (-not $r.ok) { return "Не удалось загрузить исходники для проверки:`n$($r.log)" }
    $r = Invoke-BuildDesigner $base "/CheckModules -ThinClient -Server -Extension $buildCheckExtension" 600
    if (-not $r.ok) { return "Ошибки в модулях:`n$(Get-CheckErrors $r.log)" }
    ''
}

# Копия исходников для сборки, в которой метки обезличивания заменены настоящими значениями:
# в готовом файле должны быть реальные данные, а в output (его читает модель) остаются метки.
function Copy-ProjectForBuild($base, $projectDir) {
    $dst = Join-Path (Join-Path (Get-BuildDir $base) 'src') (Split-Path $projectDir -Leaf)
    if (Test-Path $dst) { [IO.Directory]::Delete($dst, $true) }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $projectDir $dst -Recurse
    $pii = Get-Anonymizer $base
    $pii.Begin()
    try {
        foreach ($f in Get-ChildItem $dst -Recurse -File | Where-Object { $_.Extension -in '.bsl', '.xml', '.txt' }) {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
            $restored = $pii.Restore($text)
            if ($restored -ne $text) { [IO.File]::WriteAllText($f.FullName, $restored, (New-Object Text.UTF8Encoding $bom)) }
        }
    } finally {
        $pii.End()
    }
    $dst
}

# Собирает один проект. Возвращает @{ ok; file; text } — text: что сообщить пользователю и модели.
function Build-Project($base, $projectDir) {
    $rel = 'output/' + (Split-Path $projectDir -Leaf)
    if (-not (Get-ProjectInfo $projectDir)) { return @{ ok = $false; text = "В папке $rel нет корневого XML обработки или отчёта и нет Configuration.xml расширения." } }
    try {
        Initialize-BuildBase $base
        $projectDir = Copy-ProjectForBuild $base $projectDir
        $info = Get-ProjectInfo $projectDir
        $resultDir = Get-ResultDir $base
        if ($info.kind -eq 'Extension') {
            Repair-ExtensionSources $base $projectDir
            $target = Join-Path $resultDir "$($info.name).cfe"
            $r = Invoke-BuildDesigner $base "/LoadConfigFromFiles `"$projectDir`" -Extension $($info.name)" 600
            if (-not $r.ok) { return @{ ok = $false; text = "Расширение $($info.name) ($rel) не загрузилось:`n$($r.log)" } }
            $check = Invoke-BuildDesigner $base "/CheckModules -ThinClient -Server -Extension $($info.name)" 600
            if (-not $check.ok) { return @{ ok = $false; text = "Расширение $($info.name) ($rel): ошибки в модулях:`n$(Get-CheckErrors $check.log)" } }
            if (Test-Path $target) { Remove-Item $target }
            $r = Invoke-BuildDesigner $base "/DumpCfg `"$target`" -Extension $($info.name)" 600
            if (-not $r.ok) { return @{ ok = $false; text = "Расширение $($info.name): не удалось сохранить файл .cfe:`n$($r.log)" } }
        } else {
            # Сведения для подключения в «Дополнительные отчеты и обработки», справка и кнопка «Справка».
            $added = @(Add-ExternalRegistration $info)
            $problem = Test-ExternalSyntax $base $info
            if ($problem) { return @{ ok = $false; text = "$($info.name) ($rel): $problem" } }
            $ext = if ($info.kind -eq 'ExternalReport') { '.erf' } else { '.epf' }
            $target = Join-Path $resultDir "$($info.name)$ext"
            if (Test-Path $target) { Remove-Item $target }
            $r = Invoke-BuildDesigner $base "/LoadExternalDataProcessorOrReportFromFiles `"$($info.root)`" `"$target`"" 600
            if (-not $r.ok -or -not (Test-Path $target)) { return @{ ok = $false; text = "$($info.name) ($rel) не собралась:`n$($r.log)" } }
        }
        $text = if ($added) { "$target (добавлено автоматически: $($added -join ', '))" } else { $target }
        @{ ok = $true; file = $target; text = $text }
    } catch {
        @{ ok = $false; text = "$($info.name) ($rel): $_" }
    }
}
