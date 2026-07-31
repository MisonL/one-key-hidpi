# macOS Intel HiDPI

[English](README.md) | [中文](README-zh.md)

本 fork 只支持一条 Intel 安全 HiDPI 工作流。它读取已连接显示器的 EDID，生成受限的
2x HiDPI 候选模式，并且只会在明确确认后把候选模式合并到目标显示器的 override。
它不是 BetterDisplay 的连续缩放或图形界面替代品。

## 前提条件

- 必须使用完整本地仓库。根目录需要包含 `hidpi.sh`、`intel-hidpi.sh` 和完整的
  `lib/` 目录。
- 显示器需要能通过 `ioreg` 提供有效 EDID。
- 不支持下载单个脚本后直接运行。安全入口发现依赖不完整时会显式失败，不会到其他
  目录寻找辅助文件。
- 安全入口和直接运行的 Intel 工具都拒绝辅助文件和 `lib/` 目录的符号链接，不会从其他
  位置加载依赖。

当检测到多条有效显示器记录时，入口会列出 vendor ID、product ID 和原生分辨率，并要求
明确选择。EDID、标识和原生分辨率始终来自同一条记录。不同 EDID 映射到同一个 override
目标时会被拒绝，因为该目标无法安全地区分。

## 只读盘点

下面的命令只读取 EDID 元数据和已有 override 模式，不会写入文件：

```bash
./intel-hidpi.sh inventory
```

它会输出有效显示器记录、原生分辨率和匹配的 override 路径；没有有效 EDID 时会显式失败。

## 交互入口

可以先预览生成模式并取消，整个过程不会修改 override：

```bash
./hidpi.sh
```

本地菜单提供 `preset` 兼容模式和更密集的 `smooth` 模式集。`smooth` 按显示器原生宽高比，
从不低于原生尺寸三分之二的位置生成到原生尺寸，最多 41 档。确有需要时可以明确加入
近原生兼容模式。
在 `smooth` 模式下，还可以显式加入与 BetterDisplay override 布局兼容的相似分辨率：
每个 HiDPI 候选额外加入逻辑分辨率和对应 2x framebuffer 分辨率各一个普通 payload。
该选项用于兼容已观察到的 BetterDisplay override 布局，不代表实现了连续实时缩放。
将预览结果应用到 override 时，`apply` 必须复用预览所用的 `--mode-set`、
`--include-near-native` 和 `--include-similar-resolutions` 参数；不同选择会有意生成不同的候选模式集。

应用或回退都要求以 root 身份启动，并输入精确的 `APPLY` 或 `REVERT` 确认词：

```bash
sudo ./hidpi.sh
```

菜单不会自行提权，也不会回退到已移除的直接生成、远程下载或宽泛清理路径。

## 命令行

仅生成候选模式，不写入 override：

```bash
./intel-hidpi.sh preview --native-resolution 1920x1080 --mode-set smooth \
  --include-near-native --include-similar-resolutions
```

可以先只读核验目标 override 的 payload 集合：

```bash
./intel-hidpi.sh verify-override --vendor-id <供应商ID> --product-id <产品ID> \
  --native-resolution <宽>x<高> --mode-set smooth --include-near-native \
  --include-similar-resolutions
```

`verify-override` 只检查目标 plist 中直接位于 `scale-resolutions` 数组内的唯一 data
payload 集合。只有集合严格相等时才返回 `0`；它会单独报告重复的直接 data 条目，并在存在缺失
或额外 payload 时返回 `2`。

再单独只读核验 CoreGraphics 实际暴露给目标显示器的模式：

```bash
./intel-hidpi.sh verify-modes --vendor-id <供应商ID> --product-id <产品ID> \
  --native-resolution <宽>x<高> --mode-set smooth --include-near-native \
  --include-similar-resolutions
```

`verify-modes` 会同时比对逻辑分辨率和 framebuffer。普通相似分辨率记录有意使用相同的逻辑
分辨率和 framebuffer。完整命中返回 `0`，部分缺失返回 `2`。使用 `--modes-file` 时只校验离线
捕获记录，不能证明当前显示器状态。

两种核验回答的问题不同：`verify-override` 通过只能证明 override payload 配置正确，不能证明
macOS 会把每个 payload 接受并暴露为运行时模式；`verify-modes` 通过只能证明枚举到相应的模式对，
不能证明它们来自当前 override 文件。

## 精确回退

仅回退本工具为指定 vendor 和 product ID 记录过的 override：

```bash
sudo ./intel-hidpi.sh revert --vendor-id <供应商ID> --product-id <产品ID> --confirm
```

命令会先核验 manifest、目标内容和 override 根，再恢复或移除文件。记录缺失或目标被工具外
修改时会显式停止。

## 限制

EDID override 是否生效取决于显示器、显卡驱动和 macOS。确定性的预览和 fixture 验证不能证明
某个 Intel 黑苹果配置一定会在运行时暴露全部候选模式。

## 参考

https://www.tonymacx86.com/threads/solved-black-screen-with-gtx-1070-lg-ultrafine-5k-sierra-10-12-4.219872/page-4#post-1644805

https://github.com/syscl/Enable-HiDPI-OSX
