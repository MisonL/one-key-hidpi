# Intel 黑苹果外接显示器 HiDPI 调研

## 范围

本文记录在本仓库为 Intel 黑苹果外接显示器增加“自动生成相近 HiDPI
分辨率”功能的可行性和实现边界，不包含该功能的实现。

## 结论

该功能在 Intel 黑苹果上可行，但应复用本项目已有的 EDID override
机制，而不是使用 `hidpi-scale` 等仅支持 Apple Silicon 的虚拟显示器方案。

实现结果是根据面板原生分辨率生成有限数量的相近 HiDPI 模式，不能承诺
BetterDisplay 式任意百分比的实时缩放。override 发生变更后，macOS 必须重载
显示器配置；保守且可复现的生效方式是重启。

## 代码与事实依据

- 当前脚本通过 `IODisplayEDID` 检测 Intel 外接显示器，并在 `get_edid`
  中取得厂商和产品 ID。
- 脚本为每台显示器写入 override：
  `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vendor>/DisplayProductID-<product>`。
- override 中的 `scale-resolutions` 保存模式列表；现有辅助函数将逻辑 HiDPI
  尺寸编码成 2x framebuffer。
- 手工输入路径 `custom_res` 已接收一组逻辑分辨率并交给 `create_res` 处理，
  因此自动生成器可在完成输入校验后复用同一编码路径。
- BetterDisplay 的公开文档说明 Intel 与 Apple Silicon 都支持任意 HiDPI
  framebuffer；但 Intel 虚拟屏幕的上限由具体机型和 GPU 决定。因此 Intel
  应优先使用原生显示器 override，而不是假设 Apple Silicon 虚拟屏幕可用。

## 本机 Intel 验证

本次调研所用开发机为 Intel 黑苹果：macOS 15.7.7、Intel Core i7-10700、
AMD Radeon RX 580。

- `system_profiler SPDisplaysDataType` 报告两台在线的 DisplayPort 外接屏。
- `ioreg -c IODisplayConnect -l` 为两台屏幕均暴露 `IODisplayEDID`、
  `DisplayVendorID` 和 `DisplayProductID`。
- 运行时存在 `CGVirtualDisplay` Objective-C 类，但这不能证明 Apple Silicon
  的虚拟显示器工作流可在 Intel 上运行。
- 当前 `hidpi-scale` 明确仅支持 Apple Silicon，且通过本机不存在的
  `DCPAVServiceProxy` 查找显示器，不能作为 Intel 实现基础。

## 本机已有 Override

本机已有用户安装的显示器 override。其中一个文件与当前连接的 T24s-20
匹配：`DisplayVendorID-30ae/DisplayProductID-62a5`，且已经包含
`scale-resolutions`。

这是实现时的硬约束：新功能必须保留并合并既有 target plist，不能盲目替换，
也不能在单屏回退时删除整个厂商目录。

## 建议行为

### 输入

1. 读取选中显示器的 EDID，取得面板原生宽度和高度。
2. 验证宽高均为正数、在定义的 framebuffer 上限内，并保持面板宽高比。
3. 让用户选择预设密度档位，首版使用小而固定的集合。

### 初始预设

以面板原生尺寸乘以下列系数，分别向下取整为偶数，生成逻辑“看起来像”尺寸：

| 预设 | 系数 | 目的 |
| --- | ---: | --- |
| 原生 | 1.00 | 保持既有逻辑尺寸 |
| 紧凑 | 0.90 | UI 略大 |
| 均衡 | 0.80 | 中等额外工作区 |
| 宽敞 | 0.75 | 更多工作区 |
| 高密度 | 0.67 | 更小 UI，显式选择 |

初始系数须按显示器类别测试。生成器必须去重、保持宽高比，并拒绝 2x
framebuffer 超出明确安全上限的模式。

### 输出

1. 读取已有的 target override plist。
2. 保留图标元数据和既有 EDID patch 等无关字段。
3. 解析或保留已有 `scale-resolutions`，只追加尚不存在的生成模式。
4. 写入临时 plist，并使用 `plutil -lint` 校验。
5. 原子替换前，对原始 target 文件创建带时间戳的精确备份。
6. 仅在校验后设置 `root:wheel` 所有者和 `0644` 文件权限。
7. 除非后续验证出可靠的显示器重新初始化路径，否则明确提示用户重启。

## 开发前必须处理的安全问题

1. 替换当前宽泛写入路径。`end` 会把临时目录复制到全局 Overrides 目录，
   可能覆盖既有 target plist。
2. 替换当前宽泛回退路径。`disable` 会删除整个
   `DisplayVendorID-<vendor>` 目录，可能删除同厂商其他显示器的 override。
3. 不再对临时内容递归使用 `chmod 777`。
4. 在进行算术或生成 XML 前，校验每一个用户输入或自动生成的宽度和高度。
   输入格式错误必须显式失败，不能静默生成模式。
5. 记录 manifest，包含 target 路径、备份路径、生成模式和源码版本，以便
   回退时仅恢复工具自己修改的内容。
6. 对已有用户 override，必须通过可见的合并和备份决策处理，不能直接覆盖。

## 建议的原子任务

1. 增加只读显示器盘点：Intel EDID、原生分辨率、target override 路径及已有模式。
2. 增加纯 shell 生成器，并用 fixture 覆盖系数取整、去重、非法输入拒绝和
   framebuffer 上限。
3. 增加 plist 合并、备份、校验和精确回退行为。
4. 增加交互菜单项，用于生成相近 HiDPI 预设。
5. 先在非生产显示器验证，再验证重启、睡眠唤醒、拔插和完整回退。

## 许可证边界

上游 `xzhih/one-key-hidpi` 仓库没有 `LICENSE` 文件，GitHub 也报告无许可证。
GitHub fork 不会产生再发布或重新授权权利。本仓库可用于私人调研和本地 patch，
但公开发布衍生版本前，必须取得上游作者授权，或独立重写功能且不复制未授权表达。

## 参考

- 上游项目：https://github.com/xzhih/one-key-hidpi
- BetterDisplay HiDPI 文档：
  https://github.com/waydabber/BetterDisplay/wiki/Fully-scalable-HiDPI-desktop
- Apple Silicon 对照项目：https://github.com/ankithans/hidpi-scale
- BetterDummy OpenSource Edition 源码分支：
  https://github.com/waydabber/BetterDisplay/tree/opensource
