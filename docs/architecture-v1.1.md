# V1.1：独立 App 与自动拖放接收窗口

## 用户目标与方案

V1.1 保留已经验证可出纸的用户态打印引擎，将界面改为普通 macOS App：
Dock 图标和打印工作台、独立设置窗口、拖文件时自动出现的接收浮窗。
文件投递后在工作台预览、选择页码和份数，再发送打印。

选用 Swift + AppKit，预览使用系统 PDFKit / ImageIO，光栅转换继续使用
CoreGraphics 和已有 brlaser 核心。全局拖放、窗口焦点、菜单、网卡绑定均有
原生 API，可直接复用当前工程，无须引入新的运行时。

| 方案 | 对本项目的意义 |
| --- | --- |
| Swift + AppKit | 原生窗口、Dock、NSPanel、拖放与事件监视直接可用；复用现有代码。采用。 |
| SwiftUI + AppKit | 可声明式构建表单，但全局拖放、非激活浮窗与预览仍需 AppKit 互操作。暂不增加一套 UI 层。 |
| Electron | QQ 的实际方案。仍用 Node 原生扩展调用 AppKit 处理关键拖放功能；本项目不需要浏览器运行时。 |
| Flutter | 向日葵的实际方案。关键拖放仍在原生插件中实现；当前只要求 macOS，暂无重写引擎或增加跨平台运行时的收益。 |

## QQ：实际安装样本的 REA 观察

目标：QQ 7.0.2，bundle com.tencent.qq。

- QQNT.framework 标识为 Electron 40.0.0；主入口经字节码加载器加载，
  不能把可读的 bootstrap 当作全部界面源码。
- wrapper.node 的 FileDragManagerMacNSPasteboardChangeCountPolling
  使用 200 ms 定时器，注册全局与本地鼠标监视，事件掩码为 0x46。
- 原生回调检查拖拽 pasteboard 的 changeCount 与文件 URL 类型，
  并以 pressedMouseButtons 补充释放检测。
- 接收层是 NSPanel + NSView；浮窗不能成为 key/main window，
  通过 draggingEntered 和 performDragOperation 接收本地文件。
- 关键指令位置：0x1879de8、0x1879f6c、0x187b9e8、0x187bc00。
- REA 原生证据：
  ev_5b565750de31b59f2609c981d5321b0be1bd7049f0b6de5bd7343ed20e3e34a7。

这是原生机制的静态证据，不代表已经恢复 QQ 字节码中的可见布局、位置、
开关条件或完整交互。未读取聊天记录或向联系人发送文件。

## 向日葵：实际安装样本的 REA 观察

目标：AweSun / 向日葵 16.6.0，bundle com.oray.sunlogin.macclient。

- 实际技术栈为 Flutter + 原生插件。
- desktop_drop.FileDrag 使用全局左键按下、拖动、释放监视器，以及
  拖拽 pasteboard 的 changeCount；发送拖动与释放状态给 Flutter。
- 内部状态为 DOWN=0、RELEASE=1、DRAG_WITH_FILE=2；
  Flutter 事件值为内部值减一，不应直接按内部枚举解码。
- DropTarget 使用标准 NSDraggingDestination 回调，投递阶段限制本地 URL，
  并支持 NSFilePromiseReceiver。
- 文件接收窗口对应 FileFlashTransferWindow，不能混同于 AI floating_ball。
- 关键原生证据：
  ev_4abc28b06e87ac19e1874fab5de65e24e5667d757af49abf5d2421c71a28c780。

没有恢复 Flutter AOT 中完整的窗口控制流，位置与全部显隐时序仍属未知。
未连接远程设备、读取用户会话或进行文件传输。

## 独立实现的交互

1. 只监视鼠标左键手势，不监视键盘。
2. 结合新手势、拖拽 pasteboard 的类型与 changeCount，区分文件拖动、
   普通点击和文本拖动；200 ms 轮询用于补充释放与缺失事件。
3. 在拖动开始时显示非激活浮窗，保留原 App 的焦点与拖动会话；
   多屏采用 AppKit 逻辑坐标，不自行换算 Retina 像素。
4. 用户进入接收区时高亮，离开时还原。释放但未投递时延迟关闭，
   留出 AppKit 投递回调的处理时间。
5. 实际文件从 NSDraggingInfo.draggingPasteboard 读取。
   全局检测只读取类型和 changeCount，不读取通用剪贴板或保存拖动路径。
6. 投递后激活工作台，展示本地文档预览和待处理列表。
   文件承诺写入本机私有临时目录，校验路径后才加入列表。
7. 连接参数、指定发送网卡、自动浮窗开关位于设置；沿用原有本机偏好键，
   不把私人网络参数写入工程或发布包。
8. 打印批次使用参数快照，后来加入的文件留待下一批；
   发送失败停止批次，避免自动重试导致重复页面。

系统文档也说明，全局和本地事件监视的覆盖范围不同；
接收阶段应使用拖拽会话提供的 pasteboard，不能假设所有 App
都使用全局标准拖拽 pasteboard。因此必须进行真实跨 App 拖放验证。

## 一并研究的其他功能

| 功能 | V1.1 处理 |
| --- | --- |
| PDF / 图片预览 | 使用系统 PDFKit / ImageIO，只在本机查看。预览原文，打印输出仍遵循打印设置。 |
| 多文件列表 | 允许一次接收多个文件；每个文件保留自己的页码、份数和旋转选择。 |
| 批次可靠性 | 区分待处理、转换、发送、已发送和需检查；不把已发送称为已出纸。 |
| 文件承诺 | 接收照片/其他 App 提供的延迟文件，限制接收目录并防止路径越界。 |
| 取消、结束与开关 | 普通文本拖动不唤窗；松开关闭浮窗；关闭自动浮窗时移除事件监视和定时器。 |
| Office 文档 | 研究范围内；当前不做自动转换，避免未经验证的分页和新增外部软件依赖。请先导出 PDF。 |
| 登录、远控、聊天、云同步 | 属于参考产品的其他用途，本工具没有实现或触发这些操作。 |

## 授权与验证边界

本项目独立编写界面与拖放状态机，不复制或分发参考 App 的专有代码、图片或二进制。
原始分析记录只保存在被 Git 忽略的本机 evidence 目录。
打印编码核心的 GPL 授权与对应源码继续按 THIRD_PARTY.md 保留。

构建与离线检查不能代替实际拖动、焦点和窗口测试。
需要分别验证 Finder 文件、跨 App 投递、文件承诺、释放关闭、关闭开关以及设置保存。

## 原生 API 资料

- [Apple：Monitoring Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)
- [Apple：Dragging Destinations](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Tasks/DraggingDest.html)
- [Apple：NSPanel](https://developer.apple.com/documentation/appkit/nspanel)
- [Apple：PDFView](https://developer.apple.com/documentation/pdfkit/pdfview)
