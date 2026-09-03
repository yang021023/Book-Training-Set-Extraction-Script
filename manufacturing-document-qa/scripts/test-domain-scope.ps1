[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$qaWork = Join-Path $PSScriptRoot 'qa-work.ps1'
$validator = Join-Path $PSScriptRoot 'validate-jsonl.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("manufacturing-document-qa-domain-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-Record([string]$Question, [string]$Answer) {
    [pscustomobject]@{messages=@(
        [pscustomobject]@{role='user';content=$Question},
        [pscustomobject]@{role='assistant';content=$Answer}
    )}
}

try {
    [IO.Directory]::CreateDirectory((Join-Path $testRoot '_qa_work\tmp')) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $testRoot 'sample.pdf'), [byte[]](1, 2, 3))
    & $qaWork -Action Init -WorkspaceRoot $testRoot -BookId 'sample' -PdfFile 'sample.pdf' -JsonlFile 'sample.jsonl' -PageCount 1 -AsJson | Out-Null

    $badRecords = @(
        New-Record '工程师职业伦理为什么要优先考虑公众利益？' '应优先维护公众利益并承担社会责任。'
        New-Record '参加机械工程实训前应满足哪些安全教育要求？' '应接受纪律和安全教育并通过考核。'
        New-Record '锻造作业前应采用哪些个人防护措施？' '应穿工作服、隔热鞋并佩戴安全帽和护目镜。'
    )
    $badPath = Join-Path $testRoot 'bad.jsonl'
    [IO.File]::WriteAllLines($badPath, @($badRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress }), $utf8)
    $badValidation = @(& $validator -Path $badPath -ListProblems)
    $badForbidden = [int](($badValidation | Where-Object { $_ -like 'hard_forbidden_hits=*' }) -replace '^hard_forbidden_hits=', '')
    Assert-True ($badForbidden -eq 3) "three nontechnical scope records must be hard failures; actual: $badForbidden"

    $batchPath = Join-Path $testRoot '_qa_work\tmp\domain.json'
    $badCoverage = @([pscustomobject]@{page=1;kind='technical';units=@(
        [pscustomobject]@{summary='职业伦理';source_type='要求';source_fact='工程师应优先考虑公众利益';question=$badRecords[0].messages[0].content},
        [pscustomobject]@{summary='安全教育';source_type='要求';source_fact='实训前接受安全教育';question=$badRecords[1].messages[0].content},
        [pscustomobject]@{summary='个人防护';source_type='要求';source_fact='锻造前穿戴个人防护用品';question=$badRecords[2].messages[0].content}
    )})
    [IO.File]::WriteAllText($batchPath, ([pscustomobject]@{book_id='sample';start_page=1;end_page=1;coverage=$badCoverage;records=$badRecords} | ConvertTo-Json -Depth 8), $utf8)
    $commitBlocked = $false
    $commitMessage = ''
    try { & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\domain.json' -AsJson | Out-Null }
    catch {
        $commitMessage = $_.Exception.Message
        $commitBlocked = $commitMessage -like '*没有新增记录*' -or $commitMessage -like '*未通过记录门禁*'
    }
    Assert-True $commitBlocked "commit must reject nontechnical scope records; actual: $commitMessage"

    $goodRecords = @(
        New-Record '磨床砂轮安装后为什么要空运转，安装检查应包括哪些步骤？' '检查裂纹并在法兰间加垫片，均匀夹紧和静平衡；装机后空运转5～10 min，确认无异常后加工。'
        New-Record '数控线切割加工的开机和停车顺序分别是什么？' '开机先走丝，再开工作液，最后接通高频；停车按高频、工作液、走丝的顺序关闭。'
        New-Record '使用磁盘装夹磨削工件时，怎样根据工件形状配置辅助装夹？' '高工件加靠板，小底面工件配抗磁圈和挡环，磨削斜度时必须夹牢。'
    )
    $goodCoverage = @([pscustomobject]@{page=1;kind='technical';units=@(
        [pscustomobject]@{summary='砂轮安装检查';source_type='步骤';source_fact='砂轮检查、静平衡并空运转5～10 min';question=$goodRecords[0].messages[0].content},
        [pscustomobject]@{summary='线切割启停顺序';source_type='步骤';source_fact='走丝、工作液和高频存在确定启停顺序';question=$goodRecords[1].messages[0].content},
        [pscustomobject]@{summary='磁盘辅助装夹';source_type='选择';source_fact='不同形状工件采用靠板、抗磁圈或挡环';question=$goodRecords[2].messages[0].content}
    )})
    [IO.File]::WriteAllText($batchPath, ([pscustomobject]@{book_id='sample';start_page=1;end_page=1;coverage=$goodCoverage;records=$goodRecords} | ConvertTo-Json -Depth 8), $utf8)
    $result = & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\domain.json' -AsJson | ConvertFrom-Json
    Assert-True ([int]$result.added -eq 3) 'device-specific technical controls must remain accepted'

    [pscustomobject]@{
        status='passed'
        hard_scope_failures=$badForbidden
        commit_scope_blocked=$commitBlocked
        technical_controls_added=[int]$result.added
    } | ConvertTo-Json -Compress
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolvedTest)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
