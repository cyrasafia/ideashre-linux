# IdeaShare for Arch Linux (含 Wayland 支持计划)

将华为 IdeaShare（智慧屏无线投屏，PC 端）移植到 **Arch Linux**，并添加 **Wayland** 支持。

官方 Linux 版仅提供麒麟（KylinOS）与 UOS 安装包，且仅支持 X11 会话。

## 官方包分析结论

| 项目 | 麒麟包 | UOS 包 |
|---|---|---|
| 版本 | 7.06.1.81 | 7.06.1.03 |
| 架构 | x86_64 (deb) | x86_64 (deb) |
| 安装前缀 | `/opt/apps/com.huawei.ideashare` | 同左 |
| 额外依赖 | `desktop-file-utils` | `desktop-file-utils`, `deepin-elf-verify` |

**仅支持 X11 的原因**（移植需要解决的问题）：

1. 启动脚本 `bin/ideashare.sh` 强制 `QT_QPA_PLATFORM=xcb`
2. 自带 Qt 5.15.17 运行时，但平台插件目录仅有 `lib/platforms/libqxcb.so`，无 Wayland 插件
3. 主程序 `bin/IdeaShare` 直接链接 `libQt5X11Extras.so.5`
4. 反控相关脚本 `bin/reverse_detect.sh` 依赖 `xinput`/`xrandr`，非 X11 会话直接退出
5. 屏幕采集库（`libidea_mediacontrol_device_capture.so` 等）疑似走 X11 抓屏接口，待确认

## 仓库结构

```
packages/    官方原始 deb 安装包（作为移植基线，勿改动）
patches/     对官方文件的补丁 / 替换脚本
scripts/     辅助脚本（unpack.sh 解包分析等）
arch/        PKGBUILD 等 Arch 打包文件
docs/        设计文档（Wayland 支持方案见 docs/design-wayland-support.md）
```

> Wayland 移植的调研结论与选定方案（LD_PRELOAD 采集桥接 → xdg-desktop-portal + PipeWire）
> 详见 [docs/design-wayland-support.md](docs/design-wayland-support.md)。

## 快速开始（分析环境）

```bash
./scripts/unpack.sh all      # 解包两个 deb 到 unpack/
ls unpack/kylin/data/opt/apps/com.huawei.ideashare/files/bin/
```

## 路线图

> 当前范围: **仅投屏**；反控（键鼠/触摸回传）为低优先级，暂缓实施（详见设计文档 §7 Backlog）

- [ ] **阶段 0**：解包分析（采集/编码链路、动态库依赖清单）
- [ ] **阶段 1**：Arch 打包（PKGBUILD 重打包，X11 会话下可用）
- [ ] **阶段 2**：Wayland 兼容运行（XWayland 下运行 xcb 插件，验证投屏与反控）
- [ ] **阶段 3**：原生 Wayland 支持（patch 启动脚本按 `XDG_SESSION_TYPE` 选择平台插件；为自带 Qt 5.15.17 编译 `qtwayland`；评估屏幕采集替换为 PipeWire/XDG-Desktop-Portal 的可行性）

## 已知风险

- 主程序为闭源二进制且链接 `Qt5X11Extras`，原生 Wayland 窗口可能需依赖 Qt 的 xcb 兼容层或二进制 patch
- 官方包捆绑全部依赖（205 个 so），与 Arch 系统库混用时需注意符号冲突，打包时优先使用自带库
- 反控（触摸/键鼠回传）在 Wayland 下受输入权限限制，可能需要额外方案（低优先级，暂缓）

## 声明

本项目仅用于学习与研究目的，IdeaShare 及相关二进制版权归华为所有。请通过官方渠道获取原始安装包。
