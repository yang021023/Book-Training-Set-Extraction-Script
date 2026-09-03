param(
    [string]$Workspace = 'D:\工装数据'
)

$sourceRel = '工装数据3\现代数控机床设计典例 (龚仲华) (z-library.sk, 1lib.sk, z-lib.sk).jsonl'
$source = Join-Path $Workspace $sourceRel
$outDir = Join-Path $Workspace '清洗后数据\工装数据3'
$base = [System.IO.Path]::GetFileNameWithoutExtension($source)
$cleanRel = "清洗后数据\工装数据3\$base.jsonl"
$decRel = "清洗后数据\工装数据3\$base.cleanup-decisions.jsonl"
$sumRel = "清洗后数据\工装数据3\$base.cleanup-summary.csv"
$clean = Join-Path $Workspace $cleanRel
$decisions = Join-Path $Workspace $decRel
$summary = Join-Path $Workspace $sumRel

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Only non-self-contained product identifiers, local diagram labels, and
# unresolved table-only specifications are changed here. Standards and
# material/accuracy grades remain in the data when their meaning is explicit.
$rewrites = @{
    135 = @{ reason='rewrite_remove_figure_reference'; q='刀具固定、工件运动的机床应怎样确定坐标轴正方向？'; a='坐标方向以刀具运动方向为准；若由工件运动而刀具固定，则工件运动方向与规定的刀具正方向相反。' }
    461 = @{ reason='rewrite_antecedent_and_remove_product_context'; q='车削中心刀架的动力刀具标准配置和最高转速是什么？'; a='标准配置为ER25刀柄的12刀位VDI30刀具，也可选ER32刀柄的10刀位VDI40刀具；动力刀具最高转速为8000 r/min。' }
    463 = @{ reason='rewrite_antecedent_and_remove_product_context'; q='车削中心刀架Y轴的行程、快进速度和传动形式是什么？'; a='Y轴行程为85 mm，快进速度为10 m/min，由交流伺服电机经同步带驱动滚珠丝杠。' }
    502 = @{ reason='rewrite_remove_nonstandard_model_codes'; q='立式数控镗铣床型号的主参数通常如何表示，标准规定与实际命名有何差异？'; a='部分立式数控镗铣床按工作台宽度的1/10表示主参数；按标准规定应以最大镗孔直径表示的系列，实际产品中也常按工作台宽度的1/10命名。' }
    613 = @{ reason='rewrite_remove_product_model_codes'; q='普通立式、双工作区交换动柱式和双主轴四轴立式加工中心分别有什么结构特点？'; a='普通立式加工中心不带双工作区交换；双工作区交换的动柱式立式中心可在两个工作区之间切换；双主轴四轴立式中心带工作台交换装置，并由两根主轴配合四轴加工。' }
    614 = @{ reason='rewrite_remove_product_model_codes'; q='加工中心型号中的主参数通常如何由工作台宽度折算？'; a='不同系列的命名折算比例可能不同：有的按工作台宽度的1/10命名，有的按1/100命名；因此应先确认该系列采用的命名规则，再由工作台宽度确定型号主参数。' }
    621 = @{ reason='rewrite_remove_product_model_codes'; q='五轴或铣车复合加工中心的双轴配置有哪些典型形式？'; a='可采用C轴360°回转与A轴摆动的双轴转台；也可采用主轴箱B轴摆动与A轴360°回转；铣车复合结构还可采用车削C轴转台与A轴摆动。' }
    742 = @{ reason='rewrite_remove_product_model_codes'; q='国产卧式加工中心型号中的回转工作台规格和重大改进后缀通常怎样表示？'; a='型号通常以回转工作台规格体现主参数，例如400×400 mm或630×630 mm工作台可由相应数字表示；B后缀表示重大改进的高速高精度设计。' }
    791 = @{ reason='rewrite_remove_nonstandard_product_example'; q='为什么不能把变频器的频率调节范围直接当作主轴有效调速范围？'; a='频率调节范围只说明变频器能输出的频率，主轴有效调速范围还必须保证可输出切削所需转矩。低频时电机常不能提供正常转矩，因此实际有效调速范围通常小于变频器标称的频率范围。' }
    1107 = @{ reason='rewrite_remove_local_component_labels_and_model_code'; q='一台普通卧式车床数控化改造时，主传动中哪些部件应拆除或保留，主轴位置编码器可安装在哪里？'; a='应拆除用于主轴正反转和起停控制的双向多片电磁离合器；保留主电机与主传动之间的带传动（减速比130/230）。可在与主轴按1:1连接的传动轴上安装主轴位置编码器。' }
    1108 = @{ reason='rewrite_remove_model_code'; q='普通卧式车床数控化改造中，为适配普及型CNC常见的两档主轴换档，为什么不宜采用三联滑移齿轮？'; a='国产普及型CNC的主轴传动级交换通常较简单，多数仅有两档传动和交换功能，使用三联滑移齿轮不利于简化匹配。' }
    1109 = @{ reason='rewrite_remove_model_code_and_local_axis_label'; q='采用两档机械辅助变速、主电机5～100Hz的一台普通车床改造中，高低档主轴转速范围和低速特性如何？'; a='高速档约70～1400 r/min，低速档约25～500 r/min；这种方案的低速性能相对较差。' }
    1110 = @{ reason='rewrite_remove_model_code'; q='一台普通车床为保持1400 r/min最高转速而把变频范围扩至5～140 Hz时，主轴范围和机械检查要求是什么？'; a='高速档为50～1400 r/min，低速档为12.5～350 r/min，低速性能基本保持；但电机最高转速达4000 r/min，必须检查确认传动轴承和动平衡等。' }
    1111 = @{ reason='rewrite_remove_model_code'; q='一台普通卧式车床数控化改造的Z轴与X轴进给系统应采用哪些丝杠、传动比和伺服参数？'; a='Z轴滚珠丝杠导程10 mm、同步带减速比1:2，伺服额定转矩11.5 N·m、最高3000 r/min；X轴导程5 mm、同步带比1:1，伺服额定转矩5.39 N·m、最高3000 r/min。' }
    1112 = @{ reason='rewrite_remove_model_code'; q='普通卧式车床数控化改造中，Z轴和X轴滚珠丝杠分别采用什么支承方式？'; a='Z轴采用一端固定、一端游动的G-Y支承；X轴采用一端固定、一端自由的G-Z支承。' }
    1118 = @{ reason='rewrite_remove_model_code_and_local_axis_labels'; q='升降台铣床数控化改造中，主传动系统哪些结构通常保留？'; a='通常保留主电机至输入轴的带传动（减速比140/285）、中间轴的伞齿轮偏摆传动、中间轴与输出轴的1:1连接，以及保证套筒进给时主轴传动的花键结构。' }
    1119 = @{ reason='rewrite_remove_model_code_and_local_axis_label'; q='升降台铣床变频主传动为何选择双联滑移齿轮作机械辅助变速？'; a='1450 r/min感应电机的变频最高频率宜控制在约100 Hz，有效调速范围约1:20。选择双联滑移齿轮可获得高、低两档机械辅助变速，扩展适用转速范围。' }
    1120 = @{ reason='rewrite_remove_model_code_and_local_axis_labels'; q='升降台铣床采用辅助机械变速、主电机5～100 Hz时，传动比和主轴高低档范围是多少？'; a='固定前级传动比22/33和28/37后，双联齿轮形成约1:2和1:15两档总减速比；主轴高速档约72～1440 r/min，低速档约20～200 r/min。' }
    1122 = @{ reason='rewrite_remove_model_code'; q='升降台铣床数控化改造中，X、Y、Z轴的丝杠导程、传动与快进参数如何配置？'; a='X、Y轴滚珠丝杠导程均6 mm，伺服额定转矩11.5 N·m、最高3000 r/min、快进12 m/min；X直连，Y用1:1同步带。Z轴导程10 mm，伞齿轮减速比1:2，伺服18.6 N·m、最高3000 r/min，快进10 m/min。' }
    1128 = @{ reason='rewrite_remove_product_model_code'; q='钟形壳内球面数控磨床改造中，为什么选择内圆磨床作为基础，Z轴和X轴分别为什么改为伺服进给？'; a='内球面加工属于内圆加工范畴，可选用原有内圆磨床作为改造基础。床头箱Z轴改伺服以适应工件长度变化和调整球心；磨头径向X轴改伺服以实现砂轮径向进给、自动修整和补偿。' }
    1132 = @{ reason='rewrite_remove_product_model_code'; q='用于钟形壳内球面加工的原有内圆磨床主轴哪些部分可保留，为什么仍需进行内部改造？'; a='原双速电机和带传动主轴可继续用于钟形壳加工；但主轴内部必须增加工件自动定心及液压松夹机构，所以仍需改造。' }
    1135 = @{ reason='rewrite_remove_product_model_code'; q='原有内圆磨床在钟形壳内球面数控化改造中，导轨和进给系统分别如何处理？'; a='X轴滚针导轨和Z轴润滑良好的滑动导轨摩擦小、精度高，可保留；原液压油缸进给无法调节行程和速度，应以伺服电机驱动滚珠丝杠的传动系统替换。' }
    1143 = @{ reason='rewrite_remove_product_model_code'; q='星形套直滚道磨床改造为什么可选普通平面磨床作为基础？'; a='直滚道的工艺要求类似平面磨床的成型磨削加工，普通平面磨床适合作为改造基础。' }
}

$deletes = @{
    622 = 'drop_product_table_specification_without_standalone_context'
    623 = 'drop_product_table_specification_without_standalone_context'
    624 = 'drop_product_table_specification_without_standalone_context'
    630 = 'drop_product_table_specification_without_standalone_context'
    737 = 'drop_product_table_specification_without_standalone_context'
    739 = 'drop_product_table_specification_without_standalone_context'
    740 = 'drop_product_table_specification_without_standalone_context'
    741 = 'drop_product_table_specification_without_standalone_context'
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$writer = New-Object System.IO.StreamWriter($clean, $false, $utf8)
$decisionWriter = New-Object System.IO.StreamWriter($decisions, $false, $utf8)
$counts = @{}
$sourceLine = 0
$outputLine = 0
try {
    foreach($raw in [System.IO.File]::ReadLines($source)) {
        $sourceLine++
        $before = $raw | ConvertFrom-Json
        $beforeMessages = [pscustomobject]@{ messages = $before.messages }
        $action = 'keep'
        $reason = 'retained_self_contained_technical_qa'
        $afterMessages = $beforeMessages

        if($deletes.ContainsKey($sourceLine)) {
            $action = 'delete'
            $reason = $deletes[$sourceLine]
            $afterMessages = $null
        } elseif($rewrites.ContainsKey($sourceLine)) {
            $action = 'rewrite'
            $reason = $rewrites[$sourceLine].reason
            $afterMessages = [pscustomobject]@{ messages = @(
                [pscustomobject]@{ role='user'; content=$rewrites[$sourceLine].q },
                [pscustomobject]@{ role='assistant'; content=$rewrites[$sourceLine].a }
            ) }
        }

        if($action -ne 'delete') {
            $outputLine++
            $writer.WriteLine(($afterMessages | ConvertTo-Json -Depth 10 -Compress))
        }

        if(-not $counts.ContainsKey($action)) { $counts[$action] = 0 }
        $counts[$action]++
        $decision = [pscustomobject]@{
            source_file = ($sourceRel -replace '\\','/')
            source_line = $sourceLine
            record_id = ('modern-cnc-design-{0:D4}' -f $sourceLine)
            action = $action
            reason = $reason
            source_pages = @()
            before = $beforeMessages
            after = $afterMessages
            output_line = $(if($action -eq 'delete') { $null } else { $outputLine })
        }
        $decisionWriter.WriteLine(($decision | ConvertTo-Json -Depth 10 -Compress))
    }
} finally {
    $writer.Dispose()
    $decisionWriter.Dispose()
}

$summaryRows = @(
    [pscustomobject]@{ action='delete'; reason='drop_product_table_specification_without_standalone_context'; count=$deletes.Count }
)
foreach($entry in ($rewrites.GetEnumerator() | Group-Object { $_.Value.reason })) {
    $summaryRows += [pscustomobject]@{ action='rewrite'; reason=$entry.Name; count=$entry.Count }
}
$summaryRows += [pscustomobject]@{ action='keep'; reason='retained_self_contained_technical_qa'; count=($sourceLine - $deletes.Count - $rewrites.Count) }
$summaryRows | Sort-Object action,reason | Export-Csv -LiteralPath $summary -NoTypeInformation -Encoding UTF8

Write-Output ("source_lines={0}; output_lines={1}; rewrites={2}; deletes={3}" -f $sourceLine,$outputLine,$rewrites.Count,$deletes.Count)
Write-Output $clean
Write-Output $decisions
Write-Output $summary
