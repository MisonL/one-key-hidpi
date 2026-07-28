# 一键开启 macOS HiDPI

## 说明

[English](README.md) | [中文](README-zh.md)

 此脚本的目的是为中低分辨率的屏幕开启 HiDPI 选项，并且具有原生的 HiDPI 设置，不需要 RDM 软件即可在系统显示器设置中设置

macOS 的 DPI 机制和 Windows 下不一样，比如 1080p 的屏幕在 Windows 下有 125%、150% 这样的缩放选项，而同样的屏幕在 macOS 下，缩放选项里只是单纯的调节分辨率，这就使得在默认分辨率下字体和UI看起来很小，降低分辨率又显得模糊

同时，此脚本也可以通过注入修补后的 EDID 修复闪屏，或者睡眠唤醒后的闪屏问题，当然这个修复因人而异

开机的第二阶段 logo 总是会稍微放大，因为分辨率是仿冒的

设置：

![设置](./img/preferences.jpg)

![设置](./img/hidpi.gif)

## 使用方法

1.远程模式: 在终端输入以下命令回车即可

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xzhih/one-key-hidpi/master/hidpi.sh)"
```

2.本地模式: 下载项目解压,双击 `hidpi.command` 运行

### Intel 安全 HiDPI 菜单

`Intel 安全 HiDPI` 菜单仅在包含 `intel-hidpi.sh` 和
`lib/intel_hidpi_menu.sh` 的完整本地仓库中提供。上面的单文件远程命令会保留
原有菜单项，不会从当前目录加载辅助文件。

本地菜单会先依据所选显示器的 EDID 预览受限模式。应用或回退均要求以 root
身份运行并输入明确确认词。修改 override 后仍需让 macOS 重载显示器配置，通常
需要重启，系统才会显示新模式。

### 只读模式验收

在 macOS 已暴露显示器配置后，应按目标显示器验收，而不能只看主显示器或 plist：

```bash
./intel-hidpi.sh verify-modes --vendor-id <供应商ID> --product-id <产品ID> \
  --native-resolution <宽>x<高>
```

该命令按供应商 ID 与产品 ID 读取目标显示器，并同时比对每个生成候选的逻辑分辨率
和 framebuffer。全部观察到时返回 `0`；只观察到部分时返回 `2`；它不会写入
override、修改分辨率或重载显示服务。实时 CoreGraphics 采集会输出
`capture-source=live-coregraphics`。使用 `--modes-file` 时会输出
`capture-source=offline-file`；这种模式只验证传入的捕获记录，不能证明当前显示器
状态。该文件必须是小于等于 1 MiB 的普通文本捕获记录，符号链接会被拒绝。
每个选项只能提供一次，重复传入会显式失败。

### 平滑 HiDPI 模式

本地 Intel 安全菜单可选择原有的兼容预设模式，或显式选择 `smooth` 平滑模式集。
`smooth` 会从不低于面板原生逻辑尺寸 2/3 的位置到原生尺寸生成保持精确宽高比的 2x HiDPI
模式，最多 41 档。对 1920x1080 面板，这对应从 1280x720 到 1920x1080 的 41 档
模式，步进为 16x9。根据目标面板需要，还可以明确追加 `1920x1079` 的近原生兼容档。

命令行也可使用相同模式集：

```bash
./intel-hidpi.sh preview --native-resolution 1920x1080 --mode-set smooth \
  --include-near-native

./intel-hidpi.sh verify-modes --vendor-id <供应商ID> --product-id <产品ID> \
  --native-resolution 1920x1080 --mode-set smooth --include-near-native
```

`preview`、`apply` 与 `verify-modes` 默认仍使用 `preset`。`--include-near-native`
只能与 `--mode-set smooth` 同时使用。若面板无法在该范围内提供至少两个保持精确宽高比
的候选档位，命令会显式失败，不会静默退化为单一模式。这个基于 EDID override 的模式
生成器并不等同于 BetterDisplay 的 GUI 或实时显示器重配置能力。

将预览结果应用到 override 时，`apply` 必须复用预览所用的 `--mode-set` 与
`--include-near-native` 参数；不同参数会有意生成不同的候选模式集。

![运行](./img/run-zh.jpg)

## 恢复

### 命令恢复

传统菜单的选项 3 中，选择“在此显示器上禁用 HIDPI”只会删除当前选中显示器的
`DisplayProductID-<产品 ID>` override 及其图标附件，并保留同厂商的其他显示器配置。

如果使用的是完整本地仓库中的 `Intel 安全 HiDPI` 菜单，请以 root 身份重新运行
本地脚本，选择 Intel 安全菜单中的 Revert；也可以在仓库目录执行：

```bash
sudo ./intel-hidpi.sh revert --vendor-id <供应商ID> --product-id <产品ID> --confirm
```

该命令只会回退本工具为该显示器记录的 manifest 所对应的 override；manifest 缺失、
目标已被外部修改或 override 根不匹配时会显式停止，不会删除其他显示器配置。

### 恢复模式

如果使用此脚本后，开机无法进入系统，请到 macos 恢复模式，打开终端

这里有两种方式进行关闭，建议选第一种

1. 快捷恢复
    

```bash
ls /Volumes/
```

你会看到你的系统盘

```bash
cd /Volumes/你的系统盘/Users/

ls
```

你可以看到所有用户的家目录

```bash
cd 你的用户名

./.hidpi-disable
```

请直接运行 `.hidpi-disable`，不要通过符号链接或硬链接运行。它必须位于目标系统卷的
`Users/<用户名>/` 下；可从任意当前目录运行，但只会处理脚本所在卷中当前选中显示器
的单个 override 和图标附件。若把独立副本复制或移动到另一个合法的
`<卷>/Users/<用户名>/` 布局，它会处理那个卷；除非这是预期行为，否则不要复制或移动。
它没有“恢复全部设置”选项。

2. 手动恢复

不要递归删除整个 `Library/Displays/Contents/Resources/Overrides` 目录。该目录可能包含
其他显示器或系统配置。若 Intel 安全回退无法执行，请保留 manifest 和目标文件，并先
根据上面的显示器 vendor/product ID 确认需要恢复的单个 `DisplayProductID-<产品 ID>` 文件。

## 从以下得到启发

https://www.tonymacx86.com/threads/solved-black-screen-with-gtx-1070-lg-ultrafine-5k-sierra-10-12-4.219872/page-4#post-1644805

https://github.com/syscl/Enable-HiDPI-OSX
