# NetFlow · Mac 网络监控

为 Apple Silicon（含 M2）制作的原生菜单栏工具，支持 macOS 13 及以上。SwiftUI + AppKit，无第三方依赖。界面参考本地 F50 Monitor 的圆角卡片、绿色下行和蓝色上行布局，代码独立实现。

## 使用

打开 `dist/NetFlow.app`，菜单栏会出现波形图标和实时上下行速率。建议先将应用拖入「应用程序」文件夹，再在设置中按需开启「登录时启动」。没有 Dock 图标；点击菜单栏图标打开面板，右键可暂停监控、查看记录或退出。

- 每秒显示上行／下行速率，曲线展示最近 60 次采样。
- 按自然分钟累计流量，面板的「最近记录」可切换分钟／小时／天，分别显示最近五分钟、五小时或五天，并记住选择；上方保留今日、本小时、本月用量。
- 「查看全部记录」支持按分钟查看某小时、按小时查看某天、按天查看某月；可选择日期、前后翻页、导出当前时段 CSV。
- 深色、浅色和跟随系统三种外观。菜单栏可显示实时速率、今日用量或仅图标。
- 历史长期保存在本机，退出或重启后继续累计，不上传数据。

## 统计口径

自动模式读取所有 `en*` 物理网卡（通常包括 Wi-Fi、有线、USB 共享网络），排除 `lo0`、`utun*`、`awdl*`、`llw*`、网桥等接口，避免 VPN 和虚拟接口重复统计。特殊桥接网络可在设置中指定单一接口。接口更换时重新建立基线，旧记录保留，历史展示的是当时所选接口的合计，不能事后按接口拆分。

计数来自 macOS `NET_RT_IFLIST2` 的 64 位接口字节计数，包括局域网与协议开销，不等同于运营商账单或按应用流量。1 KB = 1,000 B，速率为字节/秒（B/s），不是比特/秒。

仅统计应用运行、未暂停且存在连续有效采样的时段。启动、切换网卡、休眠唤醒、计数重置和采样中断超过 10 秒会重新建立基线；这些空档不推算流量。空白时段显示「— / 未记录」，真正采样为零的时段显示「0 B」。分钟边界按采样间隔等比例分配，小时／日／月按当前系统时区汇总；夏令时长短日会保留实际小时数。

数据库约每 10 秒提交一次，正常退出、暂停、休眠前会立即保存。强制结束或断电可能丢失最后约 10 秒的未提交数据。应用使用运行锁避免两个实例重复记账；数据库写入失败时保留内存中的待保存数据并显示错误。

## 文件位置

正式数据：`~/Library/Application Support/NetFlow/traffic.sqlite`。设置页可直接打开文件夹。备份时先正常退出 NetFlow，再复制整个文件夹（包含 SQLite WAL 附属文件，如存在）。CSV 导出保留原始字节数、时区偏移和采样时长，可直接用 Numbers 或 Excel 打开。

`docs/panel.png` 和 `docs/history.png` 是演示数据界面图，不是实测流量。

## 构建和验证

需要 Xcode 或包含 Swift 的命令行工具。构建不下载第三方库。

```bash
./build.sh           # 构建 arm64 App 和 ZIP，输出到 dist/
./build.sh --run     # 构建并打开
./build.sh --debug   # 调试构建
./scripts/test.sh    # 核心采样、存储、时间边界测试
.build/debug/NetFlow --probe --seconds 3
```

开发专用：`--data-dir /绝对路径` 指定隔离数据库；`--show` 启动时展开面板；`--render-preview /绝对目录` 输出仅含演示数据的界面图后退出。

本地构建使用 ad-hoc 签名，未经过 Apple Developer ID 公证；分发到其他 Mac 如遇系统拦截，可从系统设置允许打开，或在目标机器从源码构建。

## 结构

- `Sources/NetFlowCore`：64 位网卡计数、分钟分配、SQLite 存储、日历汇总和 CSV。
- `Sources/NetFlow`：菜单栏、SwiftUI 面板、历史、设置和生命周期。
- `Tests/NetFlowCoreTests`：跨分钟／午夜、休眠／重置、重启累计、事务回滚、夏令时等测试。

API 参考：[Apple if_data64](https://developer.apple.com/documentation/kernel/if_data64)、[登录启动 SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)、[SwiftUI ImageRenderer](https://developer.apple.com/documentation/swiftui/imagerenderer)。
