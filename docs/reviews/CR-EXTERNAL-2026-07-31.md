# Claude 与 OMP 外部复核记录

日期: 2026-07-31
仓库: /Volumes/Work/code/one-key-hidpi
代码基线: 9b4d9ab96ed3c0b269a77117e277a9e7c04f130e
复核方式: 两个 CLI 的只读窄范围审查

## 后续实现收口

本文件以下章节保留基于 `9b4d9ab` 的历史复核事实。随后在业务提交
`4e6bbc7` 中已落实历史复核提出的两项防御性建议：

- 相似分辨率生成器直接拒绝同一迭代中 logical 和 framebuffer payload 相同的输入，
  并在统一输出前失败，避免泄漏重复模式行。
- 普通 payload 的宽高限制为正整数和 `0xffffffff` 范围，超界输入返回稳定错误。

当前实现和回归证据见 `docs/reviews/IH-026-2026-07-31.md`；历史章节中“本轮不修改
业务 .sh”仅描述原始复核轮次，不代表当前代码状态。

## 复核边界

两个 CLI 均被明确限制为只读，未执行 sudo、apply、revert、显示服务操作、系统重载、重启、睡眠、唤醒或热插拔。有效复核集中在以下文件:

- `lib/intel_hidpi_similar_resolutions.sh`
- `lib/intel_hidpi_mode_configuration.sh`
- `tests/test_intel_hidpi_smooth_modes.sh`

本记录不把外部模型的推断或空输出当作通过证据；只记录有明确正文和退出状态的结果。

## Claude 复核

- CLI 版本: `2.1.220`
- 有效窄审查退出码: `0`
- 复核结论: 未发现当前输入路径可触发的缺陷。
- Claude 将宽高正整数校验、输入格式正则和 smooth 配置约束列为已有防御；同时指出其复核没有覆盖 `data_payload_list_has_value` 的实现、主脚本上游生成、整数溢出和系统级 base64 行为。
- 较早的完整输出还提到两个防御性边界: 同一迭代内 logical/framebuffer payload 未直接互比，以及宽高超过 `0xffffffff` 时缺少上界校验。这两项是原始复核时的理论风险，现已由 `4e6bbc7` 和 IH-026 收口。

Claude 曾出现 API 500 重试，但最终窄审查正常完成；此前无正文的会话不计为审查结论。

## OMP 复核

- CLI 版本: `17.1.8`
- 模型: `newapi-anthropic/claude-sonnet-4-6`
- 有效复核会话: `73274`
- 原始 JSONL: `/private/tmp/one-key-hidpi-omp-final.wC3Rbs/omp.jsonl`
- 退出码: `0`
- 复核结论: 未确认高或中风险的当前可触发问题。

OMP 原始复核唯一明确提出的缺口是同一迭代内没有直接断言 `logical_payload != framebuffer_payload`。该防御建议现已由 IH-026 实施；当前 `intel-hidpi.sh` 生成路径仍固定使用 `framebuffer = logical * 2`。

随后一次 OMP 调用长时间没有正文，最终以退出码 `130` 终止；该调用不作为审查通过或失败证据。

## 汇总结论

两个有效审查结果一致支持以下结论:

1. 当前 smooth + near-native + similar 的公开生成路径没有被外部复核确认出可触发的高或中风险缺陷。
2. logical/framebuffer 同迭代互比缺口是低风险防御项，已由 IH-026 实施，不影响已验证的 1920x1080 BetterDisplay payload 集合一致性。
3. 宽高 32 位上界缺口是理论防御项，已由 IH-026 实施；当前显示器尺寸远低于该边界。
4. “本轮不修改业务 .sh 或 .swift、不改变 TASKS.md 状态”仅适用于原始复核轮次。

## 未覆盖边界

- `data_payload_list_has_value` 的独立实现及其精确匹配语义。
- 完整 `intel-hidpi.sh` 的 apply/revert、plist 合并、manifest、持久身份、锁和竞态路径。
- macOS CoreDisplay/IOKit 在真实 Intel 黑苹果上实际接受并暴露全部模式的行为。
- 真实显示器写入、显示服务重载、重启、睡眠/唤醒和热插拔验收。

以上边界已有本仓库的本地 fixture、静态检查或远程 BetterDisplay 只读对照记录，但不由本次 Claude/OMP 窄审查单独证明。
