[CmdletBinding(DefaultParameterSetName = 'Paths')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Paths')]
    [string[]]$InputPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Range')]
    [string]$InputDirectory,

    [Parameter(Mandatory = $true, ParameterSetName = 'Range')]
    [string]$FilePrefix,

    [Parameter(Mandatory = $true, ParameterSetName = 'Range')]
    [int]$StartPage,

    [Parameter(Mandatory = $true, ParameterSetName = 'Range')]
    [int]$EndPage,

    [string]$OutputPath,

    [string]$LanguageTag = 'zh-Hans-CN'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]

$asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1
    } |
    Select-Object -First 1

if (-not $asTaskMethod) {
    throw 'Unable to locate the WinRT AsTask bridge.'
}

function Wait-WinRtOperation {
    param(
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)][Type]$ResultType
    )

    $method = $script:asTaskMethod.MakeGenericMethod($ResultType)
    $task = $method.Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Format-OcrLine {
    param([string]$Text)

    $formatted = $Text -replace '(?<=[\u3400-\u9FFF])\s+(?=[\u3400-\u9FFF])', ''
    $formatted = $formatted -replace '\s+([，。；：、）》】])', '$1'
    $formatted = $formatted -replace '([（《【])\s+', '$1'
    $formatted = $formatted -replace '(?<=\d)\s*[．.]\s*(?=\d)', '.'
    return $formatted.Trim()
}

$language = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages |
    Where-Object { $_.LanguageTag -eq $LanguageTag } |
    Select-Object -First 1
if (-not $language) {
    $available = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages.LanguageTag -join ', '
    throw "OCR language '$LanguageTag' is unavailable. Available languages: $available"
}
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
if (-not $engine) {
    $available = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages.LanguageTag -join ', '
    throw "OCR language '$LanguageTag' is unavailable. Available languages: $available"
}

$resolvedInputs = if ($PSCmdlet.ParameterSetName -eq 'Range') {
    if ($StartPage -lt 1 -or $EndPage -lt $StartPage) {
        throw "Invalid page range: $StartPage-$EndPage"
    }
    $resolvedDirectory = (Resolve-Path -LiteralPath $InputDirectory).Path
    foreach ($page in $StartPage..$EndPage) {
        $candidate = Join-Path $resolvedDirectory ("{0}{1:D4}.png" -f $FilePrefix, $page)
        Resolve-Path -LiteralPath $candidate
    }
}
else {
    foreach ($candidate in $InputPath) {
        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($candidate)) {
            Resolve-Path -Path $candidate
        }
        else {
            Resolve-Path -LiteralPath $candidate
        }
    }
}

$sections = foreach ($pathInfo in ($resolvedInputs | Sort-Object Path)) {
    $resolved = $pathInfo.Path
    $file = Wait-WinRtOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($resolved)) ([Windows.Storage.StorageFile])
    $stream = Wait-WinRtOperation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoder = Wait-WinRtOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        try {
            $result = Wait-WinRtOperation ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
            $recognizedLines = $result.Lines | ForEach-Object { Format-OcrLine $_.Text }
            $recognizedText = $recognizedLines -join "`r`n"
            "===== IMAGE $([System.IO.Path]::GetFileName($resolved)) =====`r`n$recognizedText"
        }
        finally {
            if ($bitmap -is [System.IDisposable]) { $bitmap.Dispose() }
        }
    }
    finally {
        if ($stream -is [System.IDisposable]) { $stream.Dispose() }
    }
}

$text = ($sections -join "`r`n`r`n") + "`r`n"
if ($OutputPath) {
    $fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = [System.IO.Path]::GetDirectoryName($fullOutputPath)
    if ($outputDirectory) {
        [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    }
    [System.IO.File]::WriteAllText($fullOutputPath, $text, [System.Text.UTF8Encoding]::new($false))
    Write-Output $fullOutputPath
}
else {
    Write-Output $text
}
