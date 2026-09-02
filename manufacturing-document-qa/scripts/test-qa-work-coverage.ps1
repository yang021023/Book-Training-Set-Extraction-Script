[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$qaWork = Join-Path $PSScriptRoot 'qa-work.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("manufacturing-document-qa-coverage-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

try {
    [IO.Directory]::CreateDirectory((Join-Path $testRoot '_qa_work\tmp')) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $testRoot 'sample.pdf'), [byte[]](1, 2, 3))
    & $qaWork -Action Init -WorkspaceRoot $testRoot -BookId 'sample' -PdfFile 'sample.pdf' -JsonlFile 'sample.jsonl' -PageCount 3 -AsJson | Out-Null

    $records = @(1..3 | ForEach-Object {
        [pscustomobject]@{messages=@([pscustomobject]@{role='user';content="覆盖问题 $_？"},[pscustomobject]@{role='assistant';content="覆盖答案 $_。"})}
    })
    $batchPath = Join-Path $testRoot '_qa_work\tmp\coverage.json'
    $missingCoverage = [pscustomobject]@{book_id='sample';start_page=1;end_page=1;records=$records}
    [IO.File]::WriteAllText($batchPath, ($missingCoverage | ConvertTo-Json -Depth 8), $utf8)

    $missingBookIdBlocked = $false
    try { & $qaWork -Action Commit -WorkspaceRoot $testRoot -BatchFile '_qa_work\tmp\coverage.json' -AsJson | Out-Null }
    catch { $missingBookIdBlocked = $_.Exception.Message -like '*Commit 需要显式 BookId*' }
    Assert-True $missingBookIdBlocked 'commit without an explicit BookId must be blocked'

    $mismatchedBookIdBlocked = $false
    try { & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'other' -BatchFile '_qa_work\tmp\coverage.json' -AsJson | Out-Null }
    catch { $mismatchedBookIdBlocked = $_.Exception.Message -like '*批次 BookId 与显式 BookId 不一致*' }
    Assert-True $mismatchedBookIdBlocked 'commit with a mismatched BookId must be blocked'

    $missingBlocked = $false
    $missingMessage = ''
    try { & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\coverage.json' -AsJson | Out-Null }
    catch {
        $missingMessage = $_.Exception.Message
        $missingBlocked = $missingMessage -like '*缺少逐页 coverage*'
    }
    Assert-True $missingBlocked "commit without coverage must be blocked; actual: $missingMessage"

    $metadataCoverage = @([pscustomobject]@{page=1;kind='technical';units=@(
        [pscustomobject]@{summary='缺失源页事实';source_type='定义';question='覆盖问题 1？'},
        [pscustomobject]@{summary='单元 2';source_type='条件';source_fact='条件事实 2';question='覆盖问题 2？'},
        [pscustomobject]@{summary='单元 3';source_type='关系';source_fact='关系事实 3';question='覆盖问题 3？'}
    )})
    [IO.File]::WriteAllText($batchPath, ([pscustomobject]@{book_id='sample';start_page=1;end_page=1;coverage=$metadataCoverage;records=$records} | ConvertTo-Json -Depth 8), $utf8)
    $metadataBlocked = $false
    try { & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\coverage.json' -AsJson | Out-Null }
    catch { $metadataBlocked = $_.Exception.Message -like '*缺少 source_fact*' }
    Assert-True $metadataBlocked 'technical units without a concrete source fact must be blocked'

    $unverifiedSkipCoverage = @([pscustomobject]@{page=1;kind='technical';units=@(
        1..3 | ForEach-Object { [pscustomobject]@{summary="单元 $_";source_type='关系';source_fact="关系事实 $_";question="覆盖问题 $_？"} }
    ) + @(
        [pscustomobject]@{summary='声称已有覆盖的单元';source_type='条件';source_fact='必须由现有问题精确覆盖的条件事实';skip_reason='已有问答充分覆盖';covered_by=@('不存在的旧问题？')}
    )})
    [IO.File]::WriteAllText($batchPath, ([pscustomobject]@{book_id='sample';start_page=1;end_page=1;coverage=$unverifiedSkipCoverage;records=$records} | ConvertTo-Json -Depth 8), $utf8)
    $unverifiedSkipBlocked = $false
    try { & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\coverage.json' -AsJson | Out-Null }
    catch { $unverifiedSkipBlocked = $_.Exception.Message -like '*covered_by 问题不在现有 JSONL 中*' }
    Assert-True $unverifiedSkipBlocked 'an existing-coverage skip must name an actual existing question'

    $partialCoverage = @([pscustomobject]@{page=1;kind='technical';units=@(
        [pscustomobject]@{summary='单元 1';source_type='定义';source_fact='定义事实 1';question='覆盖问题 1？'},
        [pscustomobject]@{summary='单元 2';source_type='条件';source_fact='条件事实 2';question='覆盖问题 2？'}
    )})
    [IO.File]::WriteAllText($batchPath, ([pscustomobject]@{book_id='sample';start_page=1;end_page=1;coverage=$partialCoverage;records=$records} | ConvertTo-Json -Depth 8), $utf8)
    $partialBlocked = $false
    $partialMessage = ''
    try { & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\coverage.json' -AsJson | Out-Null }
    catch {
        $partialMessage = $_.Exception.Message
        $partialBlocked = $partialMessage -like '*问题未被 coverage 引用*'
    }
    Assert-True $partialBlocked "every candidate question must be referenced by coverage; actual: $partialMessage"

    $sourceDependentRecords = @(
        [pscustomobject]@{messages=@([pscustomobject]@{role='user';content='独立的有效问题是什么？'},[pscustomobject]@{role='assistant';content='这是独立且完整的答案。'})},
        [pscustomobject]@{messages=@([pscustomobject]@{role='user';content='示例中的车刀前角应如何取？'},[pscustomobject]@{role='assistant';content='该参数只适用于示例。'})},
        [pscustomobject]@{messages=@([pscustomobject]@{role='user';content='某不锈钢的加工性等级是什么？'},[pscustomobject]@{role='assistant';content='书中1Cr18Ni9Ti的表格给出了等级。'})}
    )
    $sourceDependentCoverage = @([pscustomobject]@{page=1;kind='technical';units=@(
        [pscustomobject]@{summary='有效单元';source_type='定义';source_fact='独立事实';question='独立的有效问题是什么？'},
        [pscustomobject]@{summary='示例依赖';source_type='参数';source_fact='仅给出示例参数';question='示例中的车刀前角应如何取？'},
        [pscustomobject]@{summary='书籍依赖';source_type='表格';source_fact='仅在书内表格给出';question='某不锈钢的加工性等级是什么？'}
    )})
    [IO.File]::WriteAllText($batchPath, ([pscustomobject]@{book_id='sample';start_page=1;end_page=1;coverage=$sourceDependentCoverage;records=$sourceDependentRecords} | ConvertTo-Json -Depth 8), $utf8)
    $sourceDependencyBlocked = $false
    try { & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\coverage.json' -AsJson | Out-Null }
    catch { $sourceDependencyBlocked = $_.Exception.Message -like '*coverage 引用的问题未通过记录门禁*' }
    Assert-True $sourceDependencyBlocked 'bare example and book references must be rejected as source-dependent'

    $exampleConditionRecords = @(
        [pscustomobject]@{messages=@([pscustomobject]@{role='user';content='完整工况问题 1？'},[pscustomobject]@{role='assistant';content='完整工况答案 1。'})},
        [pscustomobject]@{messages=@([pscustomobject]@{role='user';content='完整工况问题 2？'},[pscustomobject]@{role='assistant';content='完整工况答案 2。'})},
        [pscustomobject]@{messages=@([pscustomobject]@{role='user';content='高速钢车削钼合金时介质活性如何影响磨损？'},[pscustomobject]@{role='assistant';content='在给定参数的示例条件下，介质活性越高，刀具磨损越快。'})}
    )
    $exampleConditionCoverage = @([pscustomobject]@{page=1;kind='technical';units=@(
        [pscustomobject]@{summary='完整单元 1';source_type='关系';source_fact='完整事实 1';question='完整工况问题 1？'},
        [pscustomobject]@{summary='完整单元 2';source_type='关系';source_fact='完整事实 2';question='完整工况问题 2？'},
        [pscustomobject]@{summary='示例条件依赖';source_type='条件';source_fact='条件仍依赖示例';question='高速钢车削钼合金时介质活性如何影响磨损？'}
    )})
    [IO.File]::WriteAllText($batchPath, ([pscustomobject]@{book_id='sample';start_page=1;end_page=1;coverage=$exampleConditionCoverage;records=$exampleConditionRecords} | ConvertTo-Json -Depth 8), $utf8)
    $exampleConditionBlocked = $false
    try { & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\coverage.json' -AsJson | Out-Null }
    catch { $exampleConditionBlocked = $_.Exception.Message -like '*coverage 引用的问题未通过记录门禁*' }
    Assert-True $exampleConditionBlocked 'example-condition phrasing must be rejected as source-dependent'

    $completeCoverage = @([pscustomobject]@{page=1;kind='technical';units=@(1..3 | ForEach-Object {
        [pscustomobject]@{summary="单元 $_";source_type='关系';source_fact="关系事实 $_";question="覆盖问题 $_？"}
    })})
    [IO.File]::WriteAllText($batchPath, ([pscustomobject]@{book_id='sample';start_page=1;end_page=1;coverage=$completeCoverage;records=$records} | ConvertTo-Json -Depth 8), $utf8)
    $result = & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\coverage.json' -AsJson | ConvertFrom-Json
    Assert-True ([int]$result.added -eq 3) 'complete coverage should commit all records'
    Assert-True ([int]$result.next_page -eq 2) 'complete coverage should advance next_page'

    [pscustomobject]@{status='passed';missing_book_id_blocked=$missingBookIdBlocked;mismatched_book_id_blocked=$mismatchedBookIdBlocked;missing_coverage_blocked=$missingBlocked;metadata_blocked=$metadataBlocked;unverified_skip_blocked=$unverifiedSkipBlocked;partial_coverage_blocked=$partialBlocked;source_dependency_blocked=$sourceDependencyBlocked;example_condition_blocked=$exampleConditionBlocked;added=$result.added} | ConvertTo-Json -Compress
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolvedTest)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
