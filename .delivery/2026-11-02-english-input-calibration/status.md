# 英文输入校准 交付状态

| 项 | 状态 |
| --- | --- |
| 设计 | docs/designs/english-input-calibration.md v1.6（五轮独立复审通过） |
| 计划 | plan.md v1.1（REV-1 通过：plan-reviews/001.md） |
| T-01 路由与状态基础 | **已实现** c4029e3；V-1 通过 |
| T-02 LLM 校准任务 | **已实现** 9f7f754；V-1 通过（合同测试 17 项） |
| T-03 浮窗校准卡 | **已实现** 989e0d8；V-1 通过（含 CalibrationOverlayTests 8 项） |
| T-04 AppState 接线与设置 | **已实现** 362f81f；V-2 通过（CalibrationIntegrationTests 9 项 + SettingsStoreTests 扩展） |
| T-05 整体回归与手册 | **已实现** 3cbd28e；全量 `swift test` 400 项 0 失败（1 项联网探测跳过） |
| REV-2 整体实现审查 | 进行中（独立 agent） |
| V-3 整体证据集 | 全量测试已过；构建待 REV-2 后执行 |

## 任务进度与偏差

- **T-01 偏差**：`applyTranslationSettings` 依赖旧 reset 副作用（清 session/去重态）实现同句重发；按设计 4.4 意图落地为 `setSourceLanguage` 同语言 no-op + `flushForConfigurationChange()`（= reset 去掉 onEmpty，含 `session = nil`）。该分支是 T-04 设置链分流的提前落地。
- **T-04 偏差**：①`dismissCalibrationCard` 不再取消 coordinator（新请求在 `calibrateThrowing` 内自行取代旧请求；dismiss 时取消会竞态误杀新请求，与翻译管线 mutationID 守卫同一教训）；②A16 用例按设计 N-22 语义实现（后端变更后以"后续句子仍可校准"证明状态未失效，已显示未钉住卡允许被收起）；③集成测试的 sendLive 使用单一 session（每次调用新默认 session 会触发 session_changed reset，属测试构造问题非产品缺陷）。
- 已知偶发失败 G-5 本轮未出现。
- 测试适配（G-2）：19 处 onSentence 闭包加 route 参数；3 处 DiagnosticsSnapshot 构造加 2 个新字段；断言语义均未改动。OverlayServiceMetadata/ServiceRouting/CaretTracking 等既有测试全量通过。

## 恢复入口

- 下一步：REV-2 整体实现审查（agent）→ V-3 构建（build-app.sh + 签名）→ 按约定安装 /Applications → 用户人机复验。
- 基线：3cbd28e（分支 codex/caret-translation）。
