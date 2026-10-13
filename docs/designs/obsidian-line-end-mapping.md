# Obsidian 行尾映射边界修复

## 一句话方案

空白归一化匹配的锚窗以实义字符结束时，将光标还原到最后匹配 UTF-16 单元之后，避免跨过行尾后的空白块。

## 背景与目标

承接 `docs/designs/caret-translation.md` 的两段式映射与取句防护，以及 `docs/designs/obsidian-input-diagnostics.md` 的无正文诊断。原设计范围包含整体光标跟随，本文件只记录行尾增量。

2026-10-13 用户在 Obsidian 的测试内容行尾提交停顿未显示，前移一字后显示。日志两次 composing=false、防抖到期、光标框有效；275→359 取句为空，274→352 取句四字并翻译。日志不含正文，具体现场字符未直接读取。

未经修改的生产代码在合成块边界差异与行尾后六个换行时复现行尾空句、前移一字成功。目标是保留文字行尾插入边界，并覆盖连续空行和文末。

## 做法

宿主锚窗 → 逐字匹配 → 必要时去空白匹配 → 还原 AXValue 插入边界 → 原有取句与翻译。

归一化表记录保留单元的原文位置，命中结束的下一项代表下一个保留字符，可能隔着多个换行。锚尾为实义单元时，用最后匹配单元的原文位置加一，恢复其右边界。锚尾为空白或零宽标记时，沿用既有下一保留字符策略。匹配优先级、最小锚、搜索下界、方向守卫、字符甄别与读取预算保持。

## 备选与取舍

让取句跨空行回找上一句会掩盖错位，甚至翻译上一段，不采用。布局调整不能修复未发出的请求。本次只修可确定的实义字符边界；尾随空白的块归属保留既有策略。

## 明确不做

不改变取句、翻译、去重、防抖、布局、AX 预算或读取次数，不实现原 T5，不记录正文。真机输入和浮窗观察由用户进行。

## 实际交付

`Sources/Pico/CaretTracking.swift` 只调整 `mappedIndexIgnoringWhitespace` 的命中结束还原：锚尾实义单元取 `originals[hitEnd - 1] + 1`，锚尾去除单元取原有 `originals[hitEnd]`。匹配入口、归一化集合、最小长度、首个匹配和搜索下界、方向守卫、字符甄别、AX 读取及取句接口保持。

`Tests/PicoTests/CaretOffsetMappingTests.swift` 新增 7 项回归：

- `testWhitespaceVariantLineEndBeforeBlankLinesMapsToCaretLine`、`testWhitespaceVariantDocumentEndWithTrailingBlankLinesMapsToCaretLine`：经 AXFixture → AccessibilityMonitor 快照 → SentenceExtractor 断言行尾 UTF-16 插入边界和当前句范围。
- `testWhitespaceVariantMiddleStillMapsToCaretLine`、`testWhitespaceVariantUnicodeLineEndMapsToUTF16Boundary`：前移一字只变化一个 UTF-16 单元，emoji（含肤色和 ZWJ）及组合字符结尾仍落在完整字素之后。
- `testWhitespaceVariantDocumentEndWithoutTrailingBlankLinesUsesSentinel`、`testWhitespaceVariantTrailingAnchorWhitespaceKeepsExistingBoundary`、`testWhitespaceVariantContentEndRejectsCandidateBeforeHostOffset`：覆盖文末哨兵、五种去除锚尾的旧规则、首个正确候选倒退时拒绝且不改选后续匹配。关键路径断言仍仅进行锚窗和后一位字符两次宿主文本查询。

2026-10-13 修前映射测试退出 1：20 项中 5 项失败、13 个断言失败；两项指定行尾回归将 54 错映射为 60，取句为空。修后映射测试 20 项、取句测试 19 项均通过，全量 `swift test` 336 项、跳过 1 项固定短句联网探测、0 失败。`README.md` 已补行为变化与真机限制。

无代码范围或实现规则偏离。T2 已按源码提交 `6360604b8eba91dd2c291502efc5bf6637d2b1cf` 完成 Release 构建和安装至 `/Applications/润物.app`：构建退出 0，构建及安装包的 `codesign --verify --deep --strict` 均退出 0，新旧指定要求与原 Runwu Local 证书一致。替换前已备份旧应用至 `.build/obsidian-line-end-mapping/previous-installed-20261013T113443Z.app`。构建与安装二进制的 SHA256 均为 `f34574a1362b2a09145ee88f16ede7e5c4120f7e7c89e5716f2fe081cc48b2b1`。

首次安装核验记录（2026-10-13 19:39）显示新进程 PID `58638`，`debugLogEnabled` 保持 `1`；后台启动核验在 10 秒内没有取得启动日志，退出 1。只读进程采样显示主线程停于既有的 `SettingsStore.restoreAPIKeysFromKeychain → KeychainStore.string → SecItemCopyMatching → SecurityServer.decrypt` 路径，当时状态为 `waiting_keychain_before_startup`。当时尚无 `trusted=true` 启动证据，已请求用户解锁并手动处理可能的系统钥匙串提示，未自动操作钥匙串、权限或用户窗口。

用户明确回复已处理后，2026-10-13 20:04 最终核验取得 `2026-10-13T12:02:49.878Z startup trusted=true enabled=true` 和 `2026-10-13T12:02:49.909Z accessibility monitor started` 日志；PID `58638` 仍运行，`debugLogEnabled` 仍为 `1`。构建/安装 SHA256、严格签名和原指定要求再次核对通过，状态更新为 `trusted_startup_and_monitor_confirmed`，T2 运行核验通过，无需再次安装或重启。初次钥匙串等待记录保留；Obsidian 真机输入和浮窗显示仍待用户复验。

## 已知限制

合成回归不能代替用户真机复验；本次未读取现场正文或操作 Obsidian 窗口。短锚、匹配失败、方向不满足仍按旧规则；锚尾去除字符沿用旧边界策略，不宣称解决空白行光标归属。原 T5 光标框丢失后的布局调整未实施，取句、翻译、去重和防抖行为保持。

## 验收标准

- 行尾后有多个空行的回归修前失败、修后通过，映射保留行尾且取句为当前句。
- 文末尾随空行、前移一字、多 UTF-16 单元结尾及既有防护通过回归，全量无回归。
- Release 和严格签名校验成功，新旧指定要求一致，安装/构建摘要相同，新进程正常启动。

## 决策摘要

| ID | 决策及依据 |
|----|------------|
| D-01 | 用户授权修行尾边界并补空行回归，以修前红灯、修后绿灯证明改正。 |
| D-02 | 用户授权通过后重建安装；沿用旧签名权限，只后台重启润物。 |
| D-03 | 锚尾实义单元用最后命中单元后边界，锚尾去除字符沿用旧策略；只改可确定插入位置，既有防护保持。 |
| D-04 | README 记录行为变化，本增量设计记录交付与限制；原整体设计范围更大，相关机制以本文件修正为准。 |

## 接口与数据形状

| 接口 / 数据 | 实际契约 |
|-------------|----------|
| `CaretOffsetMapping.mappedIndex(anchor: String, hostOffset: Int, in text: NSString) -> Int?` | 签名不变；先逐字匹配，找不到才归一化。返回 AXValue UTF-16 插入边界，匹配或防护失败为 nil。 |
| `mappedIndexIgnoringWhitespace(anchor: String, hostOffset: Int, in text: NSString) -> Int?` | 归一化锚至少 8 个保留 UTF-16 单元；从原搜索下界对应的位置取首个匹配，`hitEnd = found.location + found.length` 使用实际命中长度。锚尾实义时取 `originals[hitEnd - 1] + 1`，锚尾去除字符时取 `originals[hitEnd]`；仍要求候选不早于 `hostOffset`。 |
| `whitespaceNormalized(_ text: NSString) -> (normalized: NSString, originals: [Int])` | `originals[i]` 是第 i 个保留 UTF-16 单元在原文的位置，末项为原文长度哨兵，数组比归一化串长 1。归一化集合保持系统空白/换行、U+200B、U+FEFF。 |
| `TextSnapshot.selectedRange` | `AccessibilityMonitor` 仍以映射结果重建 `NSRange(location: mapped, length: reported.length)`，光标后一位字符甄别不变；实义锚尾不再跨过随后的空白块。 |
| `SentenceExtractor` / `AXFieldReader` | 接口与调用保持，未增加 AX 查询或正文日志。取句从修正的 UTF-16 边界继续按原有规则执行。 |
