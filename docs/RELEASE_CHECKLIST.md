# 首次发布检查清单

目标仓库：https://github.com/shawncai/anniversary
版本：1.0.0+1 / v1.0.0
日期：2026-11-17

- [x] 检查本地目录与远端；本地原无 Git 历史，远端无分支。
- [x] 检查待提交文件的凭据、签名和个人路径。
- [x] 完善 .gitignore，并验证敏感文件不会进入提交。
- [x] 完善 README，加入已核实的运行截图。
- [x] 执行 Flutter 静态检查和测试。
- [x] 核对版本、发布说明和发布附件。
- [x] 提交并推送 main。
- [x] 推送版本标签并创建 GitHub release。
- [x] 核实远端提交、标签和 release。
- [x] 清理本轮生成的 AppleDouble 元数据并结束本轮服务。

## 本次验证

- `flutter analyze --no-pub`：通过，No issues found。
- `flutter test --no-pub --concurrency=1 --reporter expanded`：75/75 通过。
- 只读安全与架构审查：未发现明确发布阻断；不替代真机验收。
- 待提交文本经常见密钥、私钥、凭据赋值与个人路径扫描，未发现需要提交的凭据。文档中的本机 SDK 路径已改为通用说明。
- 忽略规则覆盖 `.env`、签名密钥/描述文件、设备配置、生成目录、原始设备 QA 日志和 `.shiri` 个人备份。
- 本次未修改应用逻辑、依赖或版本；复用现有开发验收构建，两份附件的字节数、SHA256 和 Dart 源码摘要均与原构建清单一致。本次未重新编译原生安装包。
- README 的三张 iOS 运行截图已逐张查看，使用测试夹具；本地原始 QA 记录包含设备路径，因此未提交。
- 本轮未启动模拟器、沙箱或长期服务；Flutter 检查和测试进程均已正常结束。

## 发布结果

- 源码提交：`81a371c0509a3e6b747270ca80b51eb90868c011`，已推送 `main`。
- 标签：`v1.0.0`，远端解引用与源码提交一致。
- [GitHub release](https://github.com/shawncai/anniversary/releases/tag/v1.0.0)：已公开发布。
- 四份附件均处于 `uploaded` 状态，GitHub 返回的 SHA256 与本地文件逐一一致。
- 仓库提交使用 GitHub noreply 邮箱，避免公开本机全局 Git 配置中的工作邮箱。
- 本清单的最终状态以单独文档提交同步到 `main`；版本标签保留在首次发布的源码快照。
