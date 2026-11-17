# 首次归集、思源黑体与相册色彩

- [x] 自动归集仅在每个纪念日首次创建成功后触发；进入/切换/恢复/编辑/重启不触发
- [x] 手动归集与权限状态继续可用；取消和失败不会自动重试
- [x] 核对 Adobe 官方思源黑体版本、许可与文件摘要，离线打包字体
- [x] 全 App 和两端小组件使用思源黑体；相册文字采用低饱和灰蓝/石墨灰
- [x] 对照主流相册结构与视觉，检查对比度、窄屏、字号与实际截图
- [x] 自动化验证与两端构建，更新已连接的测试机并保留数据
- [x] 更新文档/交付包，关闭本任务模拟器与构建服务

Validation: 75 Flutter tests, analyzer, Android/iOS native collection and font flows passed. Android widget font faces and countdown visibility verified at140x140,340x140,180x180,340x180. Official font hashes and license verified in both deliverables. Samsung SM-N9760 updated with data preserved and installed APK hash checked. Owned simulators and task build/driver processes stopped.
