# Brother Drop Print

原生 macOS 独立打印 App。V1.1 增加 Dock 图标、文档预览、文件列表和独立设置，
并在拖动本地文件时，于菜单栏图标下方显示 QQ 式接收浮窗。将 PDF、PNG 或 JPEG 投递进去，
在浮窗里调整份数和页码后直接打印，或打开工作台预览。

A native macOS app with a drag-triggered floating receiver and direct Brother raster printing over TCP.
Experimental interoperability project; not affiliated with Brother.

## 功能

- 普通 App 窗口和 Dock 图标；保留菜单栏快捷入口。
- 文件拖动开始时，菜单栏图标下方出现提示胶囊；拖近后展开为接收卡片，
  松手后原地变为打印面板（缩略图、份数、页码、打印、预览）。全程不抢焦点。
- 拖动途中即可识别不支持的文件类型，接收卡片变红并提示先导出 PDF。
- 全局检测只检查鼠标手势及拖放类型，不监视键盘或读取通用剪贴板。
- 文件预览与多文件列表；支持串行批次，后来加入的文件留待下一批。
- IP、端口、网卡绑定及自动浮窗开关移入独立设置。
- PDF 多页、PNG/JPEG；图片的 EXIF 方向和透明背景会被处理。
- 手动填写 IPv4 地址与端口，不依赖设备搜索或同一 Wi-Fi。
- 可将发送连接绑定到指定有线网卡或 Wi-Fi；指定网卡失效时不自动改走其他网卡。
- 页码范围、1–99 份、旋转及适应纸张；多份按整份文档顺序发送。
- 首版使用 A4、600 dpi、黑白、单面配置。
- 支持本地文件 URL 和其他 App 提供的文件承诺；原始文件不会被移动。
- 内置校准页；文件在本机转换，只发送到指定打印地址。
- 不安装系统级打印驱动，不需要管理员权限。

## 当前状态

这是实验性实现。已在 macOS 26 / Apple silicon 配合 DCP-1618W 确认基础出纸。
V1.1 的编译和离线检查已通过。2026-10-29 已在本机验证：从 Finder 拖动文件会唤出浮窗、
不抢焦点，松手后关闭；投递到浮窗后进入打印面板。
其他 App 的文件承诺、多显示器及全屏空间仍待逐项验收。
编码核心来自维护中的 brlaser，初始几何参数沿用其 DCP-1600 / DCP-1610W 配置。
尚未穷尽校准所有文档、密集图片和打印设置，不能推断所有 Brother 型号都兼容。
请先用“准备测试页”检查实际出纸、边框、方向、灰阶与 100 mm 标尺。

离线检查覆盖拖放状态、设置保存、接收路径、PDF/PNG 读取、页码验证、
栅格方向与补齐、完整打印流、文件不被覆盖及本地 TCP 字节传输和批次顺序。
TCP 发送完成只表示数据已交出，
不表示打印机已经完成出纸；传输失败时不会自动重试，以免重复打印。

## 使用

需要 macOS 14 或更新版本，以及 Xcode Command Line Tools。

    bash scripts/build.sh
    bash scripts/test.sh

打开生成的 build/Brother Drop Print.app。
将文件拖到自动出现的接收浮窗、工作台、菜单栏图标或 Dock 图标，也可点击“添加文件”。
在“设置…”中填写打印机的实际 IPv4 地址和打印端口（通常为 9100）。
地址和端口只保存在本机偏好设置，不写入源码。
双网卡或 VPN 环境中，可在“发送网卡”选择对应有线接口；这些选择也只保存在本机。
关闭工作台不会退出 App，因此仍可接收后续拖动；不需要时可在设置关闭自动浮窗，
或从 App 菜单退出。

如果打印机位于另一台路由器后面，地址应填写已配置打印端口转发的入口地址。
单独转发网页端口不能提供打印连接。此应用不需要搜索广播，也不会修改路由器配置。

RAW/9100 通常没有传输加密或登录认证。请在受控网络中使用，并按需限制转发来源。

## 设计与互操作证据

使用 REA 对官方安装器携带的 ADKCore.dll 进行静态检查，观察到设备搜索与
打印发送是独立路径：搜索使用 UDP 161 / SNMP，打印连接使用 TCP 9100。
这解释了“端口可连接，但安装器搜不到设备”的情况。

其 BrPDLPclBuilder / BrMode1030Compression 路径包含 PJL 作业包装、
PCL 1030 光栅模式以及替换/重复行压缩。这些位格式与 brlaser 对应，
但官方库和 brlaser 的分块大小存在差异，仍需要目标机器实测。

本项目没有复制或分发官方程序集、安装包、反编译代码、账号或网络配置。
应用使用系统 CoreGraphics 渲染页面，复用 brlaser 的用户态编码核心。
相关上游版本及授权说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 开发与测试

源码分为 Sources 下的菜单栏界面、渲染和 TCP 传输，以及 native 下的
PBM 到打印流适配器。vendor/brlaser 中的编码核心保持上游原样。
无需安装 CUPS 开发库、Ghostscript 或旧版 Brother 驱动。

构建只针对当前机器架构。GitHub Actions 执行相同的构建及离线检查，
并保存开发构建 ZIP。开发构建只有本地 ad-hoc 签名，没有 Developer ID 签名或 Apple 公证。
本地研究资料、打印数据及构建输出均不纳入 Git。

V1.1 的 QQ / 向日葵机制研究、技术栈比较和已知边界见
[架构与研究记录](docs/architecture-v1.1.md)。
用 REA 整理的 Brother 打印参数、状态查询及 QQ 浮窗参考见
[V1.2 打印参数规格](docs/brother-print-spec.md)。
本机 UI 验证辅助 App 可用以下命令生成；它仅拖动合成测试 PDF，不会打印或连接远程服务：

    bash scripts/build-ui-fixture.sh

## 许可证

GPL-2.0-or-later，详见 [LICENSE](LICENSE)。
Brother 名称和商标归其权利人所有。
