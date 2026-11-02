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
| T6/T7 审查修复 | **已实现** c2e6645 / 4687755 |
| REV-2 整体实现审查 | **通过**（implementation-reviews/001.md §7 复审：R2-01 修复核验通过、独立复跑 400/0/1skip、无新阻塞）；残留 R2-11/R2-12 已随后修复（T7） |
| V-3 整体证据集 | 全量 400 项 0 失败（修复后复跑）；`zsh Scripts/build-app.sh` 构建成功（Runwu Local 签名，`codesign --verify --deep --strict` 通过）→ **通过** |

## 任务进度与偏差

- **T-01 偏差**：`applyTranslationSettings` 依赖旧 reset 副作用（清 session/去重态）实现同句重发；按设计 4.4 意图落地为 `setSourceLanguage` 同语言 no-op + `flushForConfigurationChange()`（= reset 去掉 onEmpty，含 `session = nil`）。该分支是 T-04 设置链分流的提前落地。
- **T-04 偏差**：①`dismissCalibrationCard` 不再取消 coordinator（新请求在 `calibrateThrowing` 内自行取代旧请求；dismiss 时取消会竞态误杀新请求，与翻译管线 mutationID 守卫同一教训）；②A16 用例按设计 N-22 语义实现（后端变更后以"后续句子仍可校准"证明状态未失效，已显示未钉住卡允许被收起）；③集成测试的 sendLive 使用单一 session（每次调用新默认 session 会触发 session_changed reset，属测试构造问题非产品缺陷）。
- **REV-2 修复提交（T6）**：R2-01 校准锚点接线（monitor.onAnchorChanged 同喂 calibration.updateAnchor；此前 calibration.anchor 恒 nil、跟随模式下校准卡 orderOut 不显示，集成测试因按 cardContents（含不可见面板）计数而漏检——已收紧为 shownEntryIDs 断言）；R2-02 日志串多余 `}`；R2-07 移除未用 screen 参数；R2-08 handleInputSnapshot 单次抽句；R2-10 测试可见性收紧。
- **REV-2 未采纳项（记录理由）**：R2-03（tooLong 诊断口径，影响仅诊断行，维持现状）；R2-04（switchOff/sourceLanguage 专项诊断：这两种情形已被既有 sourceLanguageMismatch 诊断覆盖，避免重复刷日志）；R2-05（Entry 用可选字段替代 content 枚举——已在 T-03 反馈触发条款授权的等价实现，此处补记偏差）；R2-06（共享外壳降级为共享子组件——计划 T-03 预授权，分叉风险接受）；R2-09（量高恒计 corrected 段，偏大方向安全）。
- **T7（REV-2 复审残留项）**：R2-11 失焦路径补 `calibration.invalidate(clearAnchor: true)`；R2-12 startup/isolation 两处出卡等待同步收紧为 shownEntryIDs。修复后全量 400 项 0 失败。
- 已知偶发失败 G-5 本轮未出现。
- 测试适配（G-2）：19 处 onSentence 闭包加 route 参数；3 处 DiagnosticsSnapshot 构造加 2 个新字段；断言语义均未改动。OverlayServiceMetadata/ServiceRouting/CaretTracking 等既有测试全量通过。

## 完成判定

- T-01～T-05 + 审查修复全部实现 ✅
- V-1/V-2 通过 ✅；REV-2 整体审查通过（初审 1 阻塞 → T6 修复 → 复审通过，残留 R2-11/R2-12 → T7 修复）✅
- V-3 证据集：全量 400/0/1skip + `build-app.sh` 构建成功 + 严格签名校验通过 ✅
- 已按约定安装 /Applications/润物.app 并重启（PID 75201）✅
- **计划范围完成**。待用户人机复验：A2/A3/A8 真机手测（开关开启→写英文→看校准卡/切换/钉住/复制）、A12 IME 四宿主、A13 provider smoke、A10 一周试用（发行前判据）。

## 恢复入口

- 下一步：用户人机复验；发行（版本号/发行说明/DMG）另行启动。
- 最终基线：4687755（分支 codex/caret-translation，9 个本地提交，未 push）。
