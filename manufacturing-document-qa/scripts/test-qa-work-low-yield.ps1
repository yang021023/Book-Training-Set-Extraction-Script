[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$qaWork = Join-Path $PSScriptRoot 'qa-work.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("manufacturing-document-qa-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $testRoot '_qa_work\tmp')) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $testRoot 'sample.pdf'), [byte[]](1, 2, 3))

    & $qaWork -Action Init -WorkspaceRoot $testRoot -BookId 'sample' -PdfFile 'sample.pdf' -JsonlFile 'sample.jsonl' -PageCount 16 -AsJson | Out-Null

    $records = foreach ($index in 1..7) {
        [pscustomobject]@{
            messages = @(
                [pscustomobject]@{role='user';content="测试技术问题 $index？"},
                [pscustomobject]@{role='assistant';content="测试技术答案 $index。"}
            )
        }
    }
    $batchPath = Join-Path $testRoot '_qa_work\tmp\batch.json'
    $batch = [pscustomobject]@{book_id='sample';start_page=1;end_page=8;records=@($records)}
    [IO.File]::WriteAllText($batchPath, ($batch | ConvertTo-Json -Depth 6), $utf8)

    $blocked = $false
    try {
        & $qaWork -Action Commit -WorkspaceRoot $testRoot -BatchFile '_qa_work\tmp\batch.json' -AsJson | Out-Null
    }
    catch {
        $blocked = $_.Exception.Message -like '*低产批次已停止*'
    }
    Assert-True $blocked 'low-yield commit should be blocked'

    $before = Get-Content -LiteralPath (Join-Path $testRoot '_qa_work\sample\state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([int]$before.next_page -eq 1) 'blocked commit must not advance next_page'
    Assert-True (-not [IO.File]::Exists((Join-Path $testRoot 'sample.jsonl'))) 'blocked commit must not create JSONL output'
    Assert-True ([IO.File]::Exists($batchPath)) 'blocked commit must preserve the batch for review'

    $result = & $qaWork -Action Commit -WorkspaceRoot $testRoot -BatchFile '_qa_work\tmp\batch.json' -LowYieldReviewed -AsJson | ConvertFrom-Json
    Assert-True ([int]$result.added -eq 7) 'reviewed commit should add seven records'
    Assert-True ([bool]$result.low_yield_reviewed) 'reviewed commit should report the override'
    Assert-True (-not [IO.File]::Exists($batchPath)) 'successful commit should remove a temporary batch'

    $after = Get-Content -LiteralPath (Join-Path $testRoot '_qa_work\sample\state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([int]$after.next_page -eq 9) 'reviewed commit should advance next_page'
    Assert-True (@($after.recent_commits).Count -eq 1) 'state should retain one commit history entry'
    Assert-True ([int]$after.recent_commits[0].candidates -eq 7) 'history should retain candidate count'
    Assert-True ([double]$after.recent_commits[0].yield_per_page -eq 0.88) 'history should retain per-page yield'

    [pscustomobject]@{status='passed';blocked_low_yield=$blocked;reviewed_added=$result.added;history_entries=@($after.recent_commits).Count} | ConvertTo-Json -Compress
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolvedTest)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
