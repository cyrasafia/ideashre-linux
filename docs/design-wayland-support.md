# IdeaShare Arch/Wayland 移植设计文档

- 状态: Draft v1
- 日期: 2026-09-09
- 目标环境: Arch Linux + GNOME 50 (Wayland only)
- 调研基线: packages/kylinOS_x86_64.deb (7.06.1.81)
- **范围: 仅投屏**。反控（键鼠/触摸回传）标记为低优先级，暂缓实施（见 §7 Backlog）

## 1. 背景

IdeaShare 官方 Linux 版仅提供麒麟/UOS 的 deb 包，且仅支持 X11 会话。本项目目标是在
Arch + GNOME Wayland 环境下实现**投屏**可用；反控暂不在当前范围内。

## 2. 环境调研结论: GNOME 50 与 XWayland

| 事实 | 结论 | 来源 |
|---|---|---|
| GNOME 50 (Tokyo, 2026-03) 完全移除 X11 会话 | GDM 无法登录 X11，无 X11 会话可回退 | ghacks 2026-03-20; mutter X11 后端已于 2025-11 合并删除 |
| XWayland 保留且为长期承诺 | X11 应用仍可透明运行，官方表态 "around for decades" | blogs.gnome.org X11 Session Removal FAQ |

**推论**: XWayland 方案在 GNOME 50 上"能启动"，是唯一免改动的运行方式；但它只解决
UI 渲染，不解决下文的核心问题（采集/反控）。

## 3. 应用侧调研结论（符号级证据）

以下均来自 `nm -D` 对解包后二进制的分析（解包: `./scripts/unpack.sh kylin`）。

### 3.1 UI 层

| 证据 | 位置 |
|---|---|
| 启动脚本强制 `QT_QPA_PLATFORM=xcb` | bin/ideashare.sh |
| 平台插件仅有 libqxcb.so，无 wayland 插件 | files/lib/platforms/ |
| 主程序链接 libQt5X11Extras.so.5 | bin/IdeaShare (ldd) |
| 自带完整 Qt 5.15.17 运行时（205 个 so） | files/lib/ |

### 3.2 屏幕采集链路（核心瓶颈）

采集调用链: `IdeaShare → libidea_video_master.so → libidea_video_vlink.so`，
vlink 直接动态链接 libX11.so.6/libxcb.so.1（PLT 导入，无 dlopen、无 XDamage/XComposite）:

```
U XOpenDisplay / XCloseDisplay        # 独立 display 连接
U XRRGetMonitors / XRRFreeMonitors    # 显示器枚举 (XRandR)
U XShmCreateImage / XShmAttach        # SHM 段建立
U XShmGetImage / XShmDetach           # 每帧抓屏（轮询式，无 damage）
U XGetImage                           # 非 SHM 回退路径
U XFixesGetCursorImage                # 光标图像合成
U XQueryPointer                       # 指针位置
U XInitThreads
```

辅助库 `libidea_video_vdm.so` 仅做 XRandR 显示器枚举；
`libideashare_data_projection_client.so` 用 `XGetInputFocus/XGetWindowAttributes/XGetWMName`
检测活动窗口。

### 3.3 反控（输入回传）链路（低优先级，暂缓）

- `bin/IdeaShareRvrsCtl` 与 `libidea_os_shmem.so` 引用 **uinput**: 虚拟触摸/键鼠设备走内核
  uinput（evdev 级），**与显示服务器无关，Wayland 下天然可用**
- 全部二进制中未发现 XTest 注入符号
- X11 依赖仅剩 `bin/reverse_detect.sh`: 非 x11 会话直接退出，且用
  `xinput map-to-output` 做触摸↔屏幕映射（X 侧配置，非注入）

### 3.4 问题定性

| 功能 | XWayland 下表现 | 原因 |
|---|---|---|
| 应用 UI | 正常 | Qt xcb → XWayland |
| 整屏投屏 | **残缺/黑屏** | XShmGetImage 只能取到 XWayland 窗口，取不到原生 Wayland 窗口（GNOME 50 上绝大多数窗口） |
| 光标合成 | 异常 | XFixesGetCursorImage 仅见 XWayland 内光标 |
| 反控注入 | 基本正常 | uinput 走内核 evdev |
| 触摸屏映射 | 失效 | reverse_detect.sh 提前退出；xinput 仅对 XWayland 生效 |

## 4. 方案对比

| 方案 | 做法 | 结论 |
|---|---|---|
| A. XWayland 直跑 | 现状，无改动 | UI 可用、投屏残缺，仅作验证基线 |
| B. qtwayland 原生窗口 | 为自带 Qt 5.15.17 编译 qtwayland 插件，patch 启动脚本 | 只解决 UI/输入，采集问题原样存在；且主程序硬链 Qt5X11Extras，风险高收益低 |
| C. 采集桥接（LD_PRELOAD） | 拦截 vlink 的 12 个 X11 采集符号，改走 xdg-desktop-portal + PipeWire | 解决核心瓶颈；不动闭源二进制 |
| D. 层级替换 | 弃用官方采集库，自研投屏客户端 | 工程量大，放弃 |

**选定: C 为主，B 为可选增强**（先 C 跑通投屏；UI 继续走 XWayland，后续再评估 B）。

## 5. 推荐方案设计: `libideashare-wayland-bridge`

新增 LD_PRELOAD 桥接库，仅对采集相关符号做替换，其余符号 `dlsym(RTLD_NEXT)` 透传给
XWayland 真实 libX11（显示器枚举 XRandR 在 XWayland 下返回真实布局，可直接透传）。

### 5.1 拦截点与实现

| 拦截符号 | 实现方式 |
|---|---|
| `XOpenDisplay/XCloseDisplay` | 透传（保留真实连接用于 XRandR/窗口查询） |
| `XRRGetMonitors` 等枚举 | 透传（XWayland 报告真实显示器布局） |
| `XShmCreateImage` | 透传；登记 SHM 段（后续填充目标） |
| `XShmAttach/XShmDetach` | 包装登记/清理 |
| `XShmGetImage` | **核心**: 后台 PipeWire 流线程（portal ScreenCast，one-shot/持久会话）持有最新帧；调用时把帧 blit 进应用的 SHM 段（按 root 坐标偏移、ZPixmap 32bpp 转换） |
| `XGetImage` | 分配 XImage 并从 PipeWire 最新帧填充（非 SHM 回退路径同样打通） |
| `XFixesGetCursorImage` | 由 PipeWire 流的 cursor metadata（spa meta Cursor）合成；首版可返回无光标 |
| `XQueryPointer` | 透传（注意: 指针位于 Wayland 原生窗口上时 XWayland 返回滞后值，见风险） |

### 5.2 数据流

```
IdeaShare(vlink)                bridge(.so LD_PRELOAD)              GNOME 50
     |  XShmGetImage()  ------------->  blit 到应用 SHM 段
     |                                  ^ 最新帧缓存
     |                                  | PipeWire 流线程
     |                                  X-- xdg-desktop-portal ScreenCast --> mutter
     |  (XRandR/窗口查询  --透传--> XWayland)
```

### 5.3 授权与会话

- portal ScreenCast 需用户授权对话框（每次或记住选择，由 GNOME Shell 弹出）
- 桥接库需处理 D-Bus 会话总线、ScreenCast 的 Handle/Path 生命周期与流参数协商
  (SPA_VIDEO_FORMAT/BGRx, resolution 跟随显示器)
- 帧率: vlink 为轮询式（无 XDamage），XShmGetImage 调用频率即投屏帧率，桥接层以
  "最新帧快照" 语义响应，天然合拍

### 5.4 反控修复（低优先级，暂缓，仅存档）

1. patch `reverse_detect.sh`: 移除 x11 会话检查；Wayland 下跳过或替换
   `xinput map-to-output`（单显示器场景无需映射，多显示器首版从简）
2. uinput 注入链路保持不动（已验证与显示服务器无关）
3. 如 Wayland 合成器后续限制 uinput（如孤立输入），再评估 libei + portal RemoteDesktop

### 5.5 打包形态

- `arch/PKGBUILD` 增加: `ideashare-bridge` 子包（或合并进主包），启动包装器改为
  `LD_PRELOAD=/opt/.../lib/libideashare-wayland-bridge.so ideashare`，
  仅当 `XDG_SESSION_TYPE=wayland` 时注入

## 6. 实施阶段

| 阶段 | 内容 | 验证标准 |
|---|---|---|
| M1 | XWayland 直跑基线（A） | GNOME 50 下 UI 启动、连接电视、投出残缺画面（确认瓶颈定性） |
| M2 | bridge 骨架: 拦截+透传+日志 | LD_PRELOAD 后 UI/显示器枚举不回归 |
| M3 | XShmGetImage ← PipeWire 打通 | 整屏投屏包含 Wayland 原生窗口内容 |
| M4 | XGetImage 回退路径 + 光标合成 | 光标可见、格式正确 |
| M5 | 多显示器/分数缩放适配（monitor scale 换算、选屏） | 多显示器下选屏与画面正确 |
| M6 | 打包集成 + README 更新 | makepkg 安装后开箱即用 |

## 7. Backlog（低优先级，暂缓）

- 反控全链路（原 M5 内容，待投屏稳定后再评估）:
  1. patch `reverse_detect.sh`: 移除 x11 会话检查；Wayland 下跳过或替换
     `xinput map-to-output`（单显示器场景无需映射，多显示器从简）
  2. uinput 注入链路保持不动（已验证与显示服务器无关）
  3. 如 Wayland 合成器后续限制 uinput（如孤立输入），再评估 libei + portal RemoteDesktop
- 阶段 B（qtwayland 原生窗口）评估

## 8. 风险与开放问题

- **闭源二进制**: vlink 内部可能按 display/visual 假设处理 XImage（如依赖
  DisplayWidth/screen 结构），bridge 需保证返回结构自洽
- **XQueryPointer 滞后**: 指针在 Wayland 原生窗口上时 XWayland 取不到实时位置，
  影响指针合成精度；必要时改由 portal RemoteDesktop/PointerConstraints 替代
- **portal 授权交互**: 每次投屏弹授权框的体验问题；持久化授权依赖 GNOME 设置
- **HDR/缩放**: GNOME 分数缩放下 XWayland 坐标系与真实分辨率有缩放换算，blit 需按
  monitor scale 换算
- **UOS 包差异**: 本设计基于麒麟包; UOS 包 (7.06.1.03) 未做同等符号级核对，移植时需复验
- **Qt5X11Extras 硬链**: 若后续走方案 B（原生 wayland 插件）需处理 X11 依赖，暂缓

## 9. 参考

- GNOME X11 Session Removal FAQ — blogs.gnome.org/alatiera (2025-06)
- GNOME 50 发布报道（X11 会话移除、XWayland 保留）— ghacks.net (2026-03-20)
- xdg-desktop-portal ScreenCast / PipeWire: https://flatpak.github.io/xdg-desktop-portal/
