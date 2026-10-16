# Собирает архив для переноса на другой компьютер — без ваших баз, паролей, ключа API и выгрузок.
#   powershell -ExecutionPolicy Bypass -File make-package.ps1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
# Архив кладём рядом с архивом версии на Claude, а не внутрь её папки.
$zip = Join-Path (Split-Path (Split-Path $root)) 'ИИ-помощник 1С DeepSeek.zip'
$stage = Join-Path $env:TEMP 'ai-1c-package\ИИ-помощник 1С DeepSeek'
if (Test-Path (Split-Path $stage)) { [IO.Directory]::Delete((Split-Path $stage), $true) }
New-Item -ItemType Directory -Force $stage | Out-Null

$exclude = 'bases.json', 'platform.txt', 'deepseek.json', 'workspaces', 'private', 'Готовые файлы', 'make-package.ps1'
Get-ChildItem $root | Where-Object { $_.Name -notin $exclude } | Copy-Item -Destination $stage -Recurse

if (Test-Path $zip) { Remove-Item $zip }
# Архив собираем сами: Compress-Archive и ZipFile в PowerShell 5.1 пишут пути с «\»,
# а по стандарту ZIP разделитель — «/», иначе не все распаковщики поймут структуру папок.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    $base = Split-Path $stage
    foreach ($file in Get-ChildItem $stage -Recurse -File) {
        $entryName = $file.FullName.Substring($base.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, 'Optimal') | Out-Null
    }
} finally {
    $archive.Dispose()
}
[IO.Directory]::Delete((Split-Path $stage), $true)
"Архив готов: $zip"
