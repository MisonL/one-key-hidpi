# Intel 黑苹果外接显示器 HiDPI 调研

## 范围

本文先记录在本仓库为 Intel 黑苹果外接显示器增加“自动生成相近 HiDPI
分辨率”功能的可行性和实现边界，随后补充当前 fork 的实现状态和验证证据。

## 结论

该功能在 Intel 黑苹果上可行，应复用本项目已有的 EDID override
机制，而不是使用 `hidpi-scale` 等仅支持 Apple Silicon 的虚拟显示器方案。

当前实现根据面板原生分辨率生成有限数量的相近 HiDPI 模式，并通过显式的
`smooth`、近原生和相似分辨率开关复现 BetterDisplay 取证到的 override 布局。
它不能承诺 BetterDisplay 式任意百分比的实时缩放。工具不会自动重载显示服务、
重初始化显示子系统、重启或热插拔；真实运行时模式是否被 macOS 接受仍需单独验收。

## 代码与事实依据

- `hidpi.sh` 现在是完整本地仓库的安全入口；`intel-hidpi.sh` 提供盘点、
  预览、只读核验、隔离 apply 和精确 revert 子命令。
- 入口从 `ioreg` 读取有效 EDID，并将 vendor ID、product ID、原生分辨率和
  override 目标绑定在同一条记录中。
- `smooth` 按原生宽高比生成从约三分之二到原生尺寸的密集 2x HiDPI 候选，
  最多 41 档；近原生模式和 BetterDisplay 兼容的普通 payload 均需显式启用。
- override 合并、manifest、备份、持久身份、锁和回退均由 `lib/` 中的安全
  存储模块处理，隔离测试不会写入默认系统目录。
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

## 已实现行为

### 输入

1. 读取选中显示器的 EDID，取得面板原生宽度和高度。
2. 验证宽高均为正数、在定义的 framebuffer 上限内，并保持面板宽高比。
3. 让用户选择预设密度档位，首版使用小而固定的集合。

### 已验证的预设生成规则

首版实现的 `preview` 命令采用与 `hidpi-scale` 的公开计算方式一致的固定档位：
将面板物理宽高分别乘以系数、四舍五入后向下取偶数，再编码为 2x HiDPI
framebuffer。这里的逻辑“看起来像”尺寸是相对面板物理尺寸而言；例如
3840x2160 面板会生成 1920x1080 至 3840x2160 的逻辑档位。

| 预设 | 系数 | 3840x2160 示例 |
| --- | ---: | --- |
| compact | 1/2 | 1920x1080 |
| balanced | 3/5 | 2304x1296 |
| spacious | 2/3 | 2560x1440 |
| dense | 3/4 | 2880x1620 |
| native | 1/1 | 3840x2160 |

每个逻辑档位使用 16 字节的 HiDPI `scale-resolutions` payload，其前 8 字节为
2x framebuffer 宽高。生成器去重，并默认拒绝任一轴超过 8192 像素的
framebuffer；可通过只读 `preview` 的 `--framebuffer-limit` 参数使用更低的
验收上限。超限时不输出部分候选列表。

`smooth` 使用精确宽高比步进，从不低于原生尺寸三分之二的位置生成到原生尺寸，
1920x1080 会生成 41 个候选；近原生选项额外加入 1920x1079。相似分辨率选项会
为每个候选加入逻辑尺寸和 2x framebuffer 尺寸各一个普通 8-byte payload。
普通 payload 的宽高限制为正整数和 `4294967295` 范围；同一迭代的 logical 和
framebuffer payload 相同或输入超界时，生成器会在输出前显式失败。

### 输出

1. 读取已有的 target override plist。
2. 保留图标元数据和既有 EDID patch 等无关字段。
3. 解析或保留已有 `scale-resolutions`，只追加尚不存在的生成模式。
4. 写入临时 plist，并使用 `plutil -lint` 校验。
5. 原子替换前，对原始 target 文件创建带时间戳的精确备份。
6. 仅在校验后设置 `root:wheel` 所有者和 `0644` 文件权限。
7. 工具不自动重载显示服务、重初始化显示子系统、重启或热插拔显示器；
   真实运行时接受情况保持为未验证边界。

## 历史风险清单

以下保留原始调研阶段识别的风险；当前实现状态和对应测试以 TASKS.md
及 docs/reviews 下的 IH 审查记录为准。

1. 原始风险是宽泛写入路径可能覆盖既有 target plist；当前由隔离临时文件、
   校验和原子替换路径处理。
2. 原始风险是宽泛回退路径可能删除同厂商其他显示器；当前回退按目标和 manifest
   精确处理。
3. 原始风险是对临时内容递归使用 `chmod 777`；当前实现不使用该路径。
4. 原始风险是算术或 XML 生成前缺少输入校验；当前已覆盖 EDID、分辨率、payload
   和 framebuffer 边界，并对错误显式失败。
5. 原始风险是缺少精确回退依据；当前 manifest v5 记录目标、模式、哈希和持久身份。
6. 原始风险是覆盖已有用户 override；当前使用结构化合并并保留无关字段。

## 实现任务状态

- IH-001 至 IH-019：Intel 盘点、安全生成、合并、回退、入口和 smooth 模式已完成。
- IH-020：BetterDisplay 相似分辨率兼容集已完成，1920x1080 集合为 42 个 HiDPI
  payload 加 84 个普通 payload，并与只读取证逐项一致。
- IH-021 至 IH-025：审查同步、fixture 清理、ID 边界、离线捕获和低 GCD 诊断已完成。
- IH-026：payload 32 位边界、identical 防御和局部 pipeline pipefail 已完成。
- IH-027：双语 README、调研和审查口径同步在当前任务中收口。

## 原始原子任务记录（已归档）

1. 只读显示器盘点：已由 IH-001、IH-007 和安全入口完成。
2. 纯 shell 生成器及 fixture 边界：已由 IH-002、IH-018、IH-025 和 IH-026 完成。
3. plist 合并、备份、校验和精确回退：已由 IH-003、IH-006、IH-011 至 IH-016 完成。
4. 交互菜单和相近 HiDPI 预设：已由 IH-004、IH-018 至 IH-020 完成。
5. 真实显示器重载、重启、睡眠、唤醒和热插拔：按永久约束不执行，仍是未验证边界。

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
