# Подготовка внешних обработок и отчётов к подключению в 1С:Предприятии.
# Подключается в ai-build.ps1 и вызывается перед сборкой — для копии исходников, не для output.
#   - СведенияОВнешнейОбработке() в модуле объекта: без неё обработку нельзя добавить
#     в «Дополнительные отчеты и обработки» (БСП). Функция пишется без вызовов БСП,
#     поэтому компилируется в любой конфигурации, а БСП принимает её как есть.
# Добавляется, только если помощник не написал её сам. Справку и кнопку «Справка» в обработки
# не добавляем — их помощник делает, только если попросит пользователь. Возвращает список добавленного.

function Get-XmlText($node) {
    if ($null -eq $node) { return '' }
    $content = $node.SelectSingleNode(".//*[local-name()='content']")
    if ($content) { return $content.InnerText }
    $node.InnerText
}

function New-RegistrationFunction($kind, $title, $hasForm) {
    $vid = if ($kind -eq 'ExternalReport') { 'ДополнительныйОтчет' } else { 'ДополнительнаяОбработка' }
    $command = if ($kind -eq 'ExternalReport' -or $hasForm) { 'ОткрытиеФормы' } else { 'ВызовСерверногоМетода' }
    $title = $title.Replace('"', '""')
@"

#Если Сервер Или ТолстыйКлиентОбычноеПриложение Или ВнешнееСоединение Тогда

#Область СведенияДляРегистрации

// Сведения для подключения в «Дополнительные отчеты и обработки» (БСП).
// Добавлено ИИ-помощником автоматически — при необходимости поправьте версию и команды.
//
// Возвращаемое значение:
//   Структура
//
Функция СведенияОВнешнейОбработке() Экспорт

	ПараметрыРегистрации = Новый Структура;
	ПараметрыРегистрации.Вставить("Вид", "$vid");
	ПараметрыРегистрации.Вставить("Назначение", Новый Массив);
	ПараметрыРегистрации.Вставить("Наименование", "$title");
	ПараметрыРегистрации.Вставить("Версия", "1.0");
	ПараметрыРегистрации.Вставить("БезопасныйРежим", Истина);
	ПараметрыРегистрации.Вставить("Информация", "$title");

	Команды = Новый ТаблицаЗначений;
	Команды.Колонки.Добавить("Представление");
	Команды.Колонки.Добавить("Идентификатор");
	Команды.Колонки.Добавить("Использование");
	Команды.Колонки.Добавить("ПоказыватьОповещение");
	Команды.Колонки.Добавить("Модификатор");

	Команда = Команды.Добавить();
	Команда.Представление = "$title";
	Команда.Идентификатор = "Открыть";
	Команда.Использование = "$command";
	Команда.ПоказыватьОповещение = Ложь;

	ПараметрыРегистрации.Вставить("Команды", Команды);
	Возврат ПараметрыРегистрации;

КонецФункции

#КонецОбласти

#КонецЕсли
"@
}

# Подготавливает копию проекта обработки или отчёта. $info — из Get-ProjectInfo.
function Add-ExternalRegistration($info) {
    $added = @()
    $projectDir = Split-Path $info.root
    $objectDir = Join-Path $projectDir $info.name
    [xml]$root = Get-Content $info.root -Raw -Encoding UTF8
    $props = $root.MetaDataObject.FirstChild.Properties
    if (-not $props) { $props = ($root.MetaDataObject.ChildNodes | Where-Object { $_.Properties } | Select-Object -First 1).Properties }
    $title = (Get-XmlText $props.Synonym).Trim()
    if (-not $title) { $title = $info.name }
    $forms = @(Get-ChildItem (Join-Path $objectDir 'Forms') -Filter *.xml -File -ErrorAction SilentlyContinue)

    # 1. СведенияОВнешнейОбработке
    $module = Join-Path $objectDir 'Ext\ObjectModule.bsl'
    $code = if (Test-Path $module) { [IO.File]::ReadAllText($module, [Text.Encoding]::UTF8) } else { '' }
    if ($code -notmatch 'Функция\s+СведенияОВнешнейОбработке\s*\(') {
        New-Item -ItemType Directory -Force (Split-Path $module) | Out-Null
        [IO.File]::WriteAllText($module, $code.TrimEnd() + "`r`n" + (New-RegistrationFunction $info.kind $title ($forms.Count -gt 0)), (New-Object Text.UTF8Encoding $true))
        $added += 'сведения для регистрации (СведенияОВнешнейОбработке)'
    }

    $added
}
