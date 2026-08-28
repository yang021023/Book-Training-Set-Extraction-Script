[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Init', 'List', 'Resume', 'Plan', 'Commit', 'SetNext', 'Compact')]
    [string]$Action,
    [string]$WorkspaceRoot,
    [string]$BookId,
    [string]$Title,
    [string]$PdfFile,
    [string]$JsonlFile,
    [string]$ActiveFile,
    [int]$PageCount,
    [int]$StartPage,
    [ValidateRange(1, 8)][int]$BatchPages = 8,
    [string]$BatchFile,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$WorkspaceRoot = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Join-Path $PSScriptRoot '..\..' } else { $WorkspaceRoot }
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:Root = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')
$script:Work = Join-Path $script:Root '_qa_work'

function Fail([string]$Message) { throw [InvalidOperationException]::new($Message) }
function Has($Object, [string]$Name) { return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] }
function Enter-CommitMutex([string]$Id) {
    $mutex = [Threading.Mutex]::new($false, "Local\manufacturing-document-qa-commit-$Id")
    try {
        if (-not $mutex.WaitOne(0)) {
            $mutex.Dispose()
            Fail "该书已有提交正在进行：$Id"
        }
    }
    catch [Threading.AbandonedMutexException] {
        # The previous owner exited unexpectedly; the mutex is now acquired.
    }
    return $mutex
}
function Save-Json([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temp = "$Path.tmp"
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 12), $script:Utf8)
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
function State-Path([string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id) -or $Id.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Id.Contains('\') -or $Id.Contains('/')) { Fail 'BookId 无效。' }
    return Join-Path (Join-Path $script:Work $Id) 'state.json'
}
function Count-Lines([string]$FileName) {
    $path = Join-Path $script:Root $FileName
    if (-not [IO.File]::Exists($path)) { return 0 }
    return @([IO.File]::ReadAllLines($path, $script:Utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}
function To-Lite($State) {
    if ([int]$State.schema_version -eq 2) { return $State }
    if (-not (Has $State 'source') -or -not (Has $State 'output')) { Fail '无法识别旧 state.json。' }
    $legacyComplete = [string]$State.mode -in @('completed', 'legacy_audit_required')
    $next = if ($legacyComplete) { $null } else { $State.progress.resume_pdf_page }
    $status = if ($null -eq $next) { 'completed' } else { 'active' }
    return [pscustomobject][ordered]@{
        schema_version = 2
        book_id = [string]$State.book_id
        title = [string]$State.title
        pdf_file = [string]$State.source.pdf_file
        jsonl_file = [string]$State.output.jsonl_file
        page_count = [int]$State.source.page_count
        next_page = $next
        record_count = Count-Lines ([string]$State.output.jsonl_file)
        status = $status
        updated_at = [DateTimeOffset]::Now.ToString('o')
    }
}
function Load-State([string]$Id) {
    $path = State-Path $Id
    if (-not [IO.File]::Exists($path)) { Fail "未找到书籍状态：$Id" }
    return To-Lite (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function All-States {
    if (-not [IO.Directory]::Exists($script:Work)) { return @() }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $script:Work -Directory | ForEach-Object { Join-Path $_.FullName 'state.json' } | Where-Object { Test-Path -LiteralPath $_ }) {
        try { $items.Add((To-Lite (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json))) }
        catch { Write-Warning "跳过无效状态：$file" }
    }
    return @($items)
}
function Find-State {
    if (-not [string]::IsNullOrWhiteSpace($BookId)) { return Load-State $BookId }
    if ([string]::IsNullOrWhiteSpace($ActiveFile)) { Fail '请提供 BookId 或 ActiveFile。' }
    $leaf = [IO.Path]::GetFileName($ActiveFile)
    $matches = @(All-States | Where-Object { $_.pdf_file -eq $leaf -or $_.jsonl_file -eq $leaf })
    if ($matches.Count -ne 1) { Fail "ActiveFile 无法唯一映射：$leaf" }
    return $matches[0]
}
function Emit($Value) {
    if ($AsJson) { $Value | ConvertTo-Json -Depth 10 -Compress } else { $Value | ConvertTo-Json -Depth 10 }
}
function Assert-RootFile([string]$Name, [string]$Extension, [switch]$MustExist) {
    if ([string]::IsNullOrWhiteSpace($Name) -or [IO.Path]::GetFileName($Name) -ne $Name -or -not $Name.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) { Fail "必须提供工作区根目录中的 $Extension 文件名。" }
    $path = Join-Path $script:Root $Name
    if ($MustExist -and -not [IO.File]::Exists($path)) { Fail "文件不存在：$Name" }
}
function Test-Record($Record, [Collections.Generic.HashSet[string]]$Questions) {
    if (@($Record.PSObject.Properties.Name).Count -ne 1 -or -not (Has $Record 'messages')) { return 'schema' }
    $m = @($Record.messages)
    if ($m.Count -ne 2 -or [string]$m[0].role -ne 'user' -or [string]$m[1].role -ne 'assistant') { return 'roles' }
    $q = [string]$m[0].content; $a = [string]$m[1].content
    if ([string]::IsNullOrWhiteSpace($q) -or [string]::IsNullOrWhiteSpace($a)) { return 'empty' }
    if ($Questions.Contains($q)) { return 'duplicate' }
    $text = "$q`n$a"
    $hard = '(?:本书|书中|原文|文中|教材中|本页|该页|页面)(?:.{0,6})(?:列出|列举|给出|介绍|指出|定义|显示|展示)|(?:参见|见)\s*(?:图|表)\s*\d+|第\s*\d+\s*页|点\s*\d+|(?<![A-Za-z0-9])N\s*\d+\s*(?:程序)?段|第\s*[一二三四五六七八九十]+\s*轮|程序\s*\d+\s*(?:中|里)|《[^》]{2,80}》(?:的|是)?(?:内容定位|教学定位|教学内容|内容组织|项目内容|编写特点|适用对象|读者对象)|(?:知识|能力|学习|教学|课程)目标|(?:项目|任务)\s*[一二三四五六七八九十0-9]+.{0,24}(?:要求学习|涉及哪些|引导案例|应具备哪些)|(?:完成|通过).{0,30}(?:项目|任务).{0,30}(?:掌握|学会|应具备|需要掌握)'
    if ($text -match $hard) { return 'source_dependency' }
    $ranges = [regex]::Matches($a, '[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*[～~—–-]\s*[+-]?(?:\d+(?:\.\d+)?|\.\d+)').Count
    if ($a.Length -gt 600 -and $ranges -ge 6) { return 'parameter_dump' }
    $Questions.Add($q) | Out-Null
    return $null
}

if (-not [IO.Directory]::Exists($script:Root)) { Fail "工作区不存在：$script:Root" }

switch ($Action) {
    'Init' {
        if ([string]::IsNullOrWhiteSpace($BookId) -or $PageCount -lt 1) { Fail 'Init 需要 BookId 和 PageCount。' }
        Assert-RootFile $PdfFile '.pdf' -MustExist
        Assert-RootFile $JsonlFile '.jsonl'
        $path = State-Path $BookId
        if ([IO.File]::Exists($path)) { Fail "状态已存在：$BookId" }
        $state = [pscustomobject][ordered]@{schema_version=2;book_id=$BookId;title=$(if($Title){$Title}else{$BookId});pdf_file=$PdfFile;jsonl_file=$JsonlFile;page_count=$PageCount;next_page=1;record_count=(Count-Lines $JsonlFile);status='active';updated_at=[DateTimeOffset]::Now.ToString('o')}
        Save-Json $path $state; Emit $state
    }
    'List' {
        Emit ([pscustomobject]@{books=@(All-States | Sort-Object book_id | Select-Object book_id,title,status,next_page,page_count,record_count,pdf_file,jsonl_file)})
    }
    'Resume' { Emit (Find-State) }
    'Plan' {
        $state = Find-State
        if ($state.status -eq 'completed' -or $null -eq $state.next_page) { Emit ([pscustomobject]@{book_id=$state.book_id;status='completed'}); break }
        $start = if ($StartPage -gt 0) { $StartPage } else { [int]$state.next_page }
        if ($start -lt 1 -or $start -gt [int]$state.page_count) { Fail '起始页越界。' }
        $end = [Math]::Min($start + $BatchPages - 1, [int]$state.page_count)
        Emit ([pscustomobject]@{book_id=$state.book_id;pdf_file=$state.pdf_file;jsonl_file=$state.jsonl_file;start_page=$start;end_page=$end;page_count=$state.page_count})
    }
    'SetNext' {
        $state = Find-State
        if ($StartPage -lt 1 -or $StartPage -gt ([int]$state.page_count + 1)) { Fail 'StartPage 越界。' }
        $state.next_page = if ($StartPage -gt [int]$state.page_count) { $null } else { $StartPage }
        $state.status = if ($null -eq $state.next_page) { 'completed' } else { 'active' }
        $state.updated_at = [DateTimeOffset]::Now.ToString('o')
        Save-Json (State-Path $state.book_id) $state; Emit $state
    }
    'Compact' {
        $targets = if ($BookId) { @(Load-State $BookId) } else { @(All-States) }
        foreach ($state in $targets) { Save-Json (State-Path $state.book_id) $state }
        Emit ([pscustomobject]@{compacted=$targets.Count;books=@($targets.book_id)})
    }
    'Commit' {
        if ([string]::IsNullOrWhiteSpace($BatchFile)) { Fail 'Commit 需要 BatchFile。' }
        $batchPath = [IO.Path]::GetFullPath((Join-Path $script:Root $BatchFile))
        if (-not $batchPath.StartsWith($script:Root + '\', [StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($batchPath)) { Fail 'BatchFile 必须位于工作区内且存在。' }
        $batch = Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $commitMutex = Enter-CommitMutex ([string]$batch.book_id)
        try {
            $state = Load-State ([string]$batch.book_id)
            if ($state.status -eq 'completed' -or $null -eq $state.next_page) { Fail '该书已完成。' }
            $start = [int]$batch.start_page; $end = [int]$batch.end_page
            if ($start -ne [int]$state.next_page -or $end -lt $start -or $end -gt [int]$state.page_count) { Fail "批次页码必须从 $($state.next_page) 开始且不得越界。" }
            $outputPath = Join-Path $script:Root $state.jsonl_file
            $oldLines = if ([IO.File]::Exists($outputPath)) { @([IO.File]::ReadAllLines($outputPath, $script:Utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { @() }
            $questions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($line in $oldLines) { try { $obj=$line|ConvertFrom-Json; if(@($obj.messages).Count -ge 1){$questions.Add([string]$obj.messages[0].content)|Out-Null} } catch { Fail '现有 JSONL 含无效 JSON，请先修复。' } }
            $accepted = [Collections.Generic.List[string]]::new(); $reasons = @{}
            foreach ($record in @($batch.records)) {
                $reason = Test-Record $record $questions
                if ($null -eq $reason) { $accepted.Add(($record | ConvertTo-Json -Depth 6 -Compress)) }
                else { if(-not $reasons.ContainsKey($reason)){$reasons[$reason]=0};$reasons[$reason]++ }
            }
            if ($accepted.Count -eq 0) { Fail '批次没有新增记录，拒绝推进页码。' }
            $all = [Collections.Generic.List[string]]::new(); foreach($line in $oldLines){$all.Add($line)}; foreach($line in $accepted){$all.Add($line)}
            $temp = "$outputPath.tmp"; [IO.File]::WriteAllLines($temp, $all, $script:Utf8); Move-Item -LiteralPath $temp -Destination $outputPath -Force
            $state.record_count = $all.Count
            $state.next_page = if ($end -ge [int]$state.page_count) { $null } else { $end + 1 }
            $state.status = if ($null -eq $state.next_page) { 'completed' } else { 'active' }
            $state.updated_at = [DateTimeOffset]::Now.ToString('o')
            Save-Json (State-Path $state.book_id) $state
        }
        finally {
            if ($null -ne $commitMutex) {
                try { $commitMutex.ReleaseMutex() } catch { }
                $commitMutex.Dispose()
            }
        }
        $tmpRoot = [IO.Path]::GetFullPath((Join-Path $script:Work 'tmp')).TrimEnd('\') + '\'
        if ($batchPath.StartsWith($tmpRoot, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $batchPath -Force }
        Emit ([pscustomobject]@{book_id=$state.book_id;pages="$start-$end";added=$accepted.Count;skipped=$reasons;total=$state.record_count;next_page=$state.next_page;status=$state.status})
    }
}
