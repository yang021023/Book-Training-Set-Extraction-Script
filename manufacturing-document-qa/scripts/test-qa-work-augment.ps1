[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$qaWork = Join-Path $PSScriptRoot 'qa-work.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("manufacturing-document-qa-augment-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-Record([string]$Question, [string]$Answer) {
    return [pscustomobject]@{messages=@([pscustomobject]@{role='user';content=$Question},[pscustomobject]@{role='assistant';content=$Answer})}
}

try {
    [IO.Directory]::CreateDirectory((Join-Path $testRoot '_qa_work\tmp')) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $testRoot 'sample.pdf'), [byte[]](1, 2, 3))
    & $qaWork -Action Init -WorkspaceRoot $testRoot -BookId 'sample' -PdfFile 'sample.pdf' -JsonlFile 'sample.jsonl' -PageCount 4 -AsJson | Out-Null

    $initialRecords = @(1..3 | ForEach-Object { New-Record "初始问题 $_？" "初始答案 $_。" })
    $initialCoverage = @([pscustomobject]@{page=1;kind='technical';units=@(1..3 | ForEach-Object { [pscustomobject]@{summary="初始单元 $_";source_type='定义';source_fact="初始事实 $_";question="初始问题 $_？"} })})
    $initialPath = Join-Path $testRoot '_qa_work\tmp\initial.json'
    [IO.File]::WriteAllText($initialPath, ([pscustomobject]@{book_id='sample';start_page=1;end_page=1;coverage=$initialCoverage;records=$initialRecords} | ConvertTo-Json -Depth 8), $utf8)
    & $qaWork -Action Commit -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\initial.json' -AsJson | Out-Null

    $augmentRecords = @(1..3 | ForEach-Object { New-Record "补检问题 $_？" "补检答案 $_。" })
    $augmentCoverage = @([pscustomobject]@{page=1;kind='technical';units=@(
        1..3 | ForEach-Object { [pscustomobject]@{summary="补检单元 $_";source_type='关系';source_fact="补检事实 $_";question="补检问题 $_？"} }
    ) + @(
        [pscustomobject]@{summary='已有覆盖单元';source_type='条件';source_fact='已有问题可精确覆盖的条件事实';skip_reason='已有问答充分覆盖';covered_by=@('初始问题 1？')}
    )})
    $augmentPath = Join-Path $testRoot '_qa_work\tmp\augment.json'
    [IO.File]::WriteAllText($augmentPath, ([pscustomobject]@{book_id='sample';start_page=1;end_page=1;coverage=$augmentCoverage;records=$augmentRecords} | ConvertTo-Json -Depth 8), $utf8)
    $result = & $qaWork -Action Augment -WorkspaceRoot $testRoot -BookId 'sample' -BatchFile '_qa_work\tmp\augment.json' -AsJson | ConvertFrom-Json

    $state = Get-Content -LiteralPath (Join-Path $testRoot '_qa_work\sample\state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([int]$result.added -eq 3) 'augmentation should add three records'
    Assert-True ([int]$state.record_count -eq 6) 'state should include augmented records'
    Assert-True ([int]$state.next_page -eq 2) 'augmentation must not advance next_page'
    Assert-True (@($state.augmentation_commits).Count -eq 1) 'state should retain augmentation history'
    Assert-True (-not [IO.File]::Exists($augmentPath)) 'successful augmentation should remove its temporary batch'

    [pscustomobject]@{status='passed';added=$result.added;total=$state.record_count;next_page=$state.next_page} | ConvertTo-Json -Compress
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolvedTest)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
