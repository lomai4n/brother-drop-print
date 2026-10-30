# V1.2：Brother 打印参数规格与 QQ 式接收窗口

本文是 V1.2 实现前的规格整理，不含代码改动。
第 1–5 节来自 Brother 官方安装器的静态分析，第 7 节来自用户录制的 QQ 拖放视频。
标为“待核”的条目必须在 DCP-1618W 上打印验证后才能实现。

## 来源与范围

- 目标：`Start Here Mac.app/Contents/MonoBundle/ADKCore.dll`，
  SHA-256 `e7fe05dcaeca5670d7ebb8c8a83374ec2c86688e2bd758dd7fb7435bac5a4a4f`。
- 工具：REA 6.8.0 `inspect-managed-members`（只读 PE/CLI 元数据、CIL 锚点和 ldstr 字面量，不加载目标代码）。
  证据：`ev_5eab5bb2a8e58f77d857c077647d323e93377fe06512099cf3366e6a8ff04df5`。
  `switch` 跳转表由方法体文件偏移处的 CIL 字节直接解码。
- 原始输出只保存在被 Git 忽略的 `evidence/v1.2`。
- 这是 Brother 跨平台 ADK 的 PCL 路径（安装器与移动端共用），
  不是完整的 macOS CUPS 驱动；本机没有安装该驱动。
  因此省墨、浓度、介质类型等选项在 ADK 中不可调，只在 brlaser 路径中出现。
- 枚举数值按 C# 声明顺序从 0 推定，Constant 表尚未读取。**待核**。

## 1. 作业头：BrMode1030PCL.jobStart（0x06000cf6）

```
ESC %-12345X @PJL\n
@PJL SET RESOLUTION={res}\n
@PJL SET OUTBIN={outbin}\n
[@PJL SET AVOIDMAILBOXFULL=ON\n]        ← useStandardTrayWhenFull 时
@PJL SET ECONOMODE=OFF\n                ← 固定值
@PJL ENTER LANGUAGE=PCL\n
ESC&u{res}D  ESC*t{res}R  ESC&n8WdRegular
ESC&l{H}H    ESC&l{S}S    ESC&l{X}X    ESC&l{A}A
```

每页开始 `ESC*b1030M`（pageStart 0x06000cf8），
作业结束 `ESC%-12345X@PJL EOJ \nESC%-12345X`（jobEnd 0x06000cf7）。

| 参数 | 来源字段 | 取值 |
| --- | --- | --- |
| res | quality（getOutputResolution 0x06000cfb） | Draft → 300，其余 → 600 |
| S 双面 | duplex | Simplex 0、FlipOnLongEdge 1、FlipOnShortEdge 2 |
| X 份数 | copyCount、collate | 逐份 ON → 1（主机重复发送整份文档）；OFF → copyCount（打印机逐页重复） |
| A 纸张 | paperSize（BrMediaSize） | ISO_A4 26、ISO_A5 25、NA_Letter 2、NA_Legal 3、JIS_B5 100；其他回落到 26 |
| H 进纸 | inputTray | Auto 7、MPTray 4、Tray1 1、Tray2 5、Tray3 8、Tray4 9、Tray5 10、Default 7 |
| OUTBIN | outputTray | Auto AUTO、Tray1 UPPER、Mailbox1–5 OPTIONALOUTPUTBIN1–5、Mx_Sorter ALLSORTER、Mx_Stacker ALLSTACKER |

当前 App 的“多份按整份文档顺序发送”与 ADK 的逐份行为一致。

## 2. 与当前 brlaser 输出的差异

| 项目 | brlaser（已出纸验证） | ADK |
| --- | --- | --- |
| 前导 | 128 个 NUL + `@PJL JOB NAME` | 无 |
| 纸张 | `@PJL SET PAPER = A4` | PCL `ESC&l26A` |
| 进纸 | `@PJL SET SOURCETRAY` | PCL `ESC&l#H` |
| 介质、浓度 | `MEDIATYPE`、`DENSITY`、`DEVBIASADJUST` | 不设置 |
| 省墨 | `ECONOMODE` 可选 | 固定 OFF |
| 1200 dpi | `RAS1200MODE` | 不支持，最高 600 |
| 双面 | `ESC&l2S` 或 `0S` | `0S` / `1S` / `2S` |
| 其他 | `ESC E` 复位、`PAGEPROTECT`、`ORIENTATION` | `ESC&n8WdRegular`、`OUTBIN` |
| 压缩 | 1030 替换/重复行 | 同一格式，分块大小不同 |

结论：继续以已经出纸的 brlaser 为基础，不切换到 ADK 的头部。
从 ADK 借用的是参数语义：纸张代码表、300 dpi 草稿、逐份规则。
任何头部改动都要先打测试页对照。

## 3. 渲染

- **缩放**（MakePrintImageParameters 0x06000719）：
  NoScaling 按“输出分辨率 / 原图最大分辨率”换算，保持物理尺寸；
  NoScalingAtPrintableAreaCenter 同上并居中；
  CustomScaling 再乘用户的 ScaleX / ScaleY；
  其余三种（适应、等比适应、等比填充）交给成像库。
- **灰阶**（HalftonePixMap 0x060006f6）：用有序抖动矩阵 `Matrix300Graphics` 做半色调，
  以 32 像素为宽度分组处理。当前 App 用 4×4 Bayer 矩阵。
  矩阵内容还没读出；**待核**是否值得替换。
- **多合一**由主机侧成像完成，不是打印机命令：
  BrPrintLayout 1/2/4/9/16 合 1，四种排列方向（先右后下、先下后右、先左后下、先下后左）。

## 4. 参数全集（BrPrintParameters）

| 字段 | 选项 | DCP-1618W 计划 |
| --- | --- | --- |
| paperSize | A3–A6、B4–B6、Letter、Legal、Executive、Statement、Folio、JIS B5 等 34 项 | A4、A5、Letter、Legal、JIS B5（逐项测试） |
| mediaType | Plain、ThinPaper、RecycledPaper 等 8 项 | 走 brlaser `MEDIATYPE`，**待核**可用值 |
| quality | Draft、Document、Photographic、Normal、Fine、Eco | 草稿 300 / 标准 600 / 省墨 |
| scale | 6 种，见第 3 节 | 实际大小、适应纸张、自定义百分比 |
| layout、layoutDirection | 1/2/4/9/16 合 1，4 种方向 | 实现 |
| collate、copyCount | 逐份开/关 | 实现 |
| duplex | 单面、长边、短边 | 机器不支持自动双面，改做手动双面 |
| orientation、pageOrientation | 纵向、横向、自动旋转 | 实现自动旋转 |
| margin | Normal、Borderless、NoMargin | 激光机只支持 Normal |
| inputTray、outputTray | 见第 1 节 | 只有一个纸盒，固定 AUTO |

## 5. 状态查询

PJL 命令（BrPJLClient / BrPJLParser）：

- `@PJL INFO CONFIG`：读取 PAPERS、LANGUAGES
- `@PJL INFO DXCONFIG`
- `@PJL INFO BRFIRMWARE`
- `@PJL INFO BRMODELINFO`：读取 ENGINETYPE、DISPCOLOR、NUMCOLOR、COLORTURN

响应按正则 `(?<feature>.+)=(?<value>.+)` 和 `(?<feature>.+)\s+\[(?<count>\d+)\s+(?<type>.+)\]` 解析。

SNMP OID（UDP 161）：

| 用途 | OID |
| --- | --- |
| 设备状态 hrDeviceStatus | 1.3.6.1.2.1.25.3.2.1.5.1 |
| 面板显示文字 | 1.3.6.1.2.1.43.16.5.1.2.1.1 |
| Brother 状态码 | 1.3.6.1.4.1.2435.2.3.9.4.2.1.5.5.6 |
| 型号 | 1.3.6.1.2.1.25.3.2.1.3.1 |
| 支持纸张 | 1.3.6.1.4.1.2435.2.3.9.4.2.1.5.1.2.71.12.1.2 |
| 双面能力 | 1.3.6.1.2.1.43.13.4.1.9.1 |

限制：

- 打印机在另一台路由器后面、只转发了 9100 时，SNMP 不可达。
  状态功能必须可选，失败时不影响打印。
- PJL 查询走哪个端口、能否在 9100 上双向回读，都还**待核**。
- Brother 状态码表还没恢复。先显示面板文字，再逐步补充状态码含义。

## 5a. 已实现（V1.2 第 2 步）

- 编码器参数：`brother-encoder output.prn copies paper dpi economode density media page.pbm …`。
  纸张、介质和浓度的取值沿用 brlaser 上游的 PJL 名称；分辨率只开放 300 和 600。
- 栅格尺寸 =（纸张尺寸 − 左右 16 pt、上下 24 pt）× dpi / 72，四舍五入。
  A4 600 dpi 仍是 4825 × 6817，输出与 V1.1 逐字节相同。
- 界面：工作台提供纸张、纸张类型、质量、浓度；浮窗提供纸张和质量。
  质量合并为标准 600 dpi、草稿 300 dpi、省墨 600 dpi 三档。
- 未采用 ADK 的 PCL 纸张代码 `ESC&l#A`，继续用 brlaser 已验证的 `@PJL SET PAPER`。

## 5b. 已实现（V1.2 第 3 步：状态与出纸确认）

- 设置中的“状态查询”：不查询 / 仅 SNMP / 自动（默认：SNMP 不通时经打印端口查询 PJL，并记住上次回应的方式）。
  SNMP 端口可改（默认 UDP 161，团体名 public，v2c）。
- 读取的 OID：hrDeviceStatus、hrPrinterStatus、hrPrinterDetectedErrorState（缺纸、卡纸、机盖打开、碳粉等 15 种）、
  面板文字 prtConsoleDisplayBufferText、页数计数器 prtMarkerLifeCount、碳粉余量 prtMarkerSuppliesLevel / MaxCapacity。
  这些是标准 Printer MIB；第 5 节的 Brother 私有状态码表尚未恢复，暂不使用。
- PJL 只发送 `@PJL INFO STATUS` 和 `@PJL INFO PAGECOUNT`，解析 CODE / DISPLAY / ONLINE / PAGECOUNT；
  发送作业期间不做 PJL 查询，避免与作业争用打印端口。
- 出纸确认：发送前读页数计数器作为基线，发送后每 2 秒用同一来源（SNMP 或 PJL）再读，按发送顺序把文件标为“已出纸”；
  超时（45 秒 + 每页 8 秒）则提示到打印机旁检查。同一打印机上别人的作业也会推进计数器。
- 发送的打印数据与第 2 步完全相同；状态查询失败只显示“状态未知”，不影响打印。
- 本机测试用回环 SNMP 代理和 PJL 服务器验证。
- 2026-10-29 实机（DCP-1618W，固件 `8C5-G02:Ver.D`，经 9100 端口访问）：
  - SNMP v1 / v2c 均无回应；80、443、515、631 端口不通，只有 9100 可达。
  - PJL 在 9100 上可回读：`INFO ID`、`INFO STATUS`（`CODE=10001`、`DISPLAY="准备就绪"`、`ONLINE=TRUE`，
    面板文字为 UTF-8 中文；休眠时显示“休眠”）、`INFO PAGECOUNT`（`PAGECOUNT=5215`）。
  - `INFO USTATUS` 显示 DEVICE / JOB / PAGE 主动回报默认关闭；本实现不开启，改用页数计数器轮询。
  - **待核**：打印一份后计数器是否按页递增、作业处理中 PJL 查询的回应时机。

## 6. 实机验证清单（DCP-1618W）

1. 测试页基线：保持当前头部，确认出纸与 V1.1 一致。
2. 纸张：A5、Letter 各打一页，量 100 mm 标尺和边框。
3. 草稿 300 dpi 与省墨：对比灰阶条。
4. 份数：逐份 2 份、不逐份 2 份，检查出纸顺序。
5. 多合一：2 合 1、4 合 1，检查方向和边距。
6. 手动双面：先出奇数页，提示翻面后出偶数页，检查正反面方向。
7. 状态：在同一网段和端口转发两种环境下，分别试 PJL 与 SNMP 查询。

## 7. QQ 拖放窗口参考（用户录屏，QQ 7.0.2）

原始帧保存在 `evidence/v1.2/qq-reference`（不纳入 Git）。

| 状态 | QQ 的表现 |
| --- | --- |
| 拖动开始 | 菜单栏 QQ 图标正下方出现深色胶囊提示条，文案轮播；不跟随指针，不抢焦点 |
| 靠近或进入胶囊 | 原地向下展开为卡片（约 300×350 pt）：图标 + “松手添加文件” + ··· + ×；虚线边框投放区；插画中文件缩略图落入文件夹；两行主文案、一行灰色说明 |
| 离开卡片 | 收回成胶囊 |
| 在别处松手 | 胶囊消失 |
| 在卡片中松手 | 卡片原地切换为结果面板：+ 继续添加、清空、文件大图标、可改名、“1 项 · 大小 \| 设置”、有效期选项行、“分享至”一排动作按钮、底部使用说明；停留到点 × 为止 |

V1.1 的检测机制已经与 QQ 一致；差别在可见形态：
V1.1 在屏幕另一侧弹出一张大卡片，QQ 是“胶囊 → 卡片 → 结果面板”三段。

本项目对应设计：

- **胶囊**：锚定在本 App 菜单栏图标下方；图标不可见时，放在指针所在屏幕顶部。
  文案轮播“文件拖到这，直接用 Brother 打印”和“PDF、图片拖到这儿，即可打印”。
- **卡片**：标题“松手添加文件”；插画用打印机加纸张的 SF Symbols。
  主文案“文件拖到这 / 发送到 {打印机名}”；
  说明“支持 PDF、PNG、JPEG · 本机转换，不经云端”。
  不支持的类型让投放区变灰，提示先导出 PDF；判断只读拖拽类型。
- **结果面板**（标题“Brother 闪印”）：
  - 顶部：+ 继续添加、清空
  - 首页缩略图、文件名、“N 页 · 大小 \| 设置”
  - 选项行：份数、页码、纸张、质量（第 4 节）
  - 动作行：打印（主按钮）、预览（打开工作台）、草稿预设、更多
  - 底部：打印机状态点（第 5 节）
- **多文件**：结果面板显示列表和合计；仍按 V1.1 的批次规则发送。
- **实现**：同一个非激活 `NSPanel` 承载三种内容，`NSAnimationContext` 做原地变形。
  胶囊自身就是拖放目标：draggingEntered 时展开，draggingExited 后延迟收回。
  结果面板需要输入份数和页码，允许成为 key window，但仍是 nonactivating，不激活 App。
- **焦点**：全程不激活 App；只有点“预览”才激活并打开工作台。
