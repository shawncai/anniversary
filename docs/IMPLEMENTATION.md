# 拾日 v1 实现与运行

## 技术栈

- Flutter3.32.6 / Dart3.8.1共享界面、日期、本地资料库、备份和传输协议。
- iOS16+：Photos/PHPicker、CryptoKit、CoreBluetooth、WidgetKit，iOS17+支持小组件编辑选择纪念日。
- Android8(API26)+：MediaStore/PhotoPicker、javax.crypto、BLE、RemoteViews AppWidget。
- 包名com.shiri.anniversary；App Group group.com.shiri.anniversary。
- 不需要账号、APIKey、服务器、远程字体、统计SDK。唯一额外运行依赖crypto3.0.6已做用途/发布者审查，见DEPENDENCIES.md。

## 当前视觉依据

以用户最终附图为准：[首页](../design/selected/home.png)、[相册](../design/selected/album.png)、[数据](../design/selected/data.png)。后续要求覆盖旧首页：首页仅保留封面、倒计时/周年与已过天数；所有管理操作移至相册。相册和数据遵循直角网格/简洁列表。桌面小组件入口增加在数据页。

所有正式界面、封面、回忆照片和小组件都只读取用户导入的文件。初始资料库为空。未提供“示例数据”入口；test/fixtures仅供测试，不声明在pubspec assets中，不打包进App。无照片时显示纯色；添加入口位于相册。

## 主要流程

1. 首次打开添加纪念日，选择首次日期与照片归集日期范围。
2. 选择照片：系统选取后复制原图和JPEG缩略图到应用私有目录，内容SHA256去重。
3. 每个纪念日首次创建成功后自动归集一次，读取已授权图片时间索引、匹配日期范围、直接归集并补全空封面。后续只由“归集”按钮触发；进入/切换相册、编辑日期或范围、重启、权限变化和备份恢复都不自动归集。首次尝试拒绝、停止或失败后也不自动重试。云端原图不可读时报告不可用，不静默联网下载。
4. 打开照片可设为封面、修改日期或移出当前纪念日；移出只变更关联，保留原图。
5. 导出完整备份：纪念日、原图、缩略图、日期和关联写入.shiri流式文件；用户完成系统另存操作后才更新备份状态。
6. 导入：全包长度/路径/摘要校验，先预览新增、重复和冲突，再合并；默认保留本机内容。
7. 附近互传：两台手机进入发送/接收，同Wi-Fi或热点；蓝牙辅助发现，也可手输接收方地址；双方核对六位配对码并确认后才加密发送。
8. 小组件：数据页添加入口或系统小组件面板；支持事件选择、倒计时、已过天数、用户封面与点击打开事件。没有资料或图片显示纯色空态。

## 数据与传输

应用私有documents下保存原子library.json、内容寻址originals与thumbnails；原始导入暂存副本成功提交后清理。系统云备份已显式排除。

.shiri是版本化流式容器，魔数SHIRI001，带JSON清单、固定长度记录与每文件SHA256。导入只允许预定义内容寻址路径，禁止任意路径、链接或嵌套归档。原图逐文件流式处理，单原图上限512MB、缩略图16MB、清单32MB、整个容器64GB。

局域网传输握手使用系统P256 ECDH和HKDF-SHA256；文件分片AES256-GCM，带会话和序号AAD。六位SAS由完整会话和双方公钥派生，用户必须在双方确认。地址/公钥握手不含私密照片；照片流加密。进度、取消、过期、断开和校验失败均有状态；离开传输页或进入后台关闭监听和蓝牙。接收完成后仍需预览合并。

## 日期与照片文字

日期按自然日计算，起始日为0；周年当天倒计时0；闰日遇非闰年按2月28日；未来首次日期不显示负已过天数。以设备本地时区解释拍摄日期，允许用户修正。跨年日期窗口内的照片按最近的周年年份归组，窗口外的手动照片按拍摄年份归组。

封面根据实际文字RenderBox和最终裁切采样，比较黑/白字对比度。明暗混杂时为文字覆盖范围添加局部遮罩，换图、裁切、字号与布局变化后重算。小组件采用各自原生布局与背景处理，更新时机受系统限制，不承诺秒级刷新。

## 构建

使用 Flutter 3.32.6，并将其 `bin` 目录加入 `PATH`。本项目不使用npm/yarn；不运行自动依赖升级。

```sh
flutter pub get --offline
flutter analyze --no-pub
flutter test
flutter build apk --debug
flutter build ios --debug --no-codesign
```

当前项目在外置磁盘，AppleDouble的._文件会污染Gradle资源和Kotlin缓存。已支持内盘构建目录（先运行一次 `flutter build apk --debug`，由 Flutter 初始化 Gradle wrapper 后再使用以下命令）：

```sh
cd android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
GRADLE_USER_HOME=/private/tmp/shiri-gradle-native \
SHIRI_ANDROID_BUILD_DIR=/private/tmp/shiri-android-native-build \
./gradlew :app:assembleDebug --no-daemon
```

APK源产物位于/private/tmp/shiri-android-native-build/app/outputs/apk/debug。交付版本复制到build-deliverables。每轮生成文件后执行dot_clean ./。

iOS首次构建需要完整Xcode iOS平台与运行时。若actool/ibtool提示Platform Not Installed，安装对应Xcode组件后重试；不能用排除Assets或storyboard的产物作为安装包。

## 签名与真机

Android debug APK用于开发验收。发布版需要用户自己的签名keystore（不存储密码/私钥到仓库）；release构建不会借用debug签名。

iOS真机安装需要在Xcode选择用户的Apple Development Team，并为App和Widget扩展开通相同App Group。仅无签名编译不能生成可直接安装的iPhone包。不要将签名私钥或口令提交到项目。

两部真实手机的照片授权、蓝牙发现、局域网互传与桌面小组件应在发布前验收。纯Dart协议测试使用测试加密适配器；不能替代系统加密互操作或真机权限验收。

## Album management and cover playback

Album owns event creation, switching, editing, calendar permission access and cover settings. The anniversary hero has no action buttons. A first-run empty hero points to the album.

Confirmed-photo grids support explicit multi-select and long-press selection, select-all, add-to-another-anniversary, fixed cover (one photo), slideshow group (several), and confirmed batch removal. Removal requires “执行移出”, retains archived/system originals, clears affected cover references, and stores an `excluded` association. Automatic scans do not revive exclusions; explicit manual import/add does. Backups preserve exclusions and cover groups. Existing version1 libraries default to annual recurrence, fixed cover and reminders off; opening an old library never requests a new calendar permission.

Cover settings persist independently of native calendar IDs: mode (`fixed`, `slideshow`, `daily`, `interval`), source (`all`, `year`, `selection`), explicit photo IDs/year, seconds per step and daily local change minute. Selection is deterministic across restarts. Empty groups show no image; they do not pull unrelated photos. Every changed hero image goes through existing text-region contrast analysis. The UI only repaints when the selected image/day changes; it does not decode an image every second.

New events default to yearly repeat and09:00 day reminders. The editor can disable reminders or choose one-time scheduling. Calendar reconciliation runs without permission prompts after import and app resume when permission was already granted; explicit save may request permission. Native calendar rejection never rolls back locally saved event data.
