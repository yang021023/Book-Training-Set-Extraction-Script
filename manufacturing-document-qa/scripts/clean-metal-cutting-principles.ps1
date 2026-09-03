param(
    [string]$Workspace = 'D:\工装数据'
)

$sourceRel = '工装数据1\金属切削原理与刀具 (刘鹏德，段晶莹主编, Pengde Liu, Jingying Duan, 刘鹏德 etc.) (z-library.sk, 1lib.sk, z-lib.sk).jsonl'
$source = Join-Path $Workspace $sourceRel
$outDir = Join-Path $Workspace '清洗后数据\工装数据1'
$base = [IO.Path]::GetFileNameWithoutExtension($source)
$cleanRel = "清洗后数据\工装数据1\$base.jsonl"
$decRel = "清洗后数据\工装数据1\$base.cleanup-decisions.jsonl"
$sumRel = "清洗后数据\工装数据1\$base.cleanup-summary.csv"
$clean = Join-Path $Workspace $cleanRel
$decisions = Join-Path $Workspace $decRel
$summary = Join-Path $Workspace $sumRel

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Remove local figure labels, product names, and TSG/TMG table lookups while
# preserving the underlying tool-selection, connection, centering, locking,
# and dimensional facts in standalone wording.
$rewrites = @{
    441 = @{ reason='rewrite_remove_local_wear_zone_labels'; q='后刀面磨损带的最大、平均和边界沟磨损分别用哪些参数表示？'; a='最大磨损量用VC表示；中部磨损带的平均磨损量用VB表示、局部最大值用VBmax表示；边界沟深用VN表示。边界沟与高温氧化和加工表面硬化层的影响有关。' }
    600 = @{ reason='rewrite_local_insert_shape_codes'; q='通槽、半通槽和封闭槽分别适配什么刀片，主要特点是什么？'; a='通槽易加工，适配矩形刀片；半通槽适配带圆弧的刀片；封闭槽焊接面大、强度高但焊接应力也大，适合焊接面较小的刀片。' }
    601 = @{ reason='rewrite_local_insert_designation_context'; q='焊接硬质合金刀片型号通常如何编码？'; a='型号由一个字母和三位数字组成：字母及首位数字表示刀片形状，后两位表示主要尺寸；型号后缀L表示左切。例如某矩形刀片的标记可表示其长度为8 mm。' }
    603 = @{ reason='rewrite_local_insert_shape_codes'; q='不同形状的焊接硬质合金刀片分别适合哪些主要车削用途？'; a='矩形刀片主要用于外圆、镗孔、端面和切槽等；带圆弧的刀片主要用于螺纹车削，部分矩形或带圆弧刀片还可用于切断或切槽。' }
    1208 = @{ reason='rewrite_remove_local_tool_system_codes'; q='镗铣类数控机床常见的整体式和模块式工具系统有什么结构区别？'; a='整体式工具系统将与主轴连接的柄部和夹持刀具的工作部分制成一体；模块式工具系统则把柄部、接杆和工作部分分开制成系列化模块，再按用途和规格组合。' }
    1209 = @{ reason='rewrite_remove_local_tool_system_category_codes'; q='整体式镗铣工具系统按用途可配置哪些刀柄类别？'; a='可配置钻孔刀柄（安装钻夹头、锥柄夹头或铰刀）、铣刀刀柄（安装套式面铣刀、端铣刀、立铣刀或三面刃铣刀）、镗刀刀柄（安装粗镗刀、微调精镗刀或平面镗刀）、弹簧夹头刀柄、特殊刀柄、可拼装模块式刀柄、高效复合刀柄和接触式测头刀柄。' }
    1286 = @{ reason='rewrite_remove_local_turning_system_name'; q='整体式车削工具系统与哪一国际标准体系相当？'; a='与德国DIN 69880体系相当。' }
    1287 = @{ reason='rewrite_remove_product_brand_context'; q='模块式车削工具系统换刀时更换哪个部分？'; a='只更换头部的刀头模块，刀柄和夹紧单元可以保留。' }
    1288 = @{ reason='rewrite_remove_product_brand_context'; q='模块式车削工具系统在换刀速度方面有什么特点？'; a='只需更换刀头模块，因此换刀迅速。' }
    1289 = @{ reason='rewrite_remove_product_brand_context'; q='模块式车削工具系统在定位精度方面有什么特点？'; a='模块连接可获得很高的定位精度。' }
    1290 = @{ reason='rewrite_remove_product_brand_context'; q='模块式车削工具系统在联接刚性方面有什么特点？'; a='拉紧后的模块连接刚性高。' }
    1291 = @{ reason='rewrite_remove_product_brand_context'; q='模块式车削工具系统开始锁紧时，拉杆头部锥面先进入哪里？'; a='拉杆后移时，头部锥面先进入胀环端部。' }
    1292 = @{ reason='rewrite_remove_product_brand_context'; q='拉杆头部锥面进入胀环后，胀环如何与刀头模块接合？'; a='锥面使胀环张开，胀环外圆周边嵌入刀头模块的内沟槽。' }
    1293 = @{ reason='rewrite_remove_product_brand_context'; q='胀环嵌入刀头模块沟槽后，继续后移拉杆怎样完成锁紧？'; a='拉杆通过胀环拉动刀头模块向后移动，使模块被拉紧并锁定在刀柄上。' }
    1294 = @{ reason='rewrite_remove_product_brand_context'; q='模块式车削系统开始松开时，拉杆前移会使胀环发生什么变化？'; a='胀环与拉杆锥面的接触直径减小，胀环随之收缩。' }
    1295 = @{ reason='rewrite_remove_product_brand_context'; q='胀环直径缩小后，怎样解除与刀头模块的连接？'; a='胀环外圆周边退出刀头模块的内沟槽，从而解除连接。' }
    1296 = @{ reason='rewrite_remove_product_brand_context'; q='胀环与内沟槽分离后，刀头模块怎样被卸出？'; a='拉杆继续向前移动，直接把刀头模块推出刀柄。' }
    1297 = @{ reason='rewrite_remove_product_brand_context'; q='模块式车削系统可怎样从夹紧单元侧面驱动拉杆？'; a='可转动侧面凸轮，使凸轮在拉杆槽内作用并带动拉杆移动。' }
    1298 = @{ reason='rewrite_remove_product_brand_context'; q='模块式车削系统可怎样从夹紧单元后部驱动拉杆？'; a='可旋转夹紧单元后部的螺钉来推动或拉动拉杆。' }
    1299 = @{ reason='rewrite_remove_product_brand_context'; q='模块式车削工具系统的重复定位精度可达到多少？'; a='重复定位精度可达到±2 μm。' }
    1306 = @{ reason='rewrite_remove_local_tool_system_codes'; q='整体式镗铣工具系统的手动换刀和自动换刀分别应采用什么柄部？'; a='手动换刀采用适配手动换刀的柄部，自动换刀采用适配自动换刀机构的柄部。' }
    1307 = @{ reason='rewrite_remove_local_tool_system_codes'; q='整体式镗铣工具系统中，自动换刀柄部与手动换刀柄部的用途有何区别？'; a='自动换刀柄部用于与机床自动换刀机构配合，手动换刀柄部用于人工装卸；两者按换刀方式分别选用。' }
    1308 = @{ reason='rewrite_remove_local_tool_connection_codes'; q='整体式镗铣工具系统常见的刀柄、接杆与刀具连接形式有哪些？'; a='可采用直柄接杆连接刀具、锥柄接杆连接刀具、锥柄直接连接带扁尾的莫氏锥柄刀具，或由刀柄直接连接镗孔刀具而不使用中间接杆。' }
    1335 = @{ reason='rewrite_remove_local_tool_system_name'; q='整体式镗铣工具系统由哪些基本部分组成？'; a='由刀柄、多种接杆和少量工作刀具组成。' }
    1336 = @{ reason='rewrite_remove_local_tool_system_name'; q='整体式镗铣工具系统可覆盖哪些主要加工工序？'; a='可用于平面、斜面、沟槽加工，以及铣削、钻孔、扩孔、铰孔、镗孔和攻螺纹等工序。' }
    1337 = @{ reason='rewrite_remove_local_tool_system_name'; q='整体式镗铣工具系统在结构和使用方面有什么特点？'; a='其结构简单，使用方便。' }
    1338 = @{ reason='rewrite_remove_local_tool_system_name'; q='整体式镗铣工具系统在装卸和换刀方面有什么特点？'; a='标准部件组合使其装卸灵活、换刀迅速。' }
    1339 = @{ reason='rewrite_remove_local_tool_system_codes'; q='整体式镗铣工具系统怎样用标准化部件组成不同用途的工具？'; a='以适配机床的主柄为基础，按加工任务组合接杆、快换夹头和相应工作刀具，即可形成钻、扩、铰、镗、攻螺纹和铣削等不同用途的工具链。' }
    1340 = @{ reason='rewrite_remove_toolholder_model_code'; q='镗长杆刀柄的尺寸标记通常应说明哪些几何参数？'; a='应说明柄部的7∶24锥柄规格及大端直径、与接长杆配合的直径，以及刀柄装入主轴后的伸出长度。' }
    1343 = @{ reason='rewrite_remove_toolholder_model_code'; q='三面刃铣刀接长杆的尺寸标记通常应说明哪些几何参数？'; a='应说明与接长杆刀柄配合的直径、与三面刃铣刀连接部分的直径，以及接长杆长度。' }
    1346 = @{ reason='rewrite_remove_toolholder_model_code'; q='带扁尾莫氏孔刀柄的尺寸标记通常应说明哪些参数？'; a='应说明柄部的7∶24锥柄规格及大端直径、与刀具连接的莫氏锥度，以及刀柄装入主轴后的伸出长度。' }
    1353 = @{ reason='rewrite_remove_local_tool_system_numbering'; q='模块式镗铣工具系统通常依据哪些结构参数区分不同系统？'; a='主要依据模块联接的定心方式和锁紧方式区分。定心方式可采用短圆锥、单圆柱面、双键、端齿啮合或双圆柱面定心；锁紧方式可采用中心螺钉、径向螺钉或楔块、径向双头螺栓、径向单侧螺钉、径向两螺钉或螺纹联接锁紧。' }
    1360 = @{ reason='rewrite_remove_local_tool_system_name'; q='采用圆柱定心和径向锁紧的模块式工具系统，其模块组合链由哪三个层次构成？'; a='由主柄模块、中间模块和工作模块三个层次构成。' }
    1368 = @{ reason='rewrite_remove_local_tool_system_name'; q='圆柱定心、径向锁紧的模块式工具系统采用什么方式实现模块定心？'; a='采用定位圆柱插入定位孔的圆柱面定心方式。' }
    1369 = @{ reason='rewrite_remove_local_tool_system_name'; q='圆柱定心、径向锁紧的模块式工具系统在定位圆柱横向设置锥端滑销有什么作用？'; a='滑销在紧固螺钉的锥面作用下横向移动，并带动刀具模块产生轴向拉紧运动。' }
    1370 = @{ reason='rewrite_remove_local_tool_system_name'; q='圆柱定心、径向锁紧的模块式工具系统中，固定螺钉和紧固螺钉如何布置？'; a='定位孔两侧分别设置内锥端固定螺钉和外锥端紧固螺钉，两者轴线相对滑销轴线偏置一定距离。' }
    1371 = @{ reason='rewrite_remove_local_tool_system_name'; q='圆柱定心、径向锁紧的模块式工具系统拧紧外锥端紧固螺钉后，模块怎样被拉紧？'; a='紧固螺钉和固定螺钉的内外锥面推动滑销，滑销带动刀具模块轴向移动，使结合端面贴紧并形成很大正压力。' }
    1372 = @{ reason='rewrite_remove_local_tool_system_name'; q='径向锁紧的模块式工具系统对更换工作模块有什么好处？'; a='更换刀具或工作模块时不必卸下整套工具。' }
    1373 = @{ reason='rewrite_remove_local_tool_system_name'; q='圆柱定心、径向锁紧的模块式工具系统特别适用于哪类机床？'; a='特别适用于重型数控镗铣床。' }
    1374 = @{ reason='rewrite_remove_local_tool_system_name'; q='圆柱定心、径向锁紧的模块式工具系统怎样通过孔轴配合和端面贴合提高刀柄刚性？'; a='精密孔轴配合负责定心，锁紧产生的轴向力使结合端面紧密贴合，从而提高刀柄刚性。' }
    1375 = @{ reason='rewrite_remove_local_tool_system_name'; q='圆柱定心、径向锁紧的模块式工具系统为什么制造困难？'; a='其精度取决于轴孔配合间隙和结合端面的轴向跳动，两项制造允差都很小。' }
    1376 = @{ reason='rewrite_remove_local_tool_system_name'; q='圆柱定心、径向锁紧的模块式工具系统中，配合圆柱前端为什么做成直径略小的鼓形导入部分？'; a='用于引导配合圆柱在组装时顺利插入定位孔。' }
    1377 = @{ reason='rewrite_remove_local_tool_system_name'; q='短锥定心、中心螺栓轴向拉紧的模块式工具系统采用什么定心和拉紧结构？'; a='采用短锥定心、中心螺栓轴向拉紧结构。' }
    1378 = @{ reason='rewrite_remove_local_tool_system_name'; q='短锥定心、中心螺栓轴向拉紧的模块式工具系统拉紧后哪些表面同时参与定位和承载？'; a='短锥锥面与结合端面同时紧密贴合。' }
    1379 = @{ reason='rewrite_remove_local_tool_system_name'; q='短锥定心、中心螺栓轴向拉紧的模块式工具系统为什么能获得较高的定心精度和联接刚度？'; a='中心螺栓轴向拉紧后，短锥锥面定心且端面贴合，形成双面接触。' }
    1380 = @{ reason='rewrite_remove_local_tool_system_name'; q='短锥定心、中心螺栓轴向拉紧的模块式工具系统更换工作模块时为什么拆装不方便？'; a='更换工作模块必须把所有联接模块依次拆卸下来。' }
    1381 = @{ reason='rewrite_remove_local_tool_system_name'; q='短锥定心、中心螺栓轴向拉紧的模块式工具系统在制造超差后的可修复性方面有什么特点？'; a='制造过程中即使出现超差，也可以通过修整恢复要求。' }
    1382 = @{ reason='rewrite_remove_local_tool_system_name'; q='短锥定心、中心螺栓轴向拉紧的模块式工具系统与圆柱定心、径向锁紧的模块式工具系统相比，生产成本为什么较低？'; a='前者连接结构较简单，因此生产成本较低。' }
    1383 = @{ reason='rewrite_remove_local_tool_system_name'; q='短锥定心、中心螺栓轴向拉紧的模块式工具系统适用于哪些机床？'; a='适用于中小型数控镗铣床和加工中心。' }
}

$deletes = @{}
$deletes[584] = 'drop_local_turning_tool_number_lookup'
foreach($line in 1210..1216) { $deletes[$line] = 'drop_local_tool_system_category_code_lookup'
}
foreach($line in 1309..1334) { $deletes[$line] = 'drop_local_tool_system_code_lookup'
}
$deletes[1352] = 'drop_local_tool_system_acronym_lookup'
$deletes[1354] = 'drop_local_tool_system_numbering_lookup'
foreach($line in 1355..1359) { $deletes[$line] = 'drop_local_tool_system_number_lookup'
}
foreach($line in 1361..1367) { $deletes[$line] = 'drop_local_tool_system_number_lookup'
}
foreach($line in 1341,1342,1344,1345,1347,1348) { $deletes[$line] = 'drop_toolholder_model_code_lookup'
}

$utf8 = [Text.UTF8Encoding]::new($false)
$writer = [IO.StreamWriter]::new($clean, $false, $utf8)
$decisionWriter = [IO.StreamWriter]::new($decisions, $false, $utf8)
$counts = @{}
$sourceLine = 0
$outputLine = 0
try {
    foreach($raw in [IO.File]::ReadLines($source)) {
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
            record_id = ('jinshu-qiexiao-{0:D4}' -f $sourceLine)
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

$summaryRows = foreach($group in ($counts.GetEnumerator() | Sort-Object Name)) {
    [pscustomobject]@{ action=$group.Name; reason=$(switch($group.Name) { 'keep' {'retained_self_contained_technical_qa'} 'rewrite' {'standalone_context_or_local_code_rewrite'} 'delete' {'local_or_nonstandalone_code_lookup'} }); count=$group.Value }
}
$summaryRows | Export-Csv -LiteralPath $summary -NoTypeInformation -Encoding UTF8

Write-Output ("source_lines={0}; output_lines={1}; rewrites={2}; deletes={3}" -f $sourceLine,$outputLine,$counts['rewrite'],$counts['delete'])
Write-Output $clean
Write-Output $decisions
Write-Output $summary
