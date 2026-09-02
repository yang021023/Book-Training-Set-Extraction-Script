[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Init', 'List', 'Resume', 'Plan', 'Commit', 'Augment', 'Validate', 'SetNext', 'Skip', 'Compact')]
    [string]$Action,
    [string]$WorkspaceRoot,
    [string]$BookId,
    [string]$Title,
    [string]$PdfFile,
    [string]$JsonlFile,
    [string]$ActiveFile,
    [int]$PageCount,
    [int]$StartPage,
    [ValidateRange(1, 12)][int]$BatchPages = 8,
    [string]$SkipReason,
    [string]$BatchFile,
    [switch]$LowYieldReviewed,
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
function Get-BatchReviewDigest($Batch) {
    # Exclude the review receipt itself so a failed first attempt can be retried unchanged.
    $payload = [ordered]@{
        book_id = [string]$Batch.book_id
        start_page = [int]$Batch.start_page
        end_page = [int]$Batch.end_page
        coverage = @($Batch.coverage)
        records = @($Batch.records)
    }
    $json = $payload | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Register-LowYieldRejection([string]$BatchPath, $Batch, [string]$Digest, [int]$Accepted, [int]$MinimumYield) {
    $receipt = [pscustomobject][ordered]@{
        digest = $Digest
        accepted = $Accepted
        minimum_yield = $MinimumYield
        rejected_at = [DateTimeOffset]::Now.ToString('o')
    }
    if (Has $Batch 'low_yield_rejection') { $Batch.low_yield_rejection = $receipt }
    else { $Batch | Add-Member -NotePropertyName low_yield_rejection -NotePropertyValue $receipt }
    Save-Json $BatchPath $Batch
}
function Assert-LowYieldReview($Batch, [string]$Digest) {
    if (-not (Has $Batch 'low_yield_rejection')) { Fail '低产放行必须先执行一次不含 -LowYieldReviewed 的提交并被拦截。' }
    if ([string]$Batch.low_yield_rejection.digest -ne $Digest) { Fail '低产批次在首次拦截后已变更；请先不带 -LowYieldReviewed 重新提交并完成复查。' }
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
    if ([int]$State.schema_version -eq 2) {
        if (-not (Has $State 'recent_commits')) {
            $State | Add-Member -NotePropertyName recent_commits -NotePropertyValue @()
        }
        return $State
    }
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
        recent_commits = @()
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
    $matches = @(All-States | Where-Object {
        [IO.Path]::GetFileName([string]$_.pdf_file) -eq $leaf -or
        [IO.Path]::GetFileName([string]$_.jsonl_file) -eq $leaf
    })
    if ($matches.Count -ne 1) { Fail "ActiveFile 无法唯一映射：$leaf" }
    return $matches[0]
}
function Emit($Value) {
    if ($AsJson) { $Value | ConvertTo-Json -Depth 10 -Compress } else { $Value | ConvertTo-Json -Depth 10 }
}
function Assert-WorkspaceFile([string]$Name, [string]$Extension, [switch]$MustExist) {
    if ([string]::IsNullOrWhiteSpace($Name) -or [IO.Path]::IsPathRooted($Name) -or -not $Name.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) { Fail "必须提供工作区内的相对 $Extension 文件路径。" }
    $path = [IO.Path]::GetFullPath((Join-Path $script:Root $Name))
    if (-not $path.StartsWith($script:Root + '\', [StringComparison]::OrdinalIgnoreCase)) { Fail "文件必须位于工作区内：$Name" }
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
    # 企业/书内工艺编码的“对象—分组代号”速查无法脱离原编号体系使用，禁止写入训练集。
    if ($q -match '(?:三位|两位|四位|\d+位)分组(?:代号|代码|编号)' -or $q -match '分别采用什么(?:三位|两位|四位|\d+位)分组') { return 'low_value_code_lookup' }
    # 通用标准中的型号、尺寸、公差和固定数值本身可以形成有效速查知识。
    # 只拦截书内/企业自编编号；是否为通用标准由源页覆盖清单和问答上下文确认，
    # 不能仅因问题包含型号或固定数值就在此处一概过滤。
    $hard = '(?:本书|书中|原文|文中|教材(?:中)?|本页|该页|页面)|(?:上图|下图|图中|表中|按图(?:示|样)|图示中|表格中)|(?:案例|示例|例题|实例)(?:中|里|的|条件(?:下)?)|(?:参见|见)\s*(?:图|表)\s*\d+|第\s*\d+\s*页|点\s*\d+|(?<![A-Za-z0-9])N\s*\d+\s*(?:程序)?段|第\s*[一二三四五六七八九十]+\s*轮|程序\s*\d+\s*(?:中|里)|《[^》]{2,80}》(?:的|是)?(?:内容定位|教学定位|教学内容|内容组织|项目内容|编写特点|适用对象|读者对象)|(?:知识|能力|学习|教学|课程)目标|(?:项目|任务)\s*[一二三四五六七八九十0-9]+.{0,24}(?:要求学习|涉及哪些|引导案例|应具备哪些)|(?:完成|通过).{0,30}(?:项目|任务).{0,30}(?:掌握|学会|应具备|需要掌握)'
    if ($text -match $hard) { return 'source_dependency' }
    $ranges = [regex]::Matches($a, '[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*[～~—–-]\s*[+-]?(?:\d+(?:\.\d+)?|\.\d+)').Count
    if ($a.Length -gt 600 -and $ranges -ge 6) { return 'parameter_dump' }
    $Questions.Add($q) | Out-Null
    return $null
}

function Get-BatchCoverage($Batch, [int]$Start, [int]$End) {
    if (-not (Has $Batch 'coverage')) { Fail '批次缺少逐页 coverage。' }
    $entries = @($Batch.coverage)
    $expectedPages = $End - $Start + 1
    if ($entries.Count -ne $expectedPages) { Fail "coverage 必须包含 $Start-$End 的每一页且每页一次。" }

    $candidateQuestions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in @($Batch.records)) {
        if (-not (Has $record 'messages') -or @($record.messages).Count -lt 1) { continue }
        $question = [string]@($record.messages)[0].content
        if (-not [string]::IsNullOrWhiteSpace($question)) { $candidateQuestions.Add($question) | Out-Null }
    }

    $seenPages = [Collections.Generic.HashSet[int]]::new()
    $coveredQuestions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $technicalPages = 0
    foreach ($entry in $entries) {
        if (-not (Has $entry 'page') -or -not (Has $entry 'kind') -or -not (Has $entry 'units')) { Fail 'coverage 条目必须包含 page、kind 和 units。' }
        $page = [int]$entry.page
        if ($page -lt $Start -or $page -gt $End -or -not $seenPages.Add($page)) { Fail "coverage 页码越界或重复：$page" }
        $kind = [string]$entry.kind
        $units = @($entry.units)
        if ($kind -eq 'technical') {
            $technicalPages++
            if ($units.Count -eq 0) { Fail "技术页 $page 至少需要一个知识单元。" }
        }
        elseif ($kind -eq 'nontechnical') {
            if (-not (Has $entry 'reason') -or [string]::IsNullOrWhiteSpace([string]$entry.reason)) { Fail "非技术页 $page 必须填写 reason。" }
            if ($units.Count -ne 0) { Fail "非技术页 $page 的 units 必须为空。" }
        }
        else { Fail "coverage kind 只能是 technical 或 nontechnical：第 $page 页。" }

        foreach ($unit in $units) {
            if (-not (Has $unit 'summary') -or [string]::IsNullOrWhiteSpace([string]$unit.summary)) { Fail "第 $page 页知识单元缺少 summary。" }
            if (-not (Has $unit 'source_type') -or [string]::IsNullOrWhiteSpace([string]$unit.source_type)) { Fail "第 $page 页知识单元缺少 source_type。" }
            if (-not (Has $unit 'source_fact') -or [string]::IsNullOrWhiteSpace([string]$unit.source_fact)) { Fail "第 $page 页知识单元缺少 source_fact。" }
            $hasQuestion = (Has $unit 'question') -and -not [string]::IsNullOrWhiteSpace([string]$unit.question)
            $hasSkip = (Has $unit 'skip_reason') -and -not [string]::IsNullOrWhiteSpace([string]$unit.skip_reason)
            if ($hasQuestion -eq $hasSkip) { Fail "第 $page 页每个知识单元必须且只能填写 question 或 skip_reason。" }
            if ($hasQuestion) {
                $question = [string]$unit.question
                if (-not $candidateQuestions.Contains($question)) { Fail "coverage 引用的问题不在 records 中：$question" }
                $coveredQuestions.Add($question) | Out-Null
            }
            elseif ([string]$unit.skip_reason -eq '已有问答充分覆盖') {
                if (-not (Has $unit 'covered_by') -or @($unit.covered_by).Count -eq 0) { Fail "第 $page 页标为已有问答充分覆盖的单元必须填写 covered_by。" }
                foreach ($coveredQuestion in @($unit.covered_by)) {
                    if ([string]::IsNullOrWhiteSpace([string]$coveredQuestion)) { Fail "第 $page 页 covered_by 不能含空问题。" }
                }
            }
        }
    }
    foreach ($question in $candidateQuestions) {
        if (-not $coveredQuestions.Contains($question)) { Fail "records 中的问题未被 coverage 引用：$question" }
    }
    return [pscustomobject]@{technical_pages=$technicalPages;questions=$coveredQuestions}
}

function Assert-CoveredByExists($Batch, $ExistingQuestions) {
    foreach ($entry in @($Batch.coverage)) {
        foreach ($unit in @($entry.units)) {
            if ((Has $unit 'skip_reason') -and [string]$unit.skip_reason -eq '已有问答充分覆盖') {
                foreach ($coveredQuestion in @($unit.covered_by)) {
                    if (-not $ExistingQuestions.Contains([string]$coveredQuestion)) { Fail "coverage 的 covered_by 问题不在现有 JSONL 中：$coveredQuestion" }
                }
            }
        }
    }
}

if (-not [IO.Directory]::Exists($script:Root)) { Fail "工作区不存在：$script:Root" }

switch ($Action) {
    'Init' {
        if ([string]::IsNullOrWhiteSpace($BookId) -or $PageCount -lt 1) { Fail 'Init 需要 BookId 和 PageCount。' }
        Assert-WorkspaceFile $PdfFile '.pdf' -MustExist
        Assert-WorkspaceFile $JsonlFile '.jsonl'
        $path = State-Path $BookId
        if ([IO.File]::Exists($path)) { Fail "状态已存在：$BookId" }
        $state = [pscustomobject][ordered]@{schema_version=2;book_id=$BookId;title=$(if($Title){$Title}else{$BookId});pdf_file=$PdfFile;jsonl_file=$JsonlFile;page_count=$PageCount;next_page=1;record_count=(Count-Lines $JsonlFile);status='active';updated_at=[DateTimeOffset]::Now.ToString('o');recent_commits=@()}
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
    'Skip' {
        if ([string]::IsNullOrWhiteSpace($BookId)) { Fail 'Skip 需要显式 BookId。' }
        if ([string]::IsNullOrWhiteSpace($SkipReason)) { Fail 'Skip 需要 SkipReason。' }
        $skipMutex = Enter-CommitMutex $BookId
        try {
            $state = Load-State $BookId
            if ($state.status -eq 'completed' -or $null -eq $state.next_page) { Fail '书籍已完成，不能跳过页面。' }
            $expectedStart = [int]$state.next_page
            $start = if ($StartPage -gt 0) { $StartPage } else { $expectedStart }
            if ($start -ne $expectedStart) { Fail "Skip 必须从下一页 $expectedStart 开始。" }
            $end = [Math]::Min($start + $BatchPages - 1, [int]$state.page_count)
            $now = [DateTimeOffset]::Now.ToString('o')
            $entry = [pscustomobject][ordered]@{start_page=$start;end_page=$end;reason=$SkipReason;skipped_at=$now}
            $history = [Collections.Generic.List[object]]::new()
            if (Has $state 'skipped_pages') {
                foreach ($previous in @($state.skipped_pages)) { $history.Add($previous) }
            }
            $history.Add($entry)
            if (Has $state 'skipped_pages') { $state.skipped_pages = @($history) }
            else { $state | Add-Member -NotePropertyName skipped_pages -NotePropertyValue @($history) }
            $state.next_page = if ($end -ge [int]$state.page_count) { $null } else { $end + 1 }
            $state.status = if ($null -eq $state.next_page) { 'completed' } else { 'active' }
            $state.updated_at = $now
            Save-Json (State-Path $state.book_id) $state
            Emit ([pscustomobject]@{book_id=$state.book_id;skipped_pages="$start-$end";reason=$SkipReason;next_page=$state.next_page;status=$state.status})
        }
        finally {
            if ($null -ne $skipMutex) {
                try { $skipMutex.ReleaseMutex() } catch { }
                $skipMutex.Dispose()
            }
        }
    }
    'Compact' {
        $targets = if ($BookId) { @(Load-State $BookId) } else { @(All-States) }
        foreach ($state in $targets) { Save-Json (State-Path $state.book_id) $state }
        Emit ([pscustomobject]@{compacted=$targets.Count;books=@($targets.book_id)})
    }
    'Validate' {
        $state = Find-State
        $outputPath = [IO.Path]::GetFullPath((Join-Path $script:Root ([string]$state.jsonl_file)))
        if (-not $outputPath.StartsWith($script:Root + '\', [StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($outputPath)) {
            Fail "JSONL 文件不存在或不在工作区内：$($state.jsonl_file)"
        }
        $validator = Join-Path $PSScriptRoot 'validate-jsonl.ps1'
        if (-not [IO.File]::Exists($validator)) { Fail '未找到 validate-jsonl.ps1。' }
        $validation = [ordered]@{}
        foreach ($line in @(& $validator -Path $outputPath)) {
            $parts = ([string]$line).Split('=', 2)
            if ($parts.Count -eq 2) { $validation[$parts[0]] = $parts[1] }
        }
        Emit ([pscustomobject]@{book_id=$state.book_id;jsonl_file=$state.jsonl_file;validation=$validation})
    }
    'Augment' {
        if ([string]::IsNullOrWhiteSpace($BookId)) { Fail 'Augment 需要显式 BookId。' }
        if ([string]::IsNullOrWhiteSpace($BatchFile)) { Fail 'Augment 需要 BatchFile。' }
        $batchPath = [IO.Path]::GetFullPath((Join-Path $script:Root $BatchFile))
        if (-not $batchPath.StartsWith($script:Root + '\', [StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($batchPath)) { Fail 'BatchFile 必须位于工作区内且存在。' }
        $batch = Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$batch.book_id -ne $BookId) { Fail '批次 BookId 与显式 BookId 不一致。' }
        $commitMutex = Enter-CommitMutex ([string]$batch.book_id)
        try {
            $state = Load-State $BookId
            $start = [int]$batch.start_page; $end = [int]$batch.end_page
            $processedEnd = if ($null -eq $state.next_page) { [int]$state.page_count } else { ([int]$state.next_page) - 1 }
            if ($start -lt 1 -or $end -lt $start -or $end -gt $processedEnd) { Fail "补检页码必须位于已处理范围 1-$processedEnd。" }
            $pageTotal = $end - $start + 1
            $coverageInfo = Get-BatchCoverage $batch $start $end
            $candidateCount = @($batch.records).Count
            $outputPath = Join-Path $script:Root $state.jsonl_file
            $oldLines = if ([IO.File]::Exists($outputPath)) { @([IO.File]::ReadAllLines($outputPath, $script:Utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { @() }
            $questions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($line in $oldLines) { try { $obj=$line|ConvertFrom-Json; if(@($obj.messages).Count -ge 1){$questions.Add([string]$obj.messages[0].content)|Out-Null} } catch { Fail '现有 JSONL 含无效 JSON，请先修复。' } }
            Assert-CoveredByExists $batch $questions
            $accepted = [Collections.Generic.List[string]]::new(); $acceptedQuestions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); $reasons = @{}
            foreach ($record in @($batch.records)) {
                $reason = Test-Record $record $questions
                if ($null -eq $reason) { $accepted.Add(($record | ConvertTo-Json -Depth 6 -Compress)); $acceptedQuestions.Add([string]@($record.messages)[0].content) | Out-Null }
                else { if(-not $reasons.ContainsKey($reason)){$reasons[$reason]=0};$reasons[$reason]++ }
            }
            if ($accepted.Count -eq 0) { Fail '补检批次没有新增记录。' }
            foreach ($question in $coverageInfo.questions) { if (-not $acceptedQuestions.Contains($question)) { Fail "coverage 引用的问题未通过记录门禁：$question" } }
            $minimumYield = [int][Math]::Ceiling(([int]$coverageInfo.technical_pages) * 3)
            $isLowYield = $minimumYield -gt 0 -and $accepted.Count -lt $minimumYield
            if ($isLowYield) {
                $reviewDigest = Get-BatchReviewDigest $batch
                if ($LowYieldReviewed) { Assert-LowYieldReview $batch $reviewDigest }
                else {
                    Register-LowYieldRejection $batchPath $batch $reviewDigest $accepted.Count $minimumYield
                    $rate = [Math]::Round($accepted.Count / [double]$pageTotal, 2)
                    Fail "低产补检已停止：$start-$end 共 $pageTotal 页，$candidateCount 条候选仅通过 $($accepted.Count) 条（$rate 条/页），复查门槛为 $minimumYield 条。"
                }
            }
            $all = [Collections.Generic.List[string]]::new(); foreach($line in $oldLines){$all.Add($line)}; foreach($line in $accepted){$all.Add($line)}
            $temp = "$outputPath.tmp"; [IO.File]::WriteAllLines($temp, $all, $script:Utf8); Move-Item -LiteralPath $temp -Destination $outputPath -Force
            $state.record_count = $all.Count
            $state.updated_at = [DateTimeOffset]::Now.ToString('o')
            $yieldPerPage = [Math]::Round($accepted.Count / [double]$pageTotal, 2)
            $entry = [pscustomobject][ordered]@{start_page=$start;end_page=$end;page_count=$pageTotal;candidates=$candidateCount;added=$accepted.Count;skipped=[pscustomobject]$reasons;yield_per_page=$yieldPerPage;low_yield_reviewed=[bool]($isLowYield -and $LowYieldReviewed);committed_at=$state.updated_at}
            $history = @()
            if (Has $state 'augmentation_commits') { $history = @($state.augmentation_commits) }
            $history = @($history + $entry)
            if ($history.Count -gt 20) { $history = @($history[($history.Count - 20)..($history.Count - 1)]) }
            if (Has $state 'augmentation_commits') { $state.augmentation_commits = $history }
            else { $state | Add-Member -NotePropertyName augmentation_commits -NotePropertyValue $history }
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
        Emit ([pscustomobject]@{book_id=$state.book_id;pages="$start-$end";candidates=$candidateCount;added=$accepted.Count;skipped=$reasons;yield_per_page=$yieldPerPage;low_yield_reviewed=[bool]($isLowYield -and $LowYieldReviewed);total=$state.record_count;next_page=$state.next_page;status=$state.status;mode='augmentation'})
    }
    'Commit' {
        if ([string]::IsNullOrWhiteSpace($BookId)) { Fail 'Commit 需要显式 BookId。' }
        if ([string]::IsNullOrWhiteSpace($BatchFile)) { Fail 'Commit 需要 BatchFile。' }
        $batchPath = [IO.Path]::GetFullPath((Join-Path $script:Root $BatchFile))
        if (-not $batchPath.StartsWith($script:Root + '\', [StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($batchPath)) { Fail 'BatchFile 必须位于工作区内且存在。' }
        $batch = Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$batch.book_id -ne $BookId) { Fail '批次 BookId 与显式 BookId 不一致。' }
        $commitMutex = Enter-CommitMutex ([string]$batch.book_id)
        try {
            $state = Load-State $BookId
            if ($state.status -eq 'completed' -or $null -eq $state.next_page) { Fail '该书已完成。' }
            $start = [int]$batch.start_page; $end = [int]$batch.end_page
            if ($start -ne [int]$state.next_page -or $end -lt $start -or $end -gt [int]$state.page_count) { Fail "批次页码必须从 $($state.next_page) 开始且不得越界。" }
            $pageTotal = $end - $start + 1
            $coverageInfo = Get-BatchCoverage $batch $start $end
            $candidateCount = @($batch.records).Count
            $outputPath = Join-Path $script:Root $state.jsonl_file
            $oldLines = if ([IO.File]::Exists($outputPath)) { @([IO.File]::ReadAllLines($outputPath, $script:Utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { @() }
            $questions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($line in $oldLines) { try { $obj=$line|ConvertFrom-Json; if(@($obj.messages).Count -ge 1){$questions.Add([string]$obj.messages[0].content)|Out-Null} } catch { Fail '现有 JSONL 含无效 JSON，请先修复。' } }
            Assert-CoveredByExists $batch $questions
            $accepted = [Collections.Generic.List[string]]::new(); $acceptedQuestions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); $reasons = @{}
            foreach ($record in @($batch.records)) {
                $reason = Test-Record $record $questions
                if ($null -eq $reason) { $accepted.Add(($record | ConvertTo-Json -Depth 6 -Compress)); $acceptedQuestions.Add([string]@($record.messages)[0].content) | Out-Null }
                else { if(-not $reasons.ContainsKey($reason)){$reasons[$reason]=0};$reasons[$reason]++ }
            }
            if ($accepted.Count -eq 0) { Fail '批次没有新增记录，拒绝推进页码。' }
            foreach ($question in $coverageInfo.questions) { if (-not $acceptedQuestions.Contains($question)) { Fail "coverage 引用的问题未通过记录门禁：$question" } }
            $minimumYield = [int][Math]::Ceiling(([int]$coverageInfo.technical_pages) * 3)
            $isLowYield = $minimumYield -gt 0 -and $accepted.Count -lt $minimumYield
            if ($isLowYield) {
                $reviewDigest = Get-BatchReviewDigest $batch
                if ($LowYieldReviewed) { Assert-LowYieldReview $batch $reviewDigest }
                else {
                    Register-LowYieldRejection $batchPath $batch $reviewDigest $accepted.Count $minimumYield
                    $rate = [Math]::Round($accepted.Count / [double]$pageTotal, 2)
                    Fail "低产批次已停止：$start-$end 共 $pageTotal 页，$candidateCount 条候选仅通过 $($accepted.Count) 条（$rate 条/页），复查门槛为 $minimumYield 条。请回看原图并补查定义、作用、适用条件、规格选择、参数与单位、步骤、比较、原因和判据；若内容确属稀疏，复核后使用 -LowYieldReviewed 重新提交。"
                }
            }
            $all = [Collections.Generic.List[string]]::new(); foreach($line in $oldLines){$all.Add($line)}; foreach($line in $accepted){$all.Add($line)}
            $temp = "$outputPath.tmp"; [IO.File]::WriteAllLines($temp, $all, $script:Utf8); Move-Item -LiteralPath $temp -Destination $outputPath -Force
            $state.record_count = $all.Count
            $state.next_page = if ($end -ge [int]$state.page_count) { $null } else { $end + 1 }
            $state.status = if ($null -eq $state.next_page) { 'completed' } else { 'active' }
            $state.updated_at = [DateTimeOffset]::Now.ToString('o')
            $yieldPerPage = [Math]::Round($accepted.Count / [double]$pageTotal, 2)
            $commitEntry = [pscustomobject][ordered]@{
                start_page = $start
                end_page = $end
                page_count = $pageTotal
                candidates = $candidateCount
                added = $accepted.Count
                skipped = [pscustomobject]$reasons
                yield_per_page = $yieldPerPage
                low_yield_reviewed = [bool]($isLowYield -and $LowYieldReviewed)
                committed_at = $state.updated_at
            }
            $history = @(@($state.recent_commits) + $commitEntry)
            if ($history.Count -gt 20) { $history = @($history[($history.Count - 20)..($history.Count - 1)]) }
            $state.recent_commits = $history
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
        Emit ([pscustomobject]@{book_id=$state.book_id;pages="$start-$end";candidates=$candidateCount;added=$accepted.Count;skipped=$reasons;yield_per_page=$yieldPerPage;low_yield_reviewed=[bool]($isLowYield -and $LowYieldReviewed);total=$state.record_count;next_page=$state.next_page;status=$state.status})
    }
}
