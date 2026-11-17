# 连接测试机安装清单（2026-11-16）

- [x] 识别已连接设备：Samsung SM-N9760，ADB 已授权。
- [x] 校验日期修复 APK 与构建摘要中的 SHA-256 一致。
- [x] 使用保留数据的覆盖安装方式安装到该设备。
- [x] 启动应用并确认应用进程持续运行。
- [x] 执行 `dot_clean ./`，检查没有遗留本任务测试或构建进程。

安装包：[shiri-debug.apk](https://github.com/shawncai/anniversary/releases/download/v1.0.0/shiri-debug.apk)。
构建：`2026-11-16-date-entry-fix`；包名：`com.shiri.anniversary`。

## 安装结果

- `adb install -r` 返回 `Success`，未执行卸载或清除数据操作。
- 启动 `com.shiri.anniversary/.MainActivity` 返回 `Status: ok`。
- 后续再次读取应用 PID 仍为 `5964`，应用进程持续运行。
- 本任务没有启动模拟器或构建服务，安装与检查命令已结束；保留应用运行和原有ADB连接供用户测试。
