param(
    [string]$Workspace = 'D:\工装数据'
)

$ErrorActionPreference = 'Stop'

$sourceRel = '工装数据1\实用机械加工工艺手册 第5版 (陈宏钧,单立红) (z-library.sk, 1lib.sk, z-lib.sk).jsonl'
$source = Join-Path $Workspace $sourceRel
$outDir = Join-Path $Workspace '清洗后数据\工装数据1'
$base = [System.IO.Path]::GetFileNameWithoutExtension($source)
$cleanRel = "清洗后数据\工装数据1\$base.jsonl"
$decRel = "清洗后数据\工装数据1\$base.cleanup-decisions.jsonl"
$sumRel = "清洗后数据\工装数据1\$base.cleanup-summary.csv"
$clean = Join-Path $Workspace $cleanRel
$decisions = Join-Path $Workspace $decRel
$summary = Join-Path $Workspace $sumRel

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function New-Messages([string]$Question, [string]$Answer) {
    return [pscustomobject]@{
        messages = @(
            [pscustomobject]@{ role = 'user'; content = $Question },
            [pscustomobject]@{ role = 'assistant'; content = $Answer }
        )
    }
}

# These rewrites remove source-page/case/table pointers while retaining the
# technical fact that is explicitly present in the original QA.
$rewrites = @{
    871  = @{ reason='rewrite_remove_table_pointer'; q='一般用途热轧扁钢能否供应未列入标准尺寸系列的规格？'; a='经供需双方协商并在合同中注明，可以提供标准尺寸系列以外的尺寸及相应理论质量。' }
    254  = @{ reason='rewrite_remove_drawing_reference'; q='机械图样上标注的尺寸通常表示什么状态的尺寸？'; a='通常表示所示机件的最后完工尺寸；若不是最后完工尺寸，必须另加说明。' }
    301  = @{ reason='rewrite_remove_drawing_reference'; q='滚动轴承外形轮廓的尺寸和比例有什么要求？'; a='矩形线框或外形轮廓应与轴承外形尺寸一致，并与所属机械图样采用相同比例。' }
    314  = @{ reason='rewrite_remove_drawing_reference'; q='机械图样用符号表示焊缝时，还必须标注什么？'; a='还必须同时标注焊缝符号。' }
    873  = @{ reason='rewrite_remove_table_pointer'; q='优质结构钢冷拉扁钢的理论质量按什么密度计算？'; a='按密度7.85g/cm³计算。' }
    1884 = @{ reason='rewrite_remove_drawing_reference'; q='相配件的倒角和倒圆有哪两种型式，d3与d1、a有什么关系？'; a='有A型和B型两种；尺寸关系为 d3=d1−a。' }
    1895 = @{ reason='rewrite_remove_table_pointer'; q='A型退刀槽在不同配合时，长度f1应怎样计入，其他尺寸如何确定？'; a='f1应包括在公差带较小的一段长度内；其余尺寸按配合直径d1确定。' }
    1900 = @{ reason='rewrite_remove_table_pointer'; q='砂轮越程槽采用什么标准，型式和尺寸如何确定？'; a='采用GB/T 6403.5—2008规定的型式和尺寸，并按磨削外圆、内圆、端面或其组合选择相应结构。' }
    1901 = @{ reason='rewrite_remove_drawing_reference'; q='磨回转面及端面时，砂轮越程槽包括哪些加工型式？'; a='包括磨外圆、磨内圆、磨外端面、磨内端面、磨外圆及端面、磨内圆及端面六种加工型式。' }
    1912 = @{ reason='rewrite_remove_table_pointer'; q='润滑槽采用什么标准，型式和尺寸如何确定？'; a='采用GB/T 6403.2—2008规定的型式和尺寸，并按润滑部位及运动方向选择相应结构。' }
    1923 = @{ reason='rewrite_remove_table_pointer'; q='T形槽采用什么标准，尺寸如何确定？'; a='采用GB/T 158—1996规定的型式和尺寸；宽度、公差及槽间距应按工作台结构和使用要求选取。' }
    1935 = @{ reason='rewrite_remove_table_pointer'; q='零件倒圆与倒角采用什么标准，尺寸如何确定？'; a='采用GB/T 6403.4—2008规定的尺寸系列，并按零件结构和装配要求选取。' }
    2021 = @{ reason='rewrite_remove_table_pointer'; q='零件未注45°倒角时，怎样按D或d选择倒角尺寸C？'; a='按D或d分段选择：≤5、>5～30、>30～100、>100～250、>250～500、>500～1000、>1000 mm时，C分别为0.2、0.5、1、2、3、4、5 mm。' }
    2042 = @{ reason='rewrite_salvage_independent_datum_rule'; q='未注圆跳动公差的基准要素如何选择？'; a='优先以设计或工艺给出的支承面作为基准；没有支承面时取较长要素作基准，等长时任选。' }
    2054 = @{ reason='rewrite_remove_table_pointer'; q='工艺文件类型代号、方法代号和登记顺序号如何确定与登记？'; a='类型代号和方法代号按工艺文件编号规定确定；登记顺序号由企业工艺标准部门统一给定。编号应登记，不同特征号的文件应分别登记。' }
    2057 = @{ reason='rewrite_remove_drawing_reference'; q='工艺守则、工序质量文件、操作指导卡片、控制图和关键件明细表的类型代号分别是什么？'; a='工艺守则29，工序质量管理文件30，工序质量分析表31，操作指导卡片32，控制图33，零件明细表40，工艺关键件明细表41。' }
    2103 = @{ reason='rewrite_remove_drawing_reference'; q='常用锻造、焊接、冲压、机械加工、热处理、装配和检验工艺文件分别采用哪些类型编号？'; a='锻造6，焊接7，冲压8，机械加工过程9，机械加工工序10，标准或典型零件过程11，热处理14，装配过程23，装配工序24，机械加工操作指导27/27a，检验28，工艺附图29，工艺守则30。' }
    2067 = @{ reason='rewrite_remove_arbitrary_example_code'; q='不带产品代号的工艺文件编号如何由特征号和登记顺序号构成？'; a='由四位特征号与登记顺序号以一字线连接；前两位为文件类型代号，后两位为工艺方法代号，登记顺序号按该特征号分别连续编排。' }
    2069 = @{ reason='rewrite_remove_arbitrary_example_code'; q='带产品代号的工艺文件编号如何组成？'; a='由产品代号、工艺文件特征号和登记顺序号组成，各部分以一字线隔开。' }
    2361 = @{ reason='rewrite_remove_case_reference'; q='连杆螺钉的调质处理应安排在何时，粗加工为何要预留余量？'; a='调质处理应安排在粗加工后。由于调质会产生变形，粗加工时应预留加工余量；该连杆工艺预留3mm。' }
    2372 = @{ reason='rewrite_remove_case_reference'; q='输出轴粗车和精车后通常如何安排后续加工余量？'; a='粗车各部通常留精加工余量，该输出轴工艺留3mm；需要磨削的轴径在精车后再留磨削余量，该工艺留0.8mm。' }
    2429 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴选用什么材料？'; a='齿轮轴选用40Cr钢。' }
    2430 = @{ reason='rewrite_remove_case_antecedent'; q='40Cr齿轮轴调质后的硬度要求是多少？'; a='调质后的硬度要求为28～32HRC。' }
    2431 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴三处轴颈外圆对公共轴线的圆跳动公差是多少？'; a='三处轴颈外圆相对公共轴线A—B的圆跳动公差均为0.025mm。' }
    2432 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴键槽对公共轴线的对称度公差是多少？'; a='键槽对公共轴线的对称度公差为0.02mm。' }
    2433 = @{ reason='rewrite_remove_case_antecedent'; q='为什么齿轮轴在调质后再进行精车和磨削？'; a='这样安排可使精加工在调质后完成，从而有利于保证加工质量稳定。' }
    2436 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴铣键槽用的组合夹具为什么要设置键槽对称度检查基准？'; a='键槽对称度检查基准可供键槽加工时对刀以及加工后的对称度检查使用。' }
    2437 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴在磨削前的主要工艺路线如何安排？'; a='主要依次为下料、锻造、正火、两次粗车、调质和两次精车；精车时分别加工两端端面并钻出两端中心孔，然后进入磨削。' }
    2438 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴精车后在直径方向应留多少磨削余量？'; a='两次精车后，直径方向均应留0.6mm的磨削余量。' }
    2439 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴粗磨和精磨各部外圆、圆角时采用什么定位基准并加工到什么程度？'; a='以两端中心孔定位装夹，粗磨、精磨各部外圆及相应圆角，直至达到各外圆和圆角的设计尺寸。' }
    2440 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴铣18N9键槽时用哪些部位定位装夹？'; a='以两处φ60k6轴颈定位装夹工件。' }
    2441 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴滚齿时以哪一处轴颈定位装夹？'; a='以φ65r6轴颈定位装夹工件。' }
    2442 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴滚齿后的收尾工序和最终质量检查包括哪些内容？'; a='滚齿后先去毛刺，再检查零件各部尺寸和精度；检验合格后入库。' }
    2443 = @{ reason='rewrite_remove_case_antecedent'; q='齿轮轴在铣键槽前安排了什么准备工序？'; a='在铣键槽前安排划键槽线工序。' }
    2448 = @{ reason='rewrite_remove_case_antecedent'; q='矩形齿花键轴的材料和调质硬度要求是什么？'; a='材料为45钢；调质后的硬度为28～32HRC。' }
    2449 = @{ reason='rewrite_remove_case_antecedent'; q='矩形齿花键轴下料采用什么规格的棒料？'; a='采用φ40mm×200mm棒料下料。' }
    2454 = @{ reason='rewrite_remove_case_antecedent'; q='矩形齿花键轴粗、精铣花键时的装夹方式和小径要求是什么？'; a='采用一夹一顶装夹，粗、精铣8×6mm矩形花键，并保证小径φ32mm。' }
    2459 = @{ reason='rewrite_remove_case_reference'; q='大径定心的矩形齿花键轴为什么要安排粗、精磨各部外圆？'; a='粗、精磨各部外圆可保证花键轴的大径达到φ36mm。' }
    2482 = @{ reason='rewrite_remove_case_antecedent'; q='丝杆采用什么规格和精度等级的梯形螺纹？'; a='采用Tr36×6-7e梯形螺纹。' }
    2483 = @{ reason='rewrite_remove_case_antecedent'; q='丝杆两端φ20mm轴心线的同轴度公差是多少？'; a='两端φ20mm轴心线的同轴度公差为φ0.08mm。' }
    2484 = @{ reason='rewrite_remove_case_antecedent'; q='梯形螺纹丝杆的材料、调质硬度和未注倒角要求是什么？'; a='材料为45钢，调质硬度为28～32HRC，未注倒角为C1。' }
    2521 = @{ reason='rewrite_remove_case_antecedent'; q='两孔连杆机械加工工艺适用于什么生产批量？'; a='适用于小批连杆生产加工。' }
    3486 = @{ reason='rewrite_remove_table_pointer'; q='JB/T 8046.2镗套用衬套的孔径d与外径D的标准公称尺寸范围是什么？'; a='衬套内孔d的标准公称尺寸为25～185mm，外径D为30～210mm；d、D应按JB/T 8046.2规定的匹配组合选取。' }
    3490 = @{ reason='rewrite_remove_drawing_reference'; q='JB/T 8029.2支承钉规定了哪些基本型式？'; a='标准支承钉分A型、B型、C型；具体尺寸按对应型式的标准规定选择。' }
    3510 = @{ reason='rewrite_remove_table_pointer'; q='选择镗刀杆锁紧楔时，应以哪些机床主轴参数为依据？'; a='应以机床主轴锥孔的圆锥号和相应D0尺寸为依据，使锁紧楔的L、b和B尺寸与主轴及镗刀杆相匹配；不能只按镗刀杆总长度选取。' }
    3535 = @{ reason='rewrite_remove_table_pointer'; q='JB/T 3411.96切槽刀杆按莫氏圆锥号怎样选择d、D和b？'; a='莫氏3号采用d=32mm、D=68mm、b=8mm；4号采用d=42mm、D=80mm、b=10mm；5号采用d=60mm、D=106mm、b=12mm。相应d1、L2、L和L1按同一标准的配套尺寸选取。' }
    3630 = @{ reason='rewrite_remove_table_pointer'; q='单键拉刀导套与键槽拉削垫片有什么配套关系？'; a='单键拉刀导套应与键槽拉削垫片按JB/T 3411.24配套选用，使垫片厚度和宽度与导套键槽及所需调整量相匹配。' }
    3632 = @{ reason='rewrite_remove_table_pointer'; q='键槽拉削用垫片的厚度h有哪些常用档次？'; a='常用厚度h包括0.10、0.20、0.30、0.50、1.00、2.00、3.00mm；应根据导套键槽和所需调整量选择合适厚度及宽度。' }
    4281 = @{ reason='rewrite_remove_table_pointer'; q='喷吸钻适用的钻头直径范围是多少？'; a='适用大于20～22mm至大于56～65mm的钻头直径范围。' }
    4621 = @{ reason='rewrite_remove_drawing_reference'; q='带侧面齿键槽拉刀按什么标准制造，有哪些基本型式？'; a='按JB/T 9993—2011制造；基本型式包括A型拉刀、B型粗拉刀和B型精拉刀。选型时还应结合键槽宽度、公差带和拉削长度。' }
    4622 = @{ reason='rewrite_remove_drawing_reference'; q='按JB/T 9993—2011制造的带侧面齿键槽拉刀，侧面齿角为多少？'; a='侧面齿角为50°。' }
    4628 = @{ reason='rewrite_remove_table_pointer'; q='选择B型粗拉刀规格时，应依据哪些工件参数确定结构参数？'; a='以键槽宽度和拉削长度为主要输入，确定拉削余量、垫片厚度、拉削次数、刀齿宽度b、拉刀全长L、前导部高度H3、刀体宽度B和校准齿高度。' }
    4843 = @{ reason='rewrite_remove_table_pointer'; q='粗镗断续表面或有冲击的加工时，进给量如何修正？'; a='进给量取连续切削推荐值的0.75～0.85倍。' }
    4846 = @{ reason='rewrite_remove_table_pointer'; q='用硬质合金或高速钢镗刀粗镗碳素结构钢时，选择进给量应依据哪些参数？'; a='应按镗杆尺寸、镗杆伸出长度、背吃刀量和工件材料选择进给量；例如10mm镗杆、伸出50mm、背吃刀量2mm时，f取0.08mm/r。材料强度或背吃刀量增大时，进给量应相应减小。' }
    4847 = @{ reason='rewrite_remove_table_pointer'; q='用硬质合金或高速钢镗刀粗镗铸铁或铜合金时，选择进给量应依据哪些参数？'; a='应按镗杆尺寸、伸出长度、背吃刀量和工件材料选择进给量；例如10mm镗杆、伸出50mm、背吃刀量2mm时，f取0.12～0.16mm/r，通常高于对应钢件的进给范围。' }
    4848 = @{ reason='rewrite_remove_table_pointer'; q='切断或切槽时如何按工件直径、切刀宽度和材料选择进给量？'; a='应综合工件直径、切刀宽度和材料选择进给量。例如直径≤20mm、切刀宽3mm时，碳素或合金结构钢及钢铸件f=0.06～0.08mm/r，铸铁、铜合金和铝合金为0.11～0.14mm/r；随着直径和切刀宽度增大，推荐进给量提高。' }
    4851 = @{ reason='rewrite_remove_table_pointer'; q='成形车削时怎样按刀具宽度和工件直径选择进给量？'; a='应按刀具宽度和工件直径选择进给量。例如刀宽10mm、工件直径25mm或不小于40mm时，f=0.04～0.085mm/r；刀宽20mm、直径不小于40mm时，f=0.04～0.08mm/r。' }
    4853 = @{ reason='rewrite_remove_table_pointer'; q='用P10硬质合金粗车钢件时，怎样按钢的抗拉强度选择切削速度？'; a='按钢的抗拉强度Rm分档，并结合背吃刀量和进给量选择切削速度；Rm越高、背吃刀量或进给量越大，推荐切削速度越低。' }
    4854 = @{ reason='rewrite_remove_table_pointer'; q='用K20硬质合金粗车铸铁时，怎样按材料硬度选择切削速度？'; a='按铸铁硬度HBW分档，并结合背吃刀量和进给量选择切削速度；硬度提高或背吃刀量、进给量增大时，应降低切削速度。' }
    4990 = @{ reason='rewrite_remove_table_pointer'; q='统一制螺纹攻丝前，粗牙UNC与细牙UNF怎样按公称直径和牙数选择底孔？'; a='应根据英寸公称直径和每英寸牙数选择底孔；相同公称直径下，细牙牙数较多，所需底孔更大。例如1/2-13 UNC用φ10.80mm，1/2-20 UNF用φ11.50mm。' }
    4992 = @{ reason='rewrite_remove_table_pointer'; q='55°与60°圆锥管螺纹攻丝前，底孔钻头选择应依据哪些参数？'; a='应依据圆锥角、螺纹尺寸代号和每英寸牙数选择底孔钻头；55°和60°圆锥管螺纹不能混用同一底孔直径。' }
    5667 = @{ reason='rewrite_remove_table_pointer'; q='选择扩孔钻切削用量时，应依据哪些工件材料和加工参数？'; a='先按工件材料及其强度或硬度条件选择对应参数，再结合扩孔钻直径和所用进给量确定切削用量。' }
    7052 = @{ reason='rewrite_remove_table_pointer'; q='纯铜管和黄铜管的最小弯形半径如何按管径和壁厚确定？'; a='按管径d和壁厚确定。例如壁厚1.0mm时，d=5～6mm取Rmin=10mm，d=7～12mm取15～20mm，d=14mm取20mm；壁厚1.5mm时，d=16～20mm取30mm，d=24～28mm取40～50mm。' }
    7053 = @{ reason='rewrite_remove_table_pointer'; q='铝管的最小弯形半径有哪些典型取值？'; a='按管径和壁厚确定。例如壁厚1.0mm时，d=6mm取Rmin=10mm，d=8～14mm取15～20mm；壁厚1.5mm时，d=16mm取30mm、d=20mm取30mm、d=25mm取50mm；壁厚2.0mm时，d=50～60mm取100～125mm。' }
    7057 = @{ reason='rewrite_remove_table_pointer'; q='无缝钢管管径159mm时，壁厚4.5mm和6.0mm对应的最小弯形半径分别是多少？'; a='壁厚4.5mm时Rmin=450mm；壁厚6.0mm时Rmin=420mm。' }
    7059 = @{ reason='rewrite_remove_table_pointer'; q='大直径无缝钢管的最小弯形半径有哪些典型取值？'; a='例如d=194mm、壁厚6.0mm时Rmin=500mm，d=219mm、壁厚6.0mm时取500mm，d=245mm、壁厚6.0mm时取600mm，d=273mm或325mm、壁厚8.0mm时分别取700mm和800mm。' }
    8017 = @{ reason='rewrite_remove_table_pointer'; q='双柄式螺纹塞规适用哪些大直径螺纹，长度怎样随螺距选择？'; a='适用于公称直径105～180mm等大直径螺纹，常用P=2、3、4、6、8mm；通端和止端长度随螺距增大分档配置。' }
}

$deletes = @{
    1879 = 'drop_table_only_dimension_reference'
    1896 = 'drop_table_only_dimension_reference'
    1964 = 'drop_table_only_thread_dimension_reference'
    2016 = 'drop_table_only_chamfer_round_reference'
    4612 = 'drop_table_only_broach_reference'
    2044 = 'drop_duplicate_incomplete_table_reference'
    2146 = 'drop_nontechnical_document_template_content'
    2845 = 'drop_nontechnical_document_traceability_content'
    2850 = 'drop_nontechnical_document_traceability_content'
    3652 = 'drop_nontechnical_process_management_content'
    3672 = 'drop_nontechnical_process_management_content'
    3685 = 'drop_nontechnical_process_management_content'
    3696 = 'drop_nontechnical_process_management_content'
    3715 = 'drop_nontechnical_process_management_content'
    3744 = 'drop_nontechnical_process_management_content'
    3747 = 'drop_nontechnical_process_management_content'
    3749 = 'drop_nontechnical_process_management_content'
    3750 = 'drop_nontechnical_process_management_content'
    3754 = 'drop_nontechnical_process_management_content'
    3761 = 'drop_nontechnical_process_management_content'
    3762 = 'drop_nontechnical_process_management_content'
    3764 = 'drop_nontechnical_process_management_content'
    3765 = 'drop_nontechnical_process_management_content'
    3769 = 'drop_nontechnical_process_management_content'
    3778 = 'drop_nontechnical_process_management_content'
    3782 = 'drop_nontechnical_process_management_content'
    3783 = 'drop_nontechnical_process_management_content'
    3784 = 'drop_nontechnical_process_management_content'
    3785 = 'drop_nontechnical_process_management_content'
    3786 = 'drop_nontechnical_process_management_content'
    3788 = 'drop_nontechnical_process_management_content'
    3789 = 'drop_nontechnical_process_management_content'
    3793 = 'drop_nontechnical_process_management_content'
    3819 = 'drop_nontechnical_document_approval_content'
    3865 = 'drop_nontechnical_document_approval_content'
    3869 = 'drop_nontechnical_document_approval_content'
    3878 = 'drop_nontechnical_document_approval_content'
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
        $reason = 'retained_self_contained_manufacturing_qa'
        $afterMessages = $beforeMessages

        if($deletes.ContainsKey($sourceLine)) {
            $action = 'delete'
            $reason = $deletes[$sourceLine]
            $afterMessages = $null
        } elseif($rewrites.ContainsKey($sourceLine)) {
            $action = 'rewrite'
            $reason = $rewrites[$sourceLine].reason
            $afterMessages = New-Messages $rewrites[$sourceLine].q $rewrites[$sourceLine].a
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
            record_id = ('practical-machining-handbook-{0:D4}' -f $sourceLine)
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

$summaryRows = @()
foreach($entry in ($deletes.GetEnumerator() | Group-Object Value)) {
    $summaryRows += [pscustomobject]@{ action='delete'; reason=$entry.Name; count=$entry.Count }
}
foreach($entry in ($rewrites.GetEnumerator() | Group-Object { $_.Value.reason })) {
    $summaryRows += [pscustomobject]@{ action='rewrite'; reason=$entry.Name; count=$entry.Count }
}
$summaryRows += [pscustomobject]@{ action='keep'; reason='retained_self_contained_manufacturing_qa'; count=($sourceLine - $deletes.Count - $rewrites.Count) }
$summaryRows | Sort-Object action,reason | Export-Csv -LiteralPath $summary -NoTypeInformation -Encoding UTF8

Write-Output ("source_lines={0}; output_lines={1}; rewrites={2}; deletes={3}" -f $sourceLine,$outputLine,$rewrites.Count,$deletes.Count)
Write-Output (Join-Path $Workspace $cleanRel)
Write-Output (Join-Path $Workspace $decRel)
Write-Output (Join-Path $Workspace $sumRel)
