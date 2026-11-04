# 历史核验记录

> 本页原为 README「验证与兼容边界」一节（2026-11-04 移入），按日期保留 2026-10 的分日回归、本地交付与真机复验证据，属于升级版本前的历史核验，不是当前发行附件的最终校验。当前版本（v0.4.0）的发布验证见 [docs/releases/](releases/)。

以下测试、0.2.0/build 3 本地 DMG 与固定身份安装记录属于升级版本前的历史核验；旧 [v0.3.0](releases/v0.3.0.md)、[v0.2.0](releases/v0.2.0.md) 发行说明和已发布附件保持。

## 本地交付记录

历史本地交付（2026-10-14）：用户确认此次 Obsidian 问题复验通过后，已生成包含修复的本地 [润物-0.2.0.dmg](../dist/润物-0.2.0.dmg)，版本仍为 `0.2.0`、构建号 `3`。DMG 沿用标准 ad-hoc 签名、未公证；构建、镜像校验、只读挂载内容检查与严格签名通过，内含应用、Applications 链接及 LICENSE，文件 SHA256 为 `f67de84f65c45c279cddea5dbfe9853ec9fd67874eb5588c8137a6cdc545c992`。本机安装随后沿用原 Runwu Local 固定身份重建，构建/安装二进制 SHA256 均为 `0126fe866dc54dddbe329189e150fb49384a9ec4d31d1e9daead824c80be345d`，严格签名通过、指定要求保持；PID `42653` 的启动日志确认 `trusted=true enabled=true` 和辅助功能监控启动，`debugLogEnabled` 保持 `1`。两种产物的签名政策不同，各自与对应输入核对摘要；本轮未推送或发布远程附件，历史 0.1.0 DMG 保持。完整交付与限制见 [行尾映射增量设计](designs/obsidian-line-end-mapping.md)。

## 分日回归记录

2026-10-13 行尾增量修复后全量共 336 项，其中 1 项联网探测默认跳过，0 项失败。新增 7 项映射回归覆盖行尾后六个换行、文末尾随空行、前移一字、emoji/组合字符的 UTF-16 边界、文末哨兵、锚尾去除字符的旧策略及首个正确候选倒退时拒绝；均通过宿主夹具到监控快照验证，实义行尾再经生产取句器确认当前句。旧实现先跑出 5 项失败、13 个断言失败，修复后 20 项映射测试与 19 项取句测试均通过。用户 2026-10-14 回复「测试了，没问题，收尾打包安装吧」，确认此次 Obsidian 行尾问题真机复验通过；该反馈与这些合成测试均不代表全部宿主或全部输入、布局场景已验证。

2026-10-13 当次源码全量共 317 项，其中 1 项联网探测默认跳过，0 项失败；本轮修复 Chromium contenteditable 宿主（实测 Obsidian）宿主偏移与 `AXValue` 两套坐标系导致的取句偏上问题：先读宿主锚窗把偏移映射回 `AXValue` 文本再取句，映射配方向守卫（候选不得倒退）与光标后一位字符甄别，校验失败或读取出错时不翻（宁可不翻，不翻错行），宿主不提供该读取能力时沿用报告偏移；首版在真实宿主因空白表示法差异常不出卡（宿主用零宽空格+制表符表示块边界、`AXValue` 用换行，逐字锚窗找不到即不翻），已改为对空白形态容忍的映射——逐字失败时按去空白归一化匹配并还原原文索引（归一化锚不足 8 个非空白单元仍不匹配），甄别遇空白跳过；新增回归用例 testBlockBoundaryValueMapsToTheCaretLine、testUnmatchableAnchorEmitsNoSnapshot、testCandidateBeforeHostOffsetIsRejected、testPostCaretCharacterMismatchIsRejected、testPostCaretReadUnavailableStillMaps、testNativeHostAnchorHitsItsOwnOffset、testAnchorWindowLengthBoundAtDocumentStart、testUnsupportedAnchorReadKeepsReportedOffset、testFailedAnchorReadEmitsNoSnapshot、testCanonicallyEquivalentAnchorUsesFoundLength、testUnreadableValueWithReadableAnchorStillRecoversLastGoodText、testWhitespaceVariantAnchorStillMaps、testWhitespaceOnlyMatchIsRejected、testPostCaretWhitespaceSkipsCorroboration、testValueWhitespaceAtMappedIndexSkipsCorroboration。

2026-10-13 当次源码全量共 302 项，其中 1 项联网探测默认跳过，0 项失败；本轮修复 Chromium contenteditable 宿主（实测 Obsidian）把整个编辑器报成一个输入框（89% 屏高）时跟随卡贴屏幕顶缘、飘出焦点窗口的问题：高度超过所在屏 0.6 倍的输入框矩形不再作为跟随避让障碍、卡片贴光标行落下，恰为 0.6 倍及以下仍按既有规则避让（由 0.6 门槛边界用例 testFollowingCardKeepsAFieldAtExactlyTheHeightLimit 锁定）；新增回归用例 testFollowingCardHugsTheCaretWhenTheFieldFillsTheScreen；≤0.6 屏高输入框行为不变由终审 17 夹具×多高度扫描单测核验，输出与基线逐字一致。

2026-10-12 当次源码全量共 300 项，其中 1 项联网探测默认跳过，0 项失败；本轮修复有道适配器被 code50 拒绝的问题：按当前网页协议先取匿名会话 cookie、补全签名握手与翻译请求字段，cookie 被拒时重取会话并重试一次；新增会话复用、失效重取、重试上限与无 cookie 握手失败四组夹具。release 构建与 `codesign --verify --deep --strict 润物.app` 通过（Runwu Local 身份）。

2026-10-10 当次源码全量共 296 项，其中 1 项联网探测默认跳过，0 项失败；本轮新增浮窗避让输入框的布局单测与协调器回归（含宿主把光标框报在输入行之外的复现场景、翻面死区、固定卡整组让开与回位、空隙不相交不挪位、无干净位置回退、输入框矩形祖先兜底、面板高度不短于实测文本、诊断探针几何格式）。

2026-10-09 当次源码全量共 278 项，其中 1 项联网探测默认跳过，0 项失败；本轮包含设置窗口的原生生命周期回归与独立应用 policy 实测、服务菜单及重译的隔离原生交互、输入资格的合成红绿回归，以及加载/失败长卡的原生窗口缩放预算回归；不下载苹果语言包。release 构建和严格签名验证通过，留下本地 ad-hoc 签名的 `润物.app`。

## 测试覆盖与联网探测

自动化测试覆盖输入会话、组合提交、真实句子范围、多屏坐标、浮窗跟随与固定/钉住行为、两种输入来源的路由和取消、配置隔离、明确只读/禁用/后代焦点、资格失效后的读取与替换保护，以及三家网页 HTTP 夹具。SwiftUI host 回归使用真实 NSHostingView 和生产配置 generation 包装，但不下载语言包或伪造苹果原生翻译 session。

2026-10-12 14:35:14 复测「你好，世界。」（中文 → 英文）：Google 返回 `Hello World.`，Bing、有道返回 `Hello, world.`，三家成功；另以固定短句 `Use wisely.` 抽查英译中方向，有道返回「明智地使用。」。此前的 2026-10-08 18:01:19 首次探测结果相同。默认测试跳过联网探测；可明确启用以下测试，它只向三家发送该固定非敏感短句：

```sh
RUNWU_WEB_LIVE_PROBE=1 swift test --filter WebTranslationTests.testLiveAdaptersFixedSentenceProbe
```

## 兼容边界

辅助功能及光标定位依赖宿主实现，不能保证所有应用兼容。真实宿主输入反馈、苹果原生 session attach/语言包和用户自定义模型端点仍需实际使用验证；定位受限时可使用固定模式或剪贴板翻译。实现及维护决策见 [光标与服务设计](designs/caret-translation.md)、[浮窗服务菜单设计](designs/overlay-service.md) 和 [设置窗口与 Dock 设计](designs/dock-visibility.md)。
