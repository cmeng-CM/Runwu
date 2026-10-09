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

拟用 SettingsDockController 负责应用 policy 副作用及实际设置窗口登记，效果闭包可注入供隔离验证；SettingsView 通过 native window hook 把所属设置窗口交给同一控制器。AppState.presentSettings 重用窗口并恢复最小化；AppDelegate 启动维持 accessory、Dock reopen 走设置入口。实施后按真实接口回写。

## 明确不做

不隐藏菜单栏或翻译卡，不删除用户手工固定的 Dock 快捷方式；不清 TCC 授权、不创建或更换证书，不改服务、分句、主题和图标；不安装/退出/重启用户当前生产应用，不打 DMG、不推送或更新既有 Release。版本落后提示的具体来源尚未确认，不把构建号递增宣称为该提示的已验证修复。

## 已知限制

ad-hoc 代码更新可能需要重新授权，与 Dock 配置无关。测试使用假设置、密钥存储与服务及独立窗口/应用身份，不访问实际输入；用户手工固定的 Dock 项属于系统偏好，本应用不删除。仅验证当前系统原生 policy/窗口生命周期，其他系统版本和用户宿主焦点不作全兼容保证。自建设置窗口保留原有最小化/恢复；SwiftUI Settings scene保留系统固有能力，同系统独立基准（无新controller/LSUIElement）实际原生最小化按钮禁用、请求不生效；本次不新增该能力。

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

## 实际交付

起草阶段，交付将包含设置Dock生命周期实现与回归、启动plist、更新手册和本地润物.app；完成后按真实接口、测试及产物回写，不把规划当作已验证结果。
