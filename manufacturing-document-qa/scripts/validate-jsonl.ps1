param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [string]$BookTitlePattern,
    [string[]]$AdditionalForbiddenPatterns = @(),
    [switch]$ListProblems,
    [switch]$RequireNoWarnings
)

$ErrorActionPreference = 'Stop'
$utf8Strict = [Text.UTF8Encoding]::new($false, $true)
$resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
$lines = [IO.File]::ReadAllLines($resolved, $utf8Strict)

$invalidJson = 0
$schemaErrors = 0
$roleErrors = 0
$emptyContents = 0
$forbiddenHits = 0
$oversizedParameterDumps = 0
$problemLines = [Collections.Generic.HashSet[int]]::new()
$warningLines = [Collections.Generic.HashSet[int]]::new()
$questions = @{}
$answers = @{}
$normalizedQuestions = @{}
$warningCounts = [ordered]@{
    nontechnical_scope = 0
    source_dependency = 0
    undefined_basis = 0
    ordinal_dependency = 0
    ui_navigation = 0
    advice_expansion = 0
    pedagogical_framing = 0
    arbitrary_case_lookup = 0
}

$nontechnicalScopeQuestion = '(?:工程师|工程技术人员).{0,24}(?:职业伦理|职业道德|职业操守|职业责任|公众利益|社会责任|诚信|保密|持续专业发展)|(?:职业伦理|职业道德|职业操守|公众利益|社会责任)|(?:安全教育|纪律教育|工业安全培训)|岗位纪律|安全内务|个人防护措施|个人穿戴|穿戴有哪些|(?:着装|工作服|工作帽|安全帽|防护鞋|护目镜).{0,20}(?:要求|措施)|消防器材|消防通道|无人值守用电|明火电炉|(?:事故|安全隐患).{0,24}(?:应急处置|处置要点|报告|保护现场)|无关人员.{0,20}(?:进入|观看)|机械伤害.{0,24}(?:潜在危险|基本管理措施)|(?:机械设备|机床)启动前.{0,16}安全检查|(?:机械工程)?实训(?:现场|期间|结束|场所).{0,32}(?:基本安全行为|整理工具|作业场地|关闭事项|意外事故|应急处置)'

# Hard errors are deliberately narrow. Ambiguous wording belongs in review warnings.
$forbiddenPatterns = @(
    '\.pdf(?:\b|["''，。])',
    '\.jsonl(?:\b|["''，。])',
    'z-library|1lib|z-lib|Anna''s Archive',
    '根据(?:本书|原文|上图|下图|该图)|本书指出|原文指出',
    '(?:(?<!基)本书|书中|原文|文中|教材(?:中)?|本页|该页|页面)',
    '(?:上图|下图|(?<!配)(?<!绘)(?<!视)(?<!面)图中|(?<!列)(?<!具)表中|按图(?:示|样)|图示中|表格中)',
    '(?:案例|示例|例题|实例)(?:中|里|的|条件(?:下)?)',
    '(?:按|根据)\s*(?:本书|书中|原文|文中|教材(?:中)?|本页|该页|页面)(?:的|中)?(?:定义|内容|描述|记载|要求|数据|说明|规定|给出|列出|列举|介绍|指出|提到|显示|展示)',
    '(?:本书|书中|原文|文中|教材(?:中)?|本页|该页|页面)(?:还|也|曾|所)?(?:列出|列举|给出|介绍|指出|提到|说明|规定|显示|展示|可见)',
    '(?:本书|书中|原文|文中|教材(?:中)?)(?:的)?(?:示例|案例)(?:中)?',
    '(?:参见|见)\s*(?:图|表)\s*\d+',
    '第\s*\d+\s*页',
    '数据集制作|训练数据|提示语',
    '课程目标|答辩要求|提交要求|心得体会',
    '《[^》]{2,80}》(?:的|是)?(?:内容定位|教学定位|教学内容|内容组织|项目内容|编写特点|适用对象|读者对象)',
    '(?:知识|能力|学习|教学)目标',
    '(?:项目|任务)\s*[一二三四五六七八九十0-9]+.{0,24}(?:要求学习|涉及哪些|引导案例|应具备哪些)',
    '(?:完成|通过).{0,30}(?:项目|任务).{0,30}(?:掌握|学会|应具备|需要掌握)'
) + $AdditionalForbiddenPatterns
if (-not [string]::IsNullOrWhiteSpace($BookTitlePattern)) {
    $forbiddenPatterns += $BookTitlePattern
}

function Add-Count([hashtable]$Table, [string]$Key, [int]$LineNumber) {
    if ($Table.ContainsKey($Key)) {
        $Table[$Key].Count++
        $Table[$Key].Lines.Add($LineNumber)
    }
    else {
        $Table[$Key] = [pscustomobject]@{
            Count = 1
            Lines = [Collections.Generic.List[int]]::new()
        }
        $Table[$Key].Lines.Add($LineNumber)
    }
}

for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
    $lineNumber = $lineIndex + 1
    $line = $lines[$lineIndex]
    if ([string]::IsNullOrWhiteSpace($line)) {
        $schemaErrors++
        [void]$problemLines.Add($lineNumber)
        continue
    }

    try { $record = $line | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $invalidJson++
        [void]$problemLines.Add($lineNumber)
        continue
    }

    $propertyNames = @($record.PSObject.Properties.Name)
    if ($propertyNames.Count -ne 1 -or $propertyNames[0] -ne 'messages') {
        $schemaErrors++
        [void]$problemLines.Add($lineNumber)
    }

    $messages = @($record.messages)
    if ($messages.Count -lt 2 -or $messages.Count % 2 -ne 0) {
        $schemaErrors++
        [void]$problemLines.Add($lineNumber)
        continue
    }

    for ($messageIndex = 0; $messageIndex -lt $messages.Count; $messageIndex++) {
        $expectedRole = if ($messageIndex % 2 -eq 0) { 'user' } else { 'assistant' }
        if ([string]$messages[$messageIndex].role -ne $expectedRole) {
            $roleErrors++
            [void]$problemLines.Add($lineNumber)
        }
        if ([string]::IsNullOrWhiteSpace([string]$messages[$messageIndex].content)) {
            $emptyContents++
            [void]$problemLines.Add($lineNumber)
        }
    }

    $firstQuestion = [string]$messages[0].content
    $firstAnswer = [string]$messages[1].content
    if (-not [string]::IsNullOrWhiteSpace($firstQuestion)) {
        Add-Count $questions $firstQuestion $lineNumber
        $normalized = $firstQuestion.Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
        $normalized = [regex]::Replace($normalized, '[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:\s*[～~—–-]\s*[+-]?\d+(?:\.\d+)?)?', '<n>')
        $normalized = [regex]::Replace($normalized, '\s+|[，。；：、,.!?！？“”''"（）()\[\]]', '')
        Add-Count $normalizedQuestions $normalized $lineNumber
        if ($firstQuestion -match '本书(?:中|指出)|原文(?:中|指出)|第\s*\d+\s*页|上图|下图|见图|图中(?:标注|给出|所示)(?:为|的)?|(?:图|表)\s*[A-Za-z]?\s*\d+(?:\s*[-—–－.．]\s*\d+)?') {
            $forbiddenHits++
            [void]$problemLines.Add($lineNumber)
        }
        if ($firstQuestion -match $nontechnicalScopeQuestion) {
            $forbiddenHits++
            [void]$problemLines.Add($lineNumber)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($firstAnswer)) {
        Add-Count $answers $firstAnswer $lineNumber
        $numericRangeCount = [regex]::Matches($firstAnswer, '[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*[～~—–-]\s*[+-]?(?:\d+(?:\.\d+)?|\.\d+)').Count
        if ($firstAnswer.Length -gt 600 -and $numericRangeCount -ge 6) {
            $oversizedParameterDumps++
            [void]$problemLines.Add($lineNumber)
        }
    }

    if ($line -match '点\s*\d+|(?<![A-Za-z0-9])N\s*\d+\s*(?:程序)?段|第\s*[一二三四五六七八九十百]+\s*轮|程序\s*\d+\s*(?:中|里)') {
        $forbiddenHits++
        [void]$problemLines.Add($lineNumber)
    }

    foreach ($pattern in $forbiddenPatterns) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $line -match $pattern) {
            $forbiddenHits++
            [void]$problemLines.Add($lineNumber)
            break
        }
    }

    $warningPatterns = [ordered]@{
        nontechnical_scope = '职业伦理|职业道德|职业操守|职业责任|公众利益|社会责任|安全教育|岗位纪律|安全内务|个人防护|个人穿戴|消防器材|消防通道|无人值守|明火电炉|事故现场|应急处置|无关人员'
        source_dependency = '上图|下图|该图|图中(?:标注|所示|给出)|按图(?:示|样)'
        undefined_basis = '基准\s*[A-Z](?:\b|[^A-Za-z])'
        ordinal_dependency = '第[一二三四五六七八九十]+(?:步|条|个|种|处|项)(?:\b|[^骤件工序])'
        ui_navigation = '菜单|按钮|对话框|窗口|单击|双击|右键|工具栏'
        advice_expansion = '确保|避免|防止|还应|建议|实际情况|具体条件'
        pedagogical_framing = '(?:项目|任务)\s*[一二三四五六七八九十0-9]+|要求学生|通过.{0,24}(?:学习|任务).{0,24}(?:掌握|了解|具备)'
        arbitrary_case_lookup = '(?:案例|示例|任务|零件图).{0,24}(?:尺寸|长度|宽度|厚度|直径|分值|多少分)'
    }
    foreach ($entry in $warningPatterns.GetEnumerator()) {
        if ($line -match $entry.Value) {
            $warningCounts[$entry.Key]++
            [void]$warningLines.Add($lineNumber)
        }
    }
}

$duplicateQuestions = @($questions.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
$duplicateAnswers = @($answers.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
$templateGroups = @($normalizedQuestions.GetEnumerator() | Where-Object { $_.Key -match '<n>' -and $_.Value.Count -gt 1 })
foreach ($group in $duplicateQuestions) { foreach ($n in $group.Value.Lines) { [void]$problemLines.Add($n) } }
foreach ($group in $duplicateAnswers) { foreach ($n in $group.Value.Lines) { [void]$warningLines.Add($n) } }
foreach ($group in $templateGroups) { foreach ($n in $group.Value.Lines) { [void]$warningLines.Add($n) } }

$valid = $invalidJson -eq 0 -and $schemaErrors -eq 0 -and $roleErrors -eq 0 -and $emptyContents -eq 0 -and $duplicateQuestions.Count -eq 0 -and $forbiddenHits -eq 0 -and $oversizedParameterDumps -eq 0
# Default production mode treats contextual warnings as sampling hints, not as
# reasons to discard otherwise valid training data. -RequireNoWarnings remains
# available for an explicitly requested strict audit.
$trainReady = $valid
$strictReady = $valid -and $warningLines.Count -eq 0

Write-Output "lines=$($lines.Count)"
Write-Output "invalid_json=$invalidJson"
Write-Output "schema_errors=$schemaErrors"
Write-Output "role_errors=$roleErrors"
Write-Output "empty_contents=$emptyContents"
Write-Output "duplicate_first_questions=$($duplicateQuestions.Count)"
Write-Output "duplicate_answer_groups=$($duplicateAnswers.Count)"
Write-Output "normalized_template_groups=$($templateGroups.Count)"
Write-Output "hard_forbidden_hits=$forbiddenHits"
Write-Output "oversized_parameter_dumps=$oversizedParameterDumps"
foreach ($entry in $warningCounts.GetEnumerator()) { Write-Output "warning_$($entry.Key)=$($entry.Value)" }
Write-Output "warning_lines=$($warningLines.Count)"
Write-Output "valid=$valid"
Write-Output "train_ready=$trainReady"
Write-Output "strict_ready=$strictReady"

if ($ListProblems) {
    if ($problemLines.Count -gt 0) { Write-Output "problem_lines=$((@($problemLines) | Sort-Object) -join ',')" }
    if ($warningLines.Count -gt 0) { Write-Output "review_lines=$((@($warningLines) | Sort-Object) -join ',')" }
}
if (-not $valid -or ($RequireNoWarnings -and -not $strictReady)) { exit 1 }
