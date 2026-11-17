# 构建与验收记录

说明：以下为已有开发阶段的验收记录；`build-deliverables/qa/` 中的原始日志和设备元数据仅保存在本地，不随源码提交。公开运行截图见 [README](../README.md#界面预览)，本次发布验证见 [发布清单](RELEASE_CHECKLIST.md)。

本轮范围：iOS、Android、两端原生小组件；用户相册照片为唯一正式图片来源。

## 2026-11-16 全相册自动归集

- 进入相册后自动读取授权范围内的图片时间，按当前纪念日及前后范围直接归集、按年份显示，无需逐张选择或再次确认。每次运行按纪念日/范围/权限状态扫描一次，可点“重新归集”刷新新增照片。
- 原生扫描先排除首次日期之前和范围外的图片，再复制原件；Android补充EXIF拍摄时间回退，并保持筛选与归档使用同一时间。完整、部分、拒绝权限均有明确状态，系统设置返回后可重新归集。
- 全量59项Flutter测试通过，静态检查无问题。覆盖自动入口、分页、范围过滤、权限、重复归集、待确认升级、取消与暂存清理。
- 独立Android系统MediaStore和iOS PhotoKit真实相册各导入6张带日期的夹具，正确归集4张、排除2张；原生两页各2张、待确认0张、重复归集仍4张。完整流程各9张截图与严格完成标记通过。
- 证据：Android（本地历史证据：`build-deliverables/qa/auto-album-android/results.json`）、iOS（本地历史证据：`build-deliverables/qa/auto-album-ios/results.json`），已查看两端自动归集页面。Android时间索引为空的文件能正确读取EXIF；iOS通过系统弹窗授权后验证。
- 正常入口构建标记 `2026-11-16-auto-album`。没有向连接的用户手机注入夹具、清除数据或代为授予相册权限。

## 2026-11-16 首页精简

- 首页常驻文字仅有倒计时、周年数与累计天数。移除名称、具体日期、回忆胶片分区、照片数量、查看回忆和本机/备份文案；首页导航仅显示图标。
- 切换、编辑、添加封面、相册、数据入口均保留可访问名称和图标操作；无纪念日首页提供添加/导入图标，不生成示例。
- 全量49项测试及静态检查通过，包含首页文字白名单、图标入口、无封面、真实导入图片、320宽屏、大字号和深链导航。
- Android与iOS原生完整流程均通过，严格driver各确认8张截图。已查看安卓首页（本地历史证据：`build-deliverables/qa/minimal-home-android/01-anniversary.png`）、iOS首页（本地历史证据：`build-deliverables/qa/minimal-home-ios/01-anniversary.png`）及无封面首页（本地历史证据：`build-deliverables/qa/minimal-home-android/06-edited-anniversary.png`），仅显示核心数字，无文字溢出。
- 交付构建标记为 `2026-11-16-minimal-home`，使用正常应用入口，不包含测试照片或示例库；日期与本地存储逻辑未变更。

## 2026-11-16 首次日期入口

- 首次日期采用与名称相同的有边框输入框，固定显示标签和日期，右侧提供日历按钮；点击输入框或按钮均展开选择器。选择后回填，取消保留原值。
- 全量48项Flutter测试及静态检查通过。Android和iOS模拟器各通过9项日期编辑回归、输入框/展开状态截图及完整创建、编辑、照片流程。
- 已查看两端原生Android输入框截图（本地历史证据：`build-deliverables/qa/date-input-android/00-date-input.png`）及iOS输入框截图（本地历史证据：`build-deliverables/qa/date-input-ios/00-date-input.png`），日期入口和相邻表单对齐，无内容遮挡。各平台严格driver确认8张截图与所有完成标记。
- Android开发版和iOS完整未签名构建均更新为正常应用入口，继续只使用用户导入的照片；构建版本标记为 `2026-11-16-visible-date-input`。

## 2026-11-16 日期选择修复

- 原日期输入只接受斜杠格式，与编辑器显示的点号格式不一致；点号和横线输入的两个新增测试在旧实现失败。
- 首次日期直接展示年份列表，可先选过去的年份再选月日。输入兼容 `YYYY.MM.DD`、`YYYY/MM/DD`、`YYYY-MM-DD` 和 `YYYYMMDD`；非法日期仍拒绝，不自动滚到下月。
- 新增8项日期编辑回归测试；全量47/47通过，静态检查无问题。保存后的历史日期在重新打开资料库后保留，并驱动累计天数和下个周年倒计时。
- Android 35、iOS 26独立模拟器均通过8项日期编辑用例和2组原生完整流程，包含创建、修改和小组件快照保存。日期输入来自真实Flutter字段，未直接调用保存回调替代用户操作。
- 本次Android验证（本地历史证据：`build-deliverables/qa/date-fix-android/results.json`）及iOS验证（本地历史证据：`build-deliverables/qa/date-fix-ios/results.json`）各包含6张运行截图；两端交付包均重新以正常应用入口构建，不包含测试照片或测试入口。
- 没有升级依赖、修改数据库格式或操作用户连接的USB手机。iOS仍为未签名构建，真实iPhone安装需要签名。

## 已完成

- 全工程 `flutter analyze --no-pub`：无问题。
- `flutter test --concurrency=1 --reporter expanded`：59/59通过。
  - 日期：自然日、当天0、未来日期、闰日、跨年窗口、对应周年年份归集。
  - 本地存储：空库、原子持久化、真实文件归档、SHA去重、暂存清理。
  - 备份：完整原图roundtrip、冲突保留、损坏/截断/路径穿越拒绝。
  - 传输：双方SAS确认门禁、分片顺序、认证失败、截断、取消与过期清理。
  - 界面：创建/编辑、导入文件后实际计数、待确认归集、导入预览/取消/合并。
  - 布局：320宽屏、大字号、长倒计时；无溢出。
  - 小组件暖启动：有效链接退出旧照片页面并显示目标纪念日，无效链接保持原导航与数据。
  - 封面：明亮/暗色/局部亮条、真实RenderBox与变换位置，校验文字覆盖范围。
- Android Kotlin/资源/Manifest完整构建通过；原生AES-GCM标准向量、篡改拒绝、P256/HKDF及日期边界测试通过。
- Android实际AppWidgetHost小/中尺寸渲染与独立事件选择通过，已修复系统bitmap预算限制与最后widget移除后的残留alarm。
- iOS完整无签名设备构建通过，保留Assets和storyboard，真实WidgetKit扩展嵌入；原生13项日期用例通过。
- iOS独立模拟器真Native UI流程通过：3Tab、照片详情设封面、创建/修改日期、小组件快照同步；非mock平台桥。
- APK资源检查：未打包test/fixtures、assets/demo或任何设计照片；只包含正常字体/图标等应用资源。

## 最终状态

- 最终Android Flutter UI设备流程：通过。真实桥接、3页、封面、创建与编辑日期，日历点选模式，严格完成标记与6张截图检查通过。
- 最终同源iOS构建/截图：正常完整main设备构建与iPhone17模拟器核心流程全部通过，6张截图已刷新。
- 最终安装包摘要与路径：见[manifest](releases/v1.0.0-manifest.json)，Android开发签名APK及完整iOS未签名zip均已核验。

## 截图与数据说明

Android空库（本地历史证据：`build-deliverables/qa/android-empty.png`）、Android小组件（本地历史证据：`build-deliverables/qa/android-widget-small.png`）、Android中组件（本地历史证据：`build-deliverables/qa/android-widget-medium.png`）、iOS运行截图（本地历史证据：`build-deliverables/qa/ios/`）。

设备截图中的照片是测试工具先复制到独立测试资料库的夹具，用于模拟已经导入的用户文件。正式App没有该库、图片assets或示例入口。测试数据真实计数为3个纪念日、3张去重照片，未伪造设计稿的48/126张。

源设计以用户最终[首页](../design/selected/home.png)、[相册](../design/selected/album.png)、[数据](../design/selected/data.png)为依据。界面比较检查了配色、照片来源、字体、日期、主要操作、导航和内容完整性，不宣称AI图片与系统字体逐像素相同。

## 必须区分的验证边界

- Widget测试使用mock平台picker返回真实临时图片文件，验证归档/UI；模拟器UI流程使用真实平台桥与预先注入的独立资料库。两者都不等同于真实手机上的照片授权弹窗、系统picker和云相册不可用原图的完整验收。
- 纯Dart传输单测使用测试加密适配器；Android另有真实原生加密验证。iOS和Android两台真实手机的BLE、局域网权限、配对、长时间大相册传输、网络切换、后台恢复仍须实机验收。
- iOS WidgetKit的完整构建、日期逻辑与App Group快照已验证；系统桌面实际摆放、各机型/字号外观与系统调度刷新仍需用户签名后的实机验证。
- iOS未签名zip不能直接安装到iPhone。Android包是开发签名debug包，不是商店发布包。

## 运行环境与清理

原有Android AVD缺少镜像，已通过官方SDK Manager安装Android35 ARM64镜像并创建独立测试AVD。Xcode原先缺少iOS平台运行时，已补齐iOS26.0.1。没有升级Flutter或应用依赖。

外置磁盘上的AppleDouble元数据会污染Gradle与Android特征缓存；构建缓存和本任务模拟器配置使用内盘临时目录，未删除用户原缓存或操作连接的USB手机。

本任务独立模拟器、driver、接收服务、Gradle/Kotlin进程在交付前关闭；测试widget host/IDs和绑定权限由harness释放。生成文件后均执行dot_clean。

测试工具说明：Android官方integration_test的表面截图转换会改变FlutterView呈现方式；首次组合测试在转换后调用系统键盘时出现IME等待。将键盘交互安排到截图转换前，拆为由SDK自动恢复表面的独立用例。2026-11-16新增的输入回归位于所有截图转换之前，Android和iOS均通过四种日期格式输入及日历点选。生产App不调用截图转换。

## 最终交付

Android开发版APK与iOS完整无签名zip均来自最终正常入口lib/main.dart；测试入口APK单独存放在内盘临时目录，未作为交付安装包。截图与日期验证均不依赖固定生产照片。两端测试模拟器已关闭，测试driver/接收/构建服务已结束；未操作用户连接的USB手机。

最后增量仅修复小组件暖启动路由：已有照片详情页时，点击有效小组件链接会回到相应纪念日首页；MethodChannel消息回归测试通过。此修改不影响已有视觉截图，交付包在回归后重新构建。

测试稳定性：图片文件复制/哈希使用真实I/O，widget测试等待真实业务条件而非固定延时；已将过短等待窗口调整到可覆盖并行原生构建负载，并以串行全量39项复核通过。所有业务断言保留。

## 2026-11-16: 相册多选、封面与日历提醒

- Flutter analyze通过；72项单元/组件测试通过。覆盖旧版JSON、完整备份/移出排除记录、多选确认与取消、固定/轮播/定时/年份/自选组、一次/年度提醒、闰日、当天弹窗去重、320px与放大字体。
- Android35及iOS26隔离模拟器实际桥接流程通过，各5张截图及严格完成标记见`build-deliverables/qa/management-{android,ios}/results.json`。注入的是既有合成照片测试库，正式包不包含这些图片。
- 两端本机日历测试年度事项连续更新、单次→年度→单次、提醒开启→关闭。Android CalendarProvider检查3条本机事项、2条启用提醒，重复操作不新增事项。iOS以EventKit公开API读取生效提醒，年度/单次各1个提醒，关闭事项0个提醒；原始数据库的系统默认提醒占位不代表额外生效提醒。只在模拟器编译的诊断入口限QA标识，实体设备构建不包含该入口。
- Android Java与iOS Swift原生日期计算检查通过，含不重复、闰日、DST；原生小组件快照写入通过。桌面系统调度限制仍适用，不承诺小组件秒级轮播。
- 系统日历通知需用户允许日历访问并开启系统日历通知；没有本机日历源不会写入云端源，而是提示仅应用内提醒。未执行实体手机日历/相册授权，也未向实体手机注入测试资料。

本轮交付：Android正式入口调试包已用`install -r`更新Samsung SM-N9760，设备包SHA256与交付包一致；iOS完整未签名设备包已重新生成。两端专用模拟器和本轮构建/驱动服务已关闭。

## 2026-11-16: 首次归集、思源黑体和淡雅相册

- 75项 Flutter 测试通过，静态分析无问题。新增创建一次、编辑/恢复/重建页面不扫描、拒绝首次授权后不自动重试、手动归集及字体/文字对比度检查；保留320px和大字号覆盖。
- Android35和iOS26实际平台流程均通过，各4张截图及严格完成标记见 `qa/font-collection-{android,ios}/results.json`。实际系统相册在新建后归集4张，修改日期、返回相册及恢复应用仍为4张，手动点“归集”后为5张。
- 四个正式字体资产均在实际Flutter包内加载，通过OTF头检查；两端相册截图核对石墨灰/灰蓝字体及层级。375px宽度的Android实际页面预览见 `qa/font-collection-android/album-preview-375.png`。
- Android实际AppWidgetHostView验证绑定字体、可见倒计时及大小尺寸渲染。Source Han字形度量较大，原生TextView关闭额外字体padding，避免压缩倒计时区域。iOS字体通过CoreText注册及中英文字符检查，WidgetKit包包含三种实际使用字重。
- 正式包不包含预览照片，字体和OFL许可离线打包；没有增加在线字体或包依赖。

Android原生倒计时开启字号自适应，补充140×140和340×140最小尺寸检查，字体与数字完整显示；iOS小组件标题/日期和锁屏文本允许按空间缩放。最终包已保留数据更新至Samsung SM-N9760并核对摘要。iOS未签名包同步更新，本轮专用模拟器及构建/驱动进程已关闭。
