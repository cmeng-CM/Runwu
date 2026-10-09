# 设置窗口与 Dock 显示

## 一句话方案

应用以菜单栏身份启动；只有设置窗口处于打开状态时切换为普通应用，所有设置窗口关闭后恢复菜单栏身份。

## 背景与目标

用户明确要求安装启动后只显示菜单栏，打开设置才显示 Dock。当前 Info.plist 未声明 LSUIElement，AppDelegate 未设置 activationPolicy；AppState 缓存的 settingsWindow 关闭后仍保留但没有关闭状态回调。另有 SwiftUI Settings scene，不能漏掉该入口。承接 [浮窗与输入设计](overlay-service.md)，仅改变应用与设置窗口生命周期，不改变翻译及授权机制。

## 做法

Info.plist 声明 LSUIElement=true，启动为 accessory，保留可交互窗口。设置窗口专用控制器登记真实 NSWindow；自建设置与 SwiftUI Settings scene 共用该生命周期，不能用全部 NSApp.windows 推断 Dock，也不覆盖 SwiftUI 既有 delegate。窗口发现/观察与实际打开状态分开；关闭后缓存视图的重绘或迟到 hook 更新不能重新把它标为打开，只有再次真实展示/激活才恢复打开状态。关闭通知时 isVisible 仍可能为 true，因此关闭状态优先于可见性。打开设置前或真实设置窗口出现时设 regular；窗口关闭通知仅移除对应设置登记，最后一个关闭后设 accessory。最小化仍属于打开状态，Dock 保留；重新打开设置恢复最小化并激活原窗口。欢迎、授权、翻译宿主、浮窗和菜单展开不增加设置登记。

应用名、bundle ID、展示版本保持润物/com.comeg.runwu/0.1.0；内部 CFBundleVersion 从1递增为2，表示本次新构建。仍使用 ad-hoc 签名，构建号不能解决签名变化引起的授权失效。

## 备选与取舍

固定 accessory 无法满足打开设置显示 Dock；固定 regular 会在后台常驻 Dock。采用设置窗口专用登记与关闭通知。SettingsView.onDisappear 并不等于窗口关闭，避免以它隐藏 Dock；保留两种既有设置入口，不用删除 Settings scene 避开生命周期。

## 接口与数据形状

SettingsDockController 是 @MainActor NSObject。init(setPolicy: (NSApplication.ActivationPolicy) -> Bool, activate: () -> Void) 可注入副作用，正常 runtime 使用 shared 和 NSApp API。start() 更新启动身份；registerSettingsWindow(_:) 观察所属设置窗；showSettingsWindow(_:) 标记打开、切换 regular、恢复最小化并激活；restoreOpenSettingsWindow() -> Bool 恢复已打开设置。openSettingsWindowCount 和 lastPolicyChangeSucceeded 提供隔离验证观察。

登记以 ObjectIdentifier 为键，弱持有 NSWindow，分别记录 isOpen、hasClosed 与 isVisible KVO。真实 false→true 或真实 key/main 事件建立新打开状态；willClose 同步先关闭登记，缓存 hook 的更新不覆盖关闭状态。SettingsWindowHook/SettingsWindowHookView 通过 viewDidMoveToWindow 与 updateNSView 发现真实窗口，更新标题，不替换 delegate。打开后的下一主循环只在窗口仍打开、可见且未最小化时补激活，防止 policy 切换暂时丢失焦点；已关闭窗口不会由该动作重新出现。

AppState 注入 settingsDockController；presentSettings() -> NSWindow 复用原窗口并经同一控制器展示。AppDelegate(state:) 支持假状态，启动调用 start()；Dock reopen 忽略其他窗口的 hasVisibleWindows，优先恢复设置。startTranslationHost() 同时检查 runtimeEnabled，使隔离状态不启动真实宿主。

## 明确不做

不隐藏菜单栏或翻译卡，不删除用户手工固定的 Dock 快捷方式；不清 TCC 授权、不创建或更换证书，不改服务、分句、主题和图标；不安装/退出/重启用户当前生产应用，不打 DMG、不推送或更新既有 Release。版本落后提示的具体来源尚未确认，不把构建号递增宣称为该提示的已验证修复。

## 已知限制

ad-hoc 代码更新可能需要重新授权，与 Dock 配置无关。测试使用假设置、密钥存储与服务及独立窗口/应用身份，不访问实际输入；用户手工固定的 Dock 项属于系统偏好，本应用不删除。仅验证当前系统原生 policy/窗口生命周期，其他系统版本和用户宿主焦点不作全兼容保证。policy 切换及 Dock 动画有系统传播时间；独立实测等待800ms后验证原有最小化，不增加产品固定延迟。外部代码主动修改应用 policy 不属于本次控制场景。自建设置窗口保留原有最小化/恢复；SwiftUI Settings scene保留系统固有能力，同系统独立基准（无新controller/LSUIElement）实际原生最小化按钮禁用、请求不生效；本次不新增该能力。

## 验收标准

- 本地包 LSUIElement=true，0.1.0/build2、bundle ID及品牌正确，strict ad-hoc验签通过。
- 启动 accessory；自建设置与SwiftUI设置窗口打开进入regular，关闭最后一个恢复accessory，其他窗口不影响。
- 关闭后重复打开与最小化恢复可用；旧窗口的迟到关闭不能隐藏新的设置窗口，已关闭缓存视图更新不能重新显示Dock。
- 真实 native window hook及关闭通知驱动回归，effects假注入不抢用户生产应用；可独立测试真实NSApplication policy，记录验证边界。
- 相关与全量 swift test、release build通过；冻结已发布DMG摘要不变。

## 决策摘要

| ID | 决策 | 来源 | 理由 |
| --- | --- | --- | --- |
| D-01 | 启动只菜单栏，打开设置显示Dock，关闭设置隐藏 | 用户 | 当前明确需求 |
| D-02 | LSUIElement启动标记和设置窗口专用生命周期 | agent | 实现D01且不把浮窗/临时提示当设置；保留实际设置入口及最小化恢复 |
| D-03 | native window hook、过滤close通知与注入effects | agent | 两种现有设置入口均受控，避免抢SwiftUI delegate，隔离验证不操作真实授权 |
| D-04 | 展示版本0.1.0不变、内部build递增为2 | agent | 用户前问安装版本；新旧包原均build1，递增仅区分构建，不改变发布版本或签名策略 |
| D-05 | 弱窗口登记、closed状态与真实可见性转换/KVO | agent | show未必成为key，willClose时仍可见；分开观察与打开，避免闭缓存重绘重新显示Dock；依赖AppKit主线程通知 |
| D-06 | 打开后下一主循环按当前状态补激活 | agent | policy切换可能暂时失焦，真实两入口已验证；弱引用和open/visible/mini检查防止关闭后重现 |
| D-07 | 相同policy快路径，检查失败且后续状态更新重试 | agent | 已是accessory时重复请求可返回false；不误报成功切换，失败不缓存为已应用；不监控外部主动修改policy |
| D-08 | 保留原SwiftUI Settings最小化边界 | agent | 无新policy/controller的同系统基准按钮禁用、请求不生效；不新增无效样式或modifier，原自建设置mini/恢复通过独立实测 |

## 实际交付

实现已落在 App.swift、SettingsUI.swift、新 SettingsDockController.swift 与 Info.plist，增加5项 SettingsDockTests 原生窗口回归。全量278项，1项原有联网探测默认跳过，执行项零失败；独立假数据应用实测真实SwiftUI Settings scene、手动设置、关闭缓存更新、重开、多窗口、实际 policy及自建设置最小化/恢复。

本地交付润物.app：润物/com.comeg.runwu/0.1.0/build2/LSUIElement=true，采用既有 ad-hoc构建脚本与严格验签；README说明菜单栏/设置/Dock生命周期及当前源码范围。正式本地包的命令、退出码及实际身份核验落在工作流验证记录。

与原计划的差异是验证口径明确区分SwiftUI Settings的系统固有最小化边界与自建设置能力；原基准同样禁用，不新增窗口改造。候选实现中的无效样式/modifier已移除。没有未完成的Dock实现；未安装或启动用户的生产应用，尚未实测所有系统/真实宿主。原v0.1.0 DMG和远端保持，SHA256为6dcd4cf78e599b73890097237dd1514b0cfeff4674d47c503bc2250e3143a93d。
