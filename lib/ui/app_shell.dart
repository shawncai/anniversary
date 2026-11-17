import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/archive.dart';
import '../core/calendar.dart';
import '../core/models.dart';
import 'adaptive_cover.dart';
import 'app_controller.dart';
import 'event_editor.dart';
import 'cover_editor.dart';
import 'photo_page.dart';
import 'theme.dart';
import 'transfer_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final AppController controller;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  AppController get c => widget.controller;
  int _tab = 0;
  final _heroNumber = GlobalKey();
  final _heroUnit = GlobalKey();
  final _heroAnniversary = GlobalKey();
  bool _busy = false;
  String _task = '';
  StreamSubscription<String>? _links;
  Timer? _clock;
  bool _reminderOpen = false;
  bool _foreground = true;
  String? _lastCoverId;
  int? _lastMinute;

  void _activateTab(int index) {
    if (_tab == 1 && index != 1 && c.scanningPhotos) c.cancelScan = true;
    setState(() => _tab = index);
    if (index == 1) unawaited(_refreshAlbumPermission());
  }

  Future<void> _refreshAlbumPermission() async {
    try {
      // Reading authorization state must never start a scan or request access.
      await c.refreshPhotoAccess();
    } on PlatformException {
      // An explicit collection action reports the platform error.
    }
  }

  Future<void> _openPhotoSettings() => _run('打开相册权限', c.native.openSettings);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_changed);
    _links = c.native.deepLinks.listen((link) async {
      final uri = Uri.tryParse(link);
      final id = uri?.pathSegments.firstOrNull;
      if (uri?.scheme != 'shiri' ||
          uri?.host != 'anniversary' ||
          !c.state.events.any((event) => event.id == id))
        return;
      await c.handleLink(link);
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        setState(() => _tab = 0);
      }
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_foreground) return;
      final coverId = c.displayedCover(c.selected)?.id;
      final minuteKey = c.time().millisecondsSinceEpoch ~/ 60000;
      final minute = minuteKey != _lastMinute;
      _lastMinute = minuteKey;
      if (_tab == 0 && (coverId != _lastCoverId || minute)) setState(() {});
      _lastCoverId = coverId;
      if (minute) {
        unawaited(_showDayReminders());
        unawaited(c.syncWidgets());
      }
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_showDayReminders()),
    );
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_showDayReminders());
      _changed();
      unawaited(c.syncWidgets());
      unawaited(c.syncSavedReminders(refresh: true));
      if (_tab == 1) unawaited(_refreshAlbumPermission());
    }
  }

  @override
  void dispose() {
    c.cancelScan = true;
    c.removeListener(_changed);
    _links?.cancel();
    _clock?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _showDayReminders() async {
    if (!mounted ||
        !_foreground ||
        _reminderOpen ||
        _busy ||
        ModalRoute.of(context)?.isCurrent != true)
      return;
    _reminderOpen = true;
    try {
      final due = await c.takeDayReminders();
      if (!mounted || due.isEmpty) return;
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('今天是纪念日'),
          content: Text(due.map((e) => e.title).join('\n')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } on PlatformException {
      /* A reminder must never interrupt app startup. */
    } finally {
      _reminderOpen = false;
    }
  }

  void _message(String value) {
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _run(String task, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _task = task;
    });
    try {
      await action();
    } catch (error) {
      _message(
        error is PlatformException
            ? error.message ?? '系统操作未完成'
            : error.toString().replaceFirst('FormatException: ', ''),
      );
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _task = '';
        });
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_showDayReminders()),
      );
    }
  }

  Future<void> _chooseEvent() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(),
      builder: (sheet) => AlbumTheme(
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ...c.state.events.map(
                (event) => ListTile(
                  title: Text(event.title),
                  subtitle: Text(dateLabel(event.startDate.iso)),
                  leading: event.id == c.selected?.id
                      ? const Icon(Icons.check, color: ShiriTheme.albumAccent)
                      : const SizedBox(width: 24),
                  trailing: IconButton(
                    tooltip: '编辑纪念日',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () {
                      Navigator.pop(sheet);
                      unawaited(_editEvent(event));
                    },
                  ),
                  onTap: () {
                    Navigator.pop(sheet);
                    unawaited(_run('切换纪念日', () => c.select(event.id)));
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('添加纪念日'),
                onTap: () {
                  Navigator.pop(sheet);
                  unawaited(_editEvent());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editEvent([Anniversary? event]) async {
    final result = await showModalBottomSheet<Anniversary>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(),
      builder: (_) => AlbumTheme(
        child: EventEditor(event: event, today: c.clock()),
      ),
    );
    if (result == null || !mounted) return;
    final isNew = event == null;
    await _run('保存纪念日', () async {
      await c.saveEvent(result);
      final status = c.reminderStatus[result.id];
      if (status != null) _message(status);
    });
    // The creation action owns this single attempt. Reopening the page/app,
    // editing a rule, restoring a backup or changing permissions cannot retry it.
    if (isNew && mounted && c.selected?.id == result.id) {
      await _collectPhotos(automatic: true);
    }
  }

  Future<void> _manageAlbum() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(),
      builder: (sheet) => AlbumTheme(
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in [
                ('add', '添加纪念日', Icons.add),
                ('edit', '编辑纪念日', Icons.edit_outlined),
                ('cover', '封面展示', Icons.slideshow_outlined),
                ('reminder', '设置日历提醒', Icons.event_available_outlined),
                ('permission', '日历权限', Icons.settings_outlined),
              ])
                ListTile(
                  leading: Icon(item.$3),
                  title: Text(item.$2),
                  onTap: () => Navigator.pop(sheet, item.$1),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'permission') await c.native.openSettings();
    if (action == 'add') await _editEvent();
    if (action == 'edit') await _editEvent(c.selected);
    if (!mounted) return;
    if (action == 'cover' && c.selected != null)
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => CoverEditor(controller: c, eventId: c.selected!.id),
        ),
      );
    if (action == 'reminder' && c.selected != null)
      await _editEvent(c.selected);
  }

  Future<void> _pickPhotos() => _run('导入照片', () async {
    final count = await c.addPhotos();
    if (count > 0) _message('已添加 $count 张照片');
  });

  Future<void> _collectPhotos({bool automatic = false}) async {
    final event = c.selected;
    if (_busy || event == null) return;
    await _run('正在读取相册照片', () async {
      final (count, unavailable) = await c.scanPhotos(
        onProgress: (n) {
          if (mounted) setState(() => _task = '已归集 $n 张照片');
        },
      );
      if (c.photoAccess != 'full' && c.photoAccess != 'limited') return;
      if (!automatic || count > 0 || unavailable > 0 || c.cancelScan) {
        _message(
          '${c.cancelScan ? '已停止，' : ''}已归集 $count 张新照片'
          '${unavailable > 0 ? '，$unavailable 张暂不可读取' : ''}',
        );
      }
    });
  }

  Future<void> _export() => _run('准备完整备份', () async {
    final file = File('${c.temporary.path}/shiri-${newId()}.shiri');
    try {
      await ArchiveService(c.repository).exportTo(file);
      final saved = await c.native.exportFile(file);
      if (saved) {
        await c.repository.markBackedUp();
        _message('完整备份已导出');
      }
    } finally {
      if (await file.exists()) await file.delete();
    }
  });
  Future<void> _import() => _run('检查备份', () async {
    final path = await c.native.importFile();
    if (path == null) return;
    final file = File(path);
    try {
      if (mounted) await previewAndImport(context, c, file);
    } finally {
      if (await file.exists()) await file.delete();
    }
  });

  Future<void> _widgets() async {
    await c.syncWidgets();
    if (!mounted) return;
    if (Platform.isAndroid) {
      try {
        if (await c.native.requestPinWidget()) {
          _message('请在桌面确认添加小组件');
          return;
        }
      } catch (_) {
        /* Launcher may not support pinning; system instructions follow. */
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('添加桌面小组件'),
        content: Text(
          Platform.isIOS
              ? '长按桌面空白处，选择“编辑”或“＋”，搜索“拾日”并添加。小组件可显示倒计时、已过天数与用户封面；编辑小组件可选择纪念日。'
              : '长按桌面空白处，打开“小组件”，找到“拾日”并拖到桌面。可调整尺寸，添加时选择纪念日。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _openPhotos({int? year, bool pending = false, bool selecting = false}) {
    if (c.selected == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoPage(
          controller: c,
          eventId: c.selected!.id,
          year: year,
          pending: pending,
          selecting: selecting,
        ),
      ),
    );
  }

  Widget _eventSelector({Color? color, Key? textKey}) => TextButton(
    key: const ValueKey('event-selector'),
    onPressed: _busy ? null : _chooseEvent,
    style: TextButton.styleFrom(
      foregroundColor: color ?? ShiriTheme.albumInk,
      padding: EdgeInsets.zero,
      alignment: Alignment.centerLeft,
      minimumSize: const Size(48, 48),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            c.selected?.title ?? '选择纪念日',
            key: textKey,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(width: 5),
        const Icon(Icons.keyboard_arrow_down, size: 22),
      ],
    ),
  );

  Widget _home() {
    final event = c.selected!;
    final progress = c.progress!;
    final top = MediaQuery.paddingOf(context).top;
    final cover = c.coverFor(event);
    return LayoutBuilder(
      key: const ValueKey('anniversary-home'),
      builder: (context, constraints) {
        final minimumHeight =
            320.0 +
            top +
            (MediaQuery.textScalerOf(context).scale(17) - 17).clamp(0.0, 50.0) *
                7;
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            AdaptiveCover(
              file: cover,
              textKeys: [_heroNumber, _heroUnit, _heroAnniversary],
              height: math.max(minimumHeight, constraints.maxHeight - 112),
              onInk: c.coverContrast,
              builder: (context, ink) => Padding(
                padding: EdgeInsets.fromLTRB(22, top + 12, 22, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              !event.repeatYearly &&
                                      event.startDate.compareTo(c.clock()) < 0
                                  ? '${progress.elapsedDays}'
                                  : '${progress.countdownDays}',
                              key: _heroNumber,
                              style: TextStyle(
                                fontSize: 110,
                                height: .98,
                                fontWeight: FontWeight.w300,
                                color: ink,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          !event.repeatYearly &&
                                  event.startDate.compareTo(c.clock()) < 0
                              ? '天前'
                              : '天后',
                          key: _heroUnit,
                          style: TextStyle(fontSize: 26, color: ink),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (event.repeatYearly)
                      Text(
                        '${progress.anniversaryNumber}周年',
                        key: _heroAnniversary,
                        style: TextStyle(fontSize: 26, color: ink),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: '已经走过 '),
                    TextSpan(
                      text: groupedNumber(progress.elapsedDays),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const TextSpan(text: ' 天'),
                  ],
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _album() {
    final groups = <int, List<MemoryPhoto>>{};
    for (final p in c.photos) {
      groups.putIfAbsent(c.photoYear(p), () => []).add(p);
    }
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          Row(
            children: [
              Expanded(child: _eventSelector()),
              IconButton(
                tooltip: '管理纪念日',
                onPressed: _busy ? null : _manageAlbum,
                icon: const Icon(Icons.more_horiz),
              ),
              TextButton(
                onPressed: _busy ? null : _collectPhotos,
                child: const Text('归集'),
              ),
              IconButton(
                tooltip: '手动添加照片',
                onPressed: _busy ? null : _pickPhotos,
                icon: const Icon(Icons.add_photo_alternate_outlined),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (c.photoAccess != null &&
              c.photoAccess != 'full' &&
              c.photoAccess != 'notDetermined')
            Row(
              children: [
                Expanded(
                  child: Text(
                    c.photoAccess == 'limited' ? '仅已授权照片' : '未允许读取相册',
                    style: const TextStyle(
                      color: ShiriTheme.albumMuted,
                      fontSize: 14,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : _openPhotoSettings,
                  child: const Text('相册权限'),
                ),
              ],
            ),
          Row(
            children: [
              Text(
                '${c.photos.length}张',
                style: const TextStyle(
                  color: ShiriTheme.albumMuted,
                  fontSize: 16,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: c.photos.isEmpty
                    ? null
                    : () => _openPhotos(selecting: true),
                child: const Text('多选'),
              ),
              if (c.pending.isNotEmpty)
                TextButton(
                  onPressed: c.pending.isEmpty
                      ? null
                      : () => _openPhotos(pending: true),
                  child: Text('待确认${c.pending.length}张 ›'),
                ),
            ],
          ),
          const Divider(),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 70),
              child: Column(
                children: [
                  const Icon(
                    Icons.photo_library_outlined,
                    size: 44,
                    color: ShiriTheme.albumMuted,
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _busy ? null : _collectPhotos,
                    child: const Text('归集照片'),
                  ),
                ],
              ),
            ),
          ...groups.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(top: 28),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 5,
                          children: [
                            Text(
                              '${entry.key}',
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w500,
                                color: ShiriTheme.albumInk,
                              ),
                            ),
                            Text(
                              '· ${c.selected!.startDate.month.toString().padLeft(2, '0')}.${c.selected!.startDate.day.toString().padLeft(2, '0')}',
                              style: const TextStyle(
                                fontSize: 17,
                                color: ShiriTheme.albumMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => _openPhotos(year: entry.key),
                        child: Text('${entry.value.length}张 ›'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: List.generate(
                      3,
                      (index) => Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(right: index == 2 ? 0 : 2),
                          child: index >= entry.value.length
                              ? const AspectRatio(aspectRatio: 1.3)
                              : InkWell(
                                  onTap: () => _openPhotos(year: entry.key),
                                  child: AspectRatio(
                                    aspectRatio: 1.3,
                                    child: Image.file(
                                      c.repository.thumbnailFile(
                                        entry.value[index],
                                      ),
                                      fit: BoxFit.cover,
                                      cacheWidth: 480,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.broken_image_outlined,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _data() => SafeArea(
    bottom: false,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 38, 20, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${c.state.events.length}个纪念日 · ${c.state.photos.length}张照片',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              byteLabel(c.state.mediaBytes),
              style: const TextStyle(color: ShiriTheme.muted),
            ),
          ],
        ),
        const SizedBox(height: 40),
        Row(
          children: [
            const Text('备份', style: TextStyle(color: ShiriTheme.muted)),
            const Spacer(),
            Text(
              c.state.lastBackupAt == null
                  ? '尚未备份'
                  : '已备份 ${dateLabel(CalendarDate.fromDateTime(c.state.lastBackupAt!.toLocal()).iso)}',
              style: const TextStyle(color: ShiriTheme.muted, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _export,
          icon: const Icon(Icons.ios_share),
          label: const Text('导出完整备份'),
        ),
        const SizedBox(height: 14),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_download_outlined),
          title: const Text('导入备份'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _import,
        ),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 28),
        const Text('附近互传', style: TextStyle(color: ShiriTheme.muted)),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.send_to_mobile),
          title: const Text('发送资料'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : () => _transfer(false),
        ),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.mobile_friendly),
          title: const Text('接收资料'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : () => _transfer(true),
        ),
        const SizedBox(height: 28),
        const Divider(),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.widgets_outlined),
          title: const Text('桌面小组件'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _widgets,
        ),
      ],
    ),
  );
  void _transfer(bool receive) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TransferPage(controller: c, receive: receive),
    ),
  );

  Widget _empty({bool minimal = false}) => minimal
      ? const Center(
          child: Text('在相册中添加纪念日', style: TextStyle(color: ShiriTheme.muted)),
        )
      : SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.calendar_month_outlined,
                    size: 54,
                    color: ShiriTheme.accent,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '从一个重要的日子开始',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => _editEvent(),
                    icon: const Icon(Icons.add),
                    label: const Text('添加纪念日'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(onPressed: _import, child: const Text('导入备份')),
                ],
              ),
            ),
          ),
        );

  @override
  Widget build(BuildContext context) => Theme(
    data: _tab == 1 ? ShiriTheme.album : ShiriTheme.light,
    child: Scaffold(
      body: Stack(
        children: [
          if (c.selected == null && _tab != 2)
            _empty(minimal: _tab == 0)
          else
            switch (_tab) {
              0 => _home(),
              1 => _album(),
              _ => _data(),
            },
          if (_busy)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Material(
                color: Colors.white,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const LinearProgressIndicator(minHeight: 2),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _task,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          if (_task.contains('照片'))
                            TextButton(
                              onPressed: c.cancelScan
                                  ? null
                                  : () {
                                      c.cancelScan = true;
                                      setState(() => _task = '正在停止归集照片');
                                    },
                              child: const Text('停止归集'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: ShiriTheme.rule, width: .7)),
        ),
        child: BottomNavigationBar(
          currentIndex: _tab,
          showSelectedLabels: _tab != 0,
          showUnselectedLabels: _tab != 0,
          onTap: _activateTab,
          elevation: 0,
          backgroundColor: Colors.white,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: _tab == 1
              ? ShiriTheme.albumAccent
              : ShiriTheme.ink,
          unselectedItemColor: _tab == 1
              ? ShiriTheme.albumMuted
              : ShiriTheme.muted,
          selectedFontSize: 12,
          unselectedFontSize: 12,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.calendar_month_outlined),
              label: '纪念日',
              tooltip: '纪念日',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.photo_library_outlined),
              label: '相册',
              tooltip: '相册',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.layers_outlined),
              label: '数据',
              tooltip: '数据',
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> previewAndImport(
  BuildContext context,
  AppController c,
  File file,
) async {
  final archive = ArchiveService(c.repository);
  final preview = await archive.previewImport(file);
  try {
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('导入预览'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '新增 ${preview.newEvents} 个纪念日\n新增 ${preview.newPhotos} 张照片\n重复 ${preview.duplicatePhotos} 张照片',
              ),
              if (preview.conflicts.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('冲突保留本机内容'),
                ...preview.conflicts
                    .take(6)
                    .map(
                      (e) => Text(
                        e,
                        style: const TextStyle(
                          fontSize: 13,
                          color: ShiriTheme.muted,
                        ),
                      ),
                    ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('合并导入'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await archive.applyImport(preview);
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已合并到本机资料')));
    }
  } finally {
    await preview.dispose();
  }
}
