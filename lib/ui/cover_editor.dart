import 'package:flutter/material.dart';

import '../core/models.dart';
import 'app_controller.dart';
import 'photo_selection_mark.dart';
import 'theme.dart';

class CoverEditor extends StatefulWidget {
  const CoverEditor({
    super.key,
    required this.controller,
    required this.eventId,
  });
  final AppController controller;
  final String eventId;
  @override
  State<CoverEditor> createState() => _CoverEditorState();
}

class _CoverEditorState extends State<CoverEditor> {
  late Anniversary _draft;
  final _ids = <String>{};
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _draft = widget.controller.state.events.firstWhere(
      (e) => e.id == widget.eventId,
    );
    _ids.addAll(_draft.coverPhotoIds);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Merge settings into the latest event; scans and edits may have committed.
      final current = widget.controller.state.events.firstWhere(
        (e) => e.id == widget.eventId,
      );
      await widget.controller.repository.saveEvent(
        current.copyWith(
          coverMode: _draft.coverMode,
          coverSource: _draft.coverSource,
          coverYear: _draft.coverYear,
          coverPhotoId: _draft.coverPhotoId,
          coverPhotoIds: _ids.toList(),
          coverIntervalSeconds: _draft.coverIntervalSeconds,
          coverChangeMinute: _draft.coverChangeMinute,
        ),
      );
      if (mounted) Navigator.pop(context);
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
  Widget build(BuildContext context) {
    final c = widget.controller;
    final photos = c.state.photosFor(widget.eventId);
    final years =
        photos
            .map((p) => c.photoYear(p, eventId: widget.eventId))
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
    final fixed = _draft.coverMode == CoverMode.fixed;
    final choose = fixed || _draft.coverSource == CoverSource.selection;
    final valid = fixed
        ? photos.any((p) => p.id == _draft.coverPhotoId)
        : _draft.coverSource == CoverSource.selection
        ? _ids.isNotEmpty
        : _draft.coverSource == CoverSource.year
        ? years.contains(_draft.coverYear)
        : photos.isNotEmpty;
    return AlbumTheme(
      child: Scaffold(
        appBar: AppBar(
          actions: [
            TextButton(
              onPressed: _saving || !valid ? null : _save,
              child: const Text('保存'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            DropdownButtonFormField<CoverMode>(
              value: _draft.coverMode,
              decoration: const InputDecoration(labelText: '封面展示'),
              items: const [
                DropdownMenuItem(value: CoverMode.fixed, child: Text('固定照片')),
                DropdownMenuItem(
                  value: CoverMode.slideshow,
                  child: Text('自动轮播'),
                ),
                DropdownMenuItem(value: CoverMode.daily, child: Text('每天定时换图')),
                DropdownMenuItem(
                  value: CoverMode.interval,
                  child: Text('按间隔换图'),
                ),
              ],
              onChanged: _saving
                  ? null
                  : (v) => setState(
                      () => _draft = _draft.copyWith(
                        coverMode: v,
                        coverIntervalSeconds: v == CoverMode.interval
                            ? 3600
                            : 10,
                      ),
                    ),
            ),
            if (!fixed) ...[
              const SizedBox(height: 20),
              DropdownButtonFormField<CoverSource>(
                value: _draft.coverSource,
                decoration: const InputDecoration(labelText: '照片来源'),
                items: const [
                  DropdownMenuItem(value: CoverSource.all, child: Text('全部照片')),
                  DropdownMenuItem(
                    value: CoverSource.year,
                    child: Text('按年份选择'),
                  ),
                  DropdownMenuItem(
                    value: CoverSource.selection,
                    child: Text('自选照片组'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(
                        () => _draft = _draft.copyWith(
                          coverSource: v,
                          coverYear: _draft.coverYear ?? years.firstOrNull,
                        ),
                      ),
              ),
              if (_draft.coverSource == CoverSource.year) ...[
                const SizedBox(height: 20),
                DropdownButtonFormField<int>(
                  value: years.contains(_draft.coverYear)
                      ? _draft.coverYear
                      : null,
                  decoration: const InputDecoration(labelText: '年份'),
                  items: years
                      .map((y) => DropdownMenuItem(value: y, child: Text('$y')))
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (v) => setState(
                          () => _draft = _draft.copyWith(coverYear: v),
                        ),
                ),
              ],
              const SizedBox(height: 20),
              if (_draft.coverMode == CoverMode.daily)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('每天换图时间'),
                  trailing: Text(
                    TimeOfDay(
                      hour: _draft.coverChangeMinute ~/ 60,
                      minute: _draft.coverChangeMinute % 60,
                    ).format(context),
                  ),
                  onTap: _saving
                      ? null
                      : () async {
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay(
                              hour: _draft.coverChangeMinute ~/ 60,
                              minute: _draft.coverChangeMinute % 60,
                            ),
                          );
                          if (time != null && mounted)
                            setState(
                              () => _draft = _draft.copyWith(
                                coverChangeMinute: time.hour * 60 + time.minute,
                              ),
                            );
                        },
                )
              else
                DropdownButtonFormField<int>(
                  value: _draft.coverIntervalSeconds,
                  decoration: const InputDecoration(labelText: '换图间隔'),
                  items:
                      ({
                            ...(_draft.coverMode == CoverMode.slideshow
                                ? [5, 10, 30]
                                : [60, 300, 1800, 3600, 21600, 43200]),
                            _draft.coverIntervalSeconds,
                          }.toList()..sort())
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text(
                                v < 60
                                    ? '$v 秒'
                                    : v < 3600
                                    ? '${v ~/ 60} 分钟'
                                    : '${v ~/ 3600} 小时',
                              ),
                            ),
                          )
                          .toList(),
                  onChanged: _saving
                      ? null
                      : (v) => setState(
                          () =>
                              _draft = _draft.copyWith(coverIntervalSeconds: v),
                        ),
                ),
            ],
            if (choose) ...[
              const SizedBox(height: 24),
              if (!fixed)
                Row(
                  children: [
                    Text('已选 ${_ids.length} 张'),
                    const Spacer(),
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                              if (_ids.length == photos.length) {
                                _ids.clear();
                              } else {
                                _ids.addAll(photos.map((p) => p.id));
                              }
                            }),
                      child: Text(_ids.length == photos.length ? '取消全选' : '全选'),
                    ),
                  ],
                ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                ),
                itemCount: photos.length,
                itemBuilder: (context, index) {
                  final photo = photos[index];
                  final selected = fixed
                      ? photo.id == _draft.coverPhotoId
                      : _ids.contains(photo.id);
                  return InkWell(
                    onTap: _saving
                        ? null
                        : () => setState(() {
                            if (fixed) {
                              _draft = _draft.copyWith(coverPhotoId: photo.id);
                            } else if (!_ids.add(photo.id)) {
                              _ids.remove(photo.id);
                            }
                          }),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          c.repository.thumbnailFile(photo),
                          fit: BoxFit.cover,
                          cacheWidth: 400,
                        ),
                        Positioned(
                          top: 5,
                          right: 5,
                          child: PhotoSelectionMark(selected: selected),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
            if (photos.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: Text('先在相册中添加照片')),
              ),
          ],
        ),
      ),
    );
  }
}
