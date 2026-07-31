# macOS Intel HiDPI

[项目说明](README.md) | [补充中文说明](README-zh.md)

本 fork 提供一条 Intel 安全 HiDPI 工作流。它读取已连接显示器的 EDID，生成数量受限的
2x HiDPI 候选模式，并且只有在明确确认后才会把候选模式合并到显示器 override 中。
它不是 BetterDisplay 连续实时缩放或图形界面的替代品。

## 前提条件

- 必须使用完整的本地 checkout。仓库根目录必须包含 `hidpi.sh`、`intel-hidpi.sh` 和完整的
  `lib/` 目录。
- 显示器必须能通过 `ioreg` 暴露有效 EDID。
- 不要下载单个脚本后直接运行。安全入口发现 checkout 不完整时会显式失败，不会去其他位置
  查找辅助文件。
- 安全入口和直接运行的 Intel 工具会拒绝其辅助文件及 `lib/` 目录的符号链接（symbolic links），因此不会从
  其他位置加载依赖。

当存在多条有效显示器记录时，入口会输出 vendor ID、product ID 和原生分辨率，并要求明确
选择。EDID、标识和原生分辨率始终保存在同一条记录中。不同 EDID 如果映射到同一个 override
目标，会被拒绝，因为该目标无法安全选择。

## 只读盘点

下面的命令只检查 EDID 派生元数据和已有 override 模式，不会写入文件：

```bash
./intel-hidpi.sh inventory
```

命令会报告有效显示器记录、原生分辨率和匹配的 override 路径；没有有效 EDID 时会显式失败。

## 交互入口

可以先预览生成的模式并取消，整个过程不会修改 override：

```bash
./hidpi.sh
```

本地菜单提供 `preset` 兼容模式和更密集的 `smooth` 模式集。`smooth` 使用显示器原生宽高比，
从原生尺寸的三分之二开始生成到原生尺寸，最多 41 个候选。适合选定面板时，可以明确加入
近原生兼容模式。若面板的整数几何尺寸在该范围内无法提供至少两个精确宽高比候选，`smooth`
会显式拒绝；此时应使用 `preset`。

如需生成与 BetterDisplay 取证布局兼容的集合，`smooth` 还可以为每个 HiDPI 候选加入两个
普通分辨率 payload：逻辑分辨率和对应的 2x framebuffer 分辨率。该选项用于兼容已观察到的
BetterDisplay override 布局，不表示实现了连续实时缩放。

普通 payload 的宽高按无符号 32 位字段编码。生成器会显式拒绝非正数、前导零、超过
`4294967295` 的值，以及逻辑和 framebuffer payload 相同的候选。

应用已预览的选择时，`apply` 必须传入相同的 `--mode-set`、`--include-near-native` 和
`--include-similar-resolutions` 选项；选择不同的参数会有意生成不同的候选集合。

<!-- 兼容性原文索引：When applying a previewed selection, pass the same；symbolic links。 -->

应用或回退都要求以 root 身份启动，并输入精确的 `APPLY` 或 `REVERT` 确认词：

```bash
sudo ./hidpi.sh
```

菜单不会自行提权，也不会回退到已移除的直接生成、远程下载或宽泛清理路径。工具不会重载
显示服务、重初始化显示子系统、重启或热插拔显示器。静态验证不能证明 macOS 在运行时已经
接受并暴露每一个候选模式。

## 命令行

只生成候选模式，不写入 override：

```bash
./intel-hidpi.sh preview --native-resolution 1920x1080 --mode-set smooth \
  --include-near-native --include-similar-resolutions
```

以只读方式核验选定 override 的 payload 集合：

```bash
./intel-hidpi.sh verify-override --vendor-id <vendor-id> --product-id <product-id> \
  --native-resolution <width>x<height> --mode-set smooth --include-near-native \
  --include-similar-resolutions
```

`verify-override` 检查目标 plist 中直接位于 `scale-resolutions` 数组内的唯一 data payload
集合。只有集合严格相等时才返回 `0`；重复的直接 data 条目会单独报告，存在缺失或额外
payload 时返回 `2`。

以另一条只读命令核验 CoreGraphics 实际暴露给选定显示器的模式：

```bash
./intel-hidpi.sh verify-modes --vendor-id <vendor-id> --product-id <product-id> \
  --native-resolution <width>x<height> --mode-set smooth --include-near-native \
  --include-similar-resolutions
```

`verify-modes` 同时比较逻辑尺寸和 framebuffer 尺寸。普通相似分辨率记录有意使用相同的
逻辑尺寸和 framebuffer 尺寸。完整结果返回 `0`，生成模式有缺失时返回 `2`。使用
`--modes-file` 时只校验离线捕获记录；该结果不能证明当前显示器状态。

两种核验回答的问题不同。`verify-override` 通过只能证明 override payload 配置正确，不能
证明 macOS 接受了每个 payload 并将其作为运行时模式；`verify-modes` 通过只能证明枚举到了
相应的模式对，不能证明这些模式来自该 override 文件。

## 精确回退

只回退本工具此前为指定 vendor 和 product ID 记录过的 override：

```bash
sudo ./intel-hidpi.sh revert --vendor-id <vendor-id> --product-id <product-id> --confirm
```

命令会在恢复或删除之前核验 manifest、目标内容和 override 根。记录缺失或目标已被工具外部
修改时会停止。

## 限制

EDID override 的行为取决于显示器、图形驱动和 macOS。确定性的预览和 fixture 验证不能证明
某个特定 Intel 黑苹果配置会在运行时暴露所有候选模式。

## 参考来源

https://www.tonymacx86.com/threads/solved-black-screen-with-gtx-1070-lg-ultrafine-5k-sierra-10-12-4.219872/page-4#post-1644805

https://github.com/syscl/Enable-HiDPI-OSX
