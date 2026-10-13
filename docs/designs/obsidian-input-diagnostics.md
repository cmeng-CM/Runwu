# Obsidian 输入链路诊断

| 元信息 | 内容 |
|---|---|
| 状态 | 诊断构建已安装，待用户真机复现 |
| 最后更新日期 | 2026-10-13 |
| 关联来源 | [光标跟随翻译](caret-translation.md)；本机 13:17 诊断报告 |

> 背景与目标、明确不做说明范围；接口与数据形状供维护诊断查考；实际交付与已知限制记录可依赖的结论。
诊断始终只记录元数据，行为修复另行分析与确认。

## 一句话方案

在既有输入采样、防抖与取句分支记录固定原因和状态，让“已读文本却无翻译请求”的阻断可定位，不改变功能判定。

## 背景与目标

承接 caret-translation.md 的会话、组合保护、防抖、偏移映射与本机日志契约。用户确认中文已提交且停顿超过 1 秒仍无卡片；2026-10-13 13:17 报告含 64 次 Obsidian 快照，部分光标正常，却无对应取句/请求。现有日志不能区分组合状态误判、后续采样取消防抖、取句为空。

本次目标是为下一次复现提供分支证据，不宣告修复。独立探针没有 AX 权限，因此使用已有权限的润物采样。

## 做法

在现有状态转移和提前返回处记固定原因，快照记组合状态、选区与 UTF-16 长度，用标识对照各阶段。防抖区分排队、待执行取消、到期、空取句与去重。连续同类采样失败仅记状态转移，恢复后再次失败重新记录。

只使用已有读取结果，不增加 AX 调用，不调整时序。新增诊断标记不参与翻译条件，沿用文件开关、权限、内存环与报告。

## 备选与取舍

独立探针需要额外 AX 授权，且看不到内部取消原因；应用本身拥有权限和状态，因此在应用补诊断。每次采样全记会挤掉内存环，采用失败状态转移记录。

## 明确不做

不修映射、组合判断或布局，不实现旧工作流 T5，不改变日志开关/权限，不新增网络发送，不操作宿主窗口。实际根因由安装后的用户复现确定。

## 实际交付

- `Sources/Pico/Input.swift` 补充快照组合状态、UTF-16 长度、报告/最终选区，防抖排队/到期/真实取消，取句为空/语言不匹配/句子去重，以及采样失效/恢复和会话重置事件。
- `Sources/Pico/Diagnostics.swift` 增加封闭的 `InputDiagnosticReason` 与元数据格式器；继续使用原 `DiagnosticLog` 内存环、文件开关、上限与 0600 权限。
- 新增 `InputPipelineDiagnosticTests` 7 项，`CaretTrackingTests` 新增 3 项并补充既有重入回归断言：通过真实 monitor → coordinator → debounce 路径验证组合取消、未知组合取消、恢复后再失败、到期空取句与去重；检查正文/锚窗/标签/密钥/译文哨兵不进入内存环、文件和导出报告。
- README 补充诊断事件的阅读方法。未改变采样间隔、防抖默认值、AX 调用与预算、功能 guard 的求值顺序、回调、快照或布局语义。
- 全量 `swift test` 327 项、0 失败、1 项既有联网测试跳过；独立任务审查双 PASS，47 项相关测试复跑通过。
- 2026-10-13 14:27 已使用既有 Runwu Local 身份构建并安装到 `/Applications/润物.app`，严格签名验证通过，指定要求与旧安装一致，构建/安装可执行文件 SHA-256 一致；后台重启后的启动日志确认 `trusted=true enabled=true`，调试开关仍为 `1`。安装证据保存于 `.workflow/obsidian-input-diagnostics/reports/build-install.md`。
- 用户真机复现尚未完成，旧 caret-offset-mapping T5 仍未执行。没有据此宣告真机故障修复。

## 已知限制

宿主报告的组合状态需与用户操作对照，不能单凭 true 判断用户还未上屏。内存环重启清零，文件按既有上限滚动。本轮测试证明诊断和隐私边界，不证明真机故障已修。

失效日志按同一应用中的原因转移记录，不按会话 token 变化重复记录：旧行为仍可在每次失败时重置会话，日志不能用来计数全部重置次数。真正得到可信采样才清除失败状态；失败导致的焦点丢失、重获焦点不能冒充恢复。重入回调中已被新采样替代的外层读取不覆盖新采样的诊断状态。同值 `anchor` 几何也独立去重，锚点回调仍按原逻辑发布。

`geometry_unavailable` 表示既有 `reader.geometry` 返回 nil，可能包含编辑资格或读取预算失效；不新增读取细分它的内部失败。`focus_unavailable` 同样不推断宿主拒绝的具体原因。`composingReadable=false` 时 `composing=false` 只是格式占位，不代表已经提交。`utf16Length` 描述本次快照文本，强制读取/组合下的既有空文本兜底仍可能为 0，不能当作宿主文档总长度。

## 验收标准

- 区分组合抑制、会话重置、真实防抖取消/到期、空取句。
- 私有哨兵不进入内存环、文件或报告；重复失败不逐采样刷屏，恢复后的失败可见。
- 现有输入、组合、映射、防抖、预算测试全绿，独立审查无功能变化。
- app 严格签名验证通过，沿用旧指定要求，安装/构建相同且正常启动。

## 决策摘要

| ID | 决策 | 来源 | 理由与边界 |
|---|---|---|---|
| D-01 | 仅补组合/取消/取句诊断，保持行为 | 用户 | 当前证据在请求前中断，尚未授权行为修复 |
| D-02 | 仅固定原因、状态、长度、偏移与标识 | 用户 | 不含正文和密钥的现有契约 |
| D-03 | 不增加 AX 读取，重复失败按状态转移记录 | agent | 保持预算、时序及内存环证据 |
| D-04 | 审查验证后签名重建安装，用户复现 | 用户 | 沿用润物权限，不操作宿主窗口 |
| D-05 | 按整次采样的最终原因与净会话变化记失效 | agent | 重复失效会重置并重获焦点；保持真实取消事件，同时不以失败引起的焦点变化冒充恢复。日志不用于统计所有内部重置次数 |
| D-06 | 同值 anchor 几何独立去重 | agent | 保留原事件名与锚点回调，避免失效清除 lastAnchor 后相同坐标刷屏；跨会话相同坐标可合并，用 session/reset/snapshot 关联 |
| D-07 | 重入时仅最新读取更新诊断状态 | agent | 已被新采样替代的外层读取不能覆盖恢复状态；诊断代次不参与原功能 guard，不另记被替代读取的失败 |
| D-08 | 几何与焦点失效保持粗分类 | agent | 不增加 AX 查询细分内部资格、权限或预算错误；沿用既有 nil 结果，后续分析不得把粗原因误当为具体宿主错误 |

## 接口与数据形状

沿用 `DiagnosticLog.write(_:)`，不改变 `onSnapshot`、`onAnchorChanged`、`onFocusChanged` 与 `onSentence` 回调签名或 `TextSnapshot`。新增 `InputDebouncer.submit(_:session:action:)` 用既有会话关联事件；`cancel(reason:)`、`InputCoordinator.reset(reason:)` 的默认原因是 `reset`，原无参调用仍有效。

| 事件 | 字段与含义 |
|---|---|
| `snapshot captured` | `bundle`、`pid`、`session`；`composingReadable`、`composing`；`utf16Length`；`reportedStart/Length` 为宿主报告选区，`mappedStart/Length` 为最终快照选区；`forced`、`changed`。只在既有 changed/force 路径记录，成功的未变化轮询不新增快照日志 |
| `snapshot received`（保留旧事件） | 保留 `bundle`、`length`（Swift 字符数），追加 `pid`、`session`、`composing`、`utf16Length`、`selectedStart/Length`（最终快照选区） |
| `input sample blocked` / `input sample recovered` | `reason`、`bundle`、`pid`、`session`；失败时若已有几何/文本结果，再附组合可读性、UTF-16 长度和报告/映射选区。恢复事件的 reason 是此前失败原因 |
| `input session reset` | `reason`、`bundle`、`pid`、`session`、`previousSession`。记录一次读取前后会话的变化；应用变化优先用 `application_changed`，同次下游失败另见 blocked 事件。停止监控时记录 `monitor_stopped`，其 session 是停止前身份，不附 previousSession |
| `input coordinator reset` | `reason`、`pid`、`session`（清除前身份）。无会话时不重复记录；原回调仍可触发 reset |
| `input suppressed` | 固定 `reason` 与 `bundle`、`pid`、`session`；连续相同抑制不重复，正常输入后可再次记录 |
| `debounce queued` / `debounce elapsed` | 排队/真正到期执行前记录原 `bundle`、`pid`、`session`；queued 另记 `delayMilliseconds`。到期先清除诊断 pending 标记，随后才进入原 action |
| `debounce cancelled` | 固定 `reason` 与原排队任务的 `bundle`、`pid`、`session`。仅诊断 pending 标记存在时记录，保留原 Task 的取消操作；已到期的 Task 引用不产生伪取消 |
| `sentence skipped` | 固定 `reason` 与 `bundle`、`pid`、`session`；`extraction_empty` 可附 `utf16Length` 和 `selectedStart`，`sentence_deduplicated` 附 `sentenceStart` 和 `sentenceUTF16Length` |

所有新增选区与长度均用 UTF-16 单元；缺失数字记 `-1`。旧 `debounce fired` 保留，其 `sentenceLength` 仍是 Swift 字符数。标识沿用既有 bundle 与 session UUID；不序列化原句 key、正文、锚窗、后一位字符或错误描述。

固定采样原因包含 `application_changed`、`application_unavailable`、`focus_changed`、`focus_unavailable`、`geometry_unavailable`、`composition_unreadable`、`anchor_read_failed`、`mapping_not_found`、`post_caret_mismatch`、`content_unreadable`、`content_qualification_failed`、`session_changed`、`composing`、`shortcut_recovery_empty`。协调器/防抖原因包含 `composing`、`empty_text`、`timing_changed`、`complete_sentence`、`shortcut`、`reset`、`source_language_changed`、`excluded_app`、`snapshot_replaced`、`disabled`；取句结果另记 `extraction_empty`、`source_language_mismatch`、`sentence_deduplicated`。
