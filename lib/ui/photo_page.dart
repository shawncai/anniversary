import 'package:flutter/material.dart';

import '../core/calendar.dart';
import '../core/models.dart';
import 'app_controller.dart';
import 'photo_selection_mark.dart';
import 'theme.dart';

class PhotoPage extends StatefulWidget {
  const PhotoPage({
    super.key,
    required this.controller,
    required this.eventId,
    this.year,
    this.pending = false,
    this.selecting = false,
  });
  final AppController controller;
  final String eventId;
  final int? year;
  final bool pending;
  final bool selecting;
  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage> {
  final _selected = <String>{};
  bool _saving = false;
  late bool _selecting = widget.pending || widget.selecting;

  Future<void> _operate(String action) async {
    final ids = _selected.toSet();
    final c = widget.controller;
    if (ids.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      if (action == 'remove') {
        final yes = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text('移出 ${ids.length} 张照片？'),
            content: const Text('原图保留在本机和系统相册，自动归集不会再次加入。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('执行移出'),
              ),
            ],
          ),
        );
        if (yes != true) return;
        await c.repository.removeAssociations(widget.eventId, ids);
      } else if (action == 'add') {
        final targets = c.state.events
            .where((e) => e.id != widget.eventId)
            .toList();
        if (targets.isEmpty) {
          if (mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('请先添加另一个纪念日')));
          return;
        }
        final target = await showModalBottomSheet<String>(
          context: context,
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(),
          builder: (sheet) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: targets
                  .map(
                    (e) => ListTile(
                      title: Text(e.title),
                      onTap: () => Navigator.pop(sheet, e.id),
                    ),
                  )
                  .toList(),
            ),
          ),
        );
        if (target == null) return;
        await c.repository.associatePhotos(target, ids);
      } else if (action == 'cover') {
        final event = c.state.events.firstWhere((e) => e.id == widget.eventId);
        await c.repository.saveEvent(
          event.copyWith(
            coverMode: ids.length == 1 ? CoverMode.fixed : CoverMode.slideshow,
            coverPhotoId: ids.first,
            coverPhotoIds: ids.toList(),
            coverSource: CoverSource.selection,
            coverIntervalSeconds: 10,
          ),
        );
      } else {
        await c.repository.confirmPhotos(widget.eventId, ids);
      }
      if (mounted) {
        setState(() {
          _selected.clear();
          _selecting = widget.pending;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (action) {
              'cover' => ids.length == 1 ? '已设为固定封面' : '已设为轮播封面组',
              'add' => '已加入纪念日',
              'remove' => '已移出',
              _ => '照片已归集',
            }),
          ),
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlbumTheme(
    child: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final photos = c.state
            .photosFor(
              widget.eventId,
              status: widget.pending
                  ? AssociationStatus.pending
                  : AssociationStatus.confirmed,
            )
            .where(
              (p) =>
                  widget.year == null ||
                  c.photoYear(p, eventId: widget.eventId) == widget.year,
            )
            .toList();
        _selected.retainAll(photos.map((p) => p.id));
        return Scaffold(
          appBar: AppBar(
            title: Text(
              _selecting
                  ? '已选 ${_selected.length} 张'
                  : '${widget.year ?? ''} ${photos.length}张',
            ),
            actions: [
              if (_selecting)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          if (_selected.length == photos.length) {
                            _selected.clear();
                          } else {
                            _selected.addAll(photos.map((p) => p.id));
                          }
                        }),
                  child: Text(
                    _selected.length == photos.length && photos.isNotEmpty
                        ? '取消全选'
                        : '全选',
                  ),
                ),
              if (!widget.pending)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _selecting = !_selecting;
                          _selected.clear();
                        }),
                  child: Text(_selecting ? '取消' : '多选'),
                ),
            ],
          ),
          body: photos.isEmpty
              ? const Center(
                  child: Text(
                    '暂无照片',
                    style: TextStyle(color: ShiriTheme.albumMuted),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                  ),
                  itemCount: photos.length,
                  itemBuilder: (context, index) {
                    final photo = photos[index];
                    final selected = _selected.contains(photo.id);
                    return Semantics(
                      label: '${dateLabel(photo.date.iso)}拍摄的照片',
                      selected: selected,
                      child: InkWell(
                        key: ValueKey('photo-${photo.id}'),
                        onTap: _saving
                            ? null
                            : () {
                                if (_selecting) {
                                  setState(
                                    () => selected
                                        ? _selected.remove(photo.id)
                                        : _selected.add(photo.id),
                                  );
                                } else {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => PhotoDetail(
                                        controller: c,
                                        photoId: photo.id,
                                        eventId: widget.eventId,
                                      ),
                                    ),
                                  );
                                }
                              },
                        onLongPress: _saving
                            ? null
                            : () => setState(() {
                                _selecting = true;
                                _selected.add(photo.id);
                              }),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(
                              c.repository.thumbnailFile(photo),
                              fit: BoxFit.cover,
                              cacheWidth: 500,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.broken_image_outlined),
                            ),
                            if (_selecting)
                              Positioned(
                                right: 5,
                                top: 5,
                                child: PhotoSelectionMark(selected: selected),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
          bottomNavigationBar: !_selecting
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: widget.pending
                        ? FilledButton(
                            onPressed: _saving || _selected.isEmpty
                                ? null
                                : () => _operate('confirm'),
                            child: Text('归入纪念日 · ${_selected.length}张'),
                          )
                        : Row(
                            children: [
                              for (final item in [
                                ('cover', '封面组', Icons.slideshow_outlined),
                                (
                                  'add',
                                  '加入',
                                  Icons.add_photo_alternate_outlined,
                                ),
                                ('remove', '移出', Icons.remove_circle_outline),
                              ])
                                Expanded(
                                  child: TextButton(
                                    onPressed: _saving || _selected.isEmpty
                                        ? null
                                        : () => _operate(item.$1),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(item.$3),
                                        const SizedBox(height: 4),
                                        Text(item.$2),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
        );
      },
    ),
  );
}

class PhotoDetail extends StatelessWidget {
  const PhotoDetail({
    super.key,
    required this.controller,
    required this.photoId,
    required this.eventId,
    this.pending = false,
  });
  final AppController controller;
  final String photoId;
  final String eventId;
  final bool pending;
  Future<void> _action(
    BuildContext context,
    String action,
    MemoryPhoto photo,
  ) async {
    try {
      if (action == 'cover') {
        final event = controller.state.events.firstWhere(
          (e) => e.id == eventId,
        );
        await controller.repository.saveEvent(
          event.copyWith(coverPhotoId: photo.id, coverMode: CoverMode.fixed),
        );
        if (context.mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已设为封面')));
      } else if (action == 'date') {
        final d = photo.date;
        final value = await showDatePicker(
          context: context,
          initialDate: DateTime(d.year, d.month, d.day),
          firstDate: DateTime(1),
          lastDate: DateTime(9999, 12, 31),
        );
        if (value != null)
          await controller.repository.updatePhotoDate(photo.id, value);
      } else if (action == 'remove') {
        final yes = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('移出这个纪念日？'),
            content: const Text('原图保留在本机和系统相册，自动归集不会再次加入。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('执行移出'),
              ),
            ],
          ),
        );
        if (yes == true) {
          await controller.repository.removeAssociation(eventId, photo.id);
          if (context.mounted) Navigator.pop(context);
        }
      }
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => AlbumTheme(
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final photo = controller.state.photos.firstWhere(
          (p) => p.id == photoId,
        );
        return Scaffold(
          appBar: AppBar(
            title: Text(
              dateLabel(
                CalendarDate.fromDateTime(photo.capturedAt.toLocal()).iso,
              ),
            ),
            actions: [
              PopupMenuButton<String>(
                tooltip: '照片操作',
                onSelected: (action) => _action(context, action, photo),
                itemBuilder: (_) => [
                  if (!pending)
                    const PopupMenuItem(value: 'cover', child: Text('设为封面')),
                  const PopupMenuItem(value: 'date', child: Text('修改日期')),
                  const PopupMenuItem(value: 'remove', child: Text('移出此纪念日')),
                ],
              ),
            ],
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: .8,
              maxScale: 5,
              child: Image.file(
                controller.repository.thumbnailFile(photo),
                fit: BoxFit.contain,
                semanticLabel: photo.originalName,
                errorBuilder: (_, __, ___) => const Text('照片暂时无法显示'),
              ),
            ),
          ),
        );
      },
    ),
  );
}
