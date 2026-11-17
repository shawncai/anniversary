import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/calendar.dart';
import '../core/cover.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../platform/native_platform.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.repository,
    required this.native,
    required this.temporary,
    CalendarDate Function()? clock,
    DateTime Function()? time,
  }) : clock = clock ?? CalendarDate.today,
       time = time ?? DateTime.now {
    _subscription = repository.changes.listen((_) {
      notifyListeners();
      _queueWidgetSync();
      unawaited(syncSavedReminders());
    });
  }
  final LibraryRepository repository;
  final NativePlatform native;
  final Directory temporary;
  final CalendarDate Function() clock;
  final DateTime Function() time;
  final Map<String, String> reminderStatus = {};
  final Map<String, String> _reminderSignatures = {};
  Future<void> _reminderTail = Future.value();
  late final StreamSubscription<LibraryState> _subscription;
  Future<void> _widgetTail = Future.value();
  final Map<String, bool> _coverLight = {};
  bool _closed = false;
  bool cancelScan = false;
  bool _scanning = false;
  bool get scanningPhotos => _scanning;
  String? photoAccess;
  String? widgetError;
  LibraryState get state => repository.state;
  Anniversary? get selected => state.selectedEvent;
  List<MemoryPhoto> get photos =>
      selected == null ? [] : state.photosFor(selected!.id);
  List<MemoryPhoto> get pending => selected == null
      ? []
      : state.photosFor(selected!.id, status: AssociationStatus.pending);
  AnniversaryProgress? get progress => selected == null
      ? null
      : anniversaryProgress(
          selected!.startDate,
          today: clock(),
          repeatYearly: selected!.repeatYearly,
        );

  int photoYear(MemoryPhoto photo, {String? eventId}) {
    final matches = state.events.where((e) => e.id == eventId);
    final event = eventId == null || matches.isEmpty ? selected : matches.first;
    if (event == null) return photo.date.year;
    return anniversaryYearForPhoto(
      photo.date,
      event.startDate,
      windowDays: event.windowDays,
    );
  }

  final _displayCovers =
      <String, ({int revision, int step, MemoryPhoto? photo})>{};
  MemoryPhoto? displayedCover(Anniversary? event) {
    if (event == null) return null;
    final now = time();
    final local = now.toLocal();
    final step = switch (event.coverMode) {
      CoverMode.fixed => 0,
      CoverMode.daily =>
        CalendarDate.fromDateTime(local).daysSince(CalendarDate(1970, 1, 1)) -
            (local.hour * 60 + local.minute < event.coverChangeMinute ? 1 : 0),
      _ => now.millisecondsSinceEpoch ~/ (event.coverIntervalSeconds * 1000),
    };
    final cached = _displayCovers[event.id];
    if (cached != null &&
        cached.revision == repository.revision &&
        cached.step == step)
      return cached.photo;
    final photo = coverPhoto(state, event, now);
    _displayCovers[event.id] = (
      revision: repository.revision,
      step: step,
      photo: photo,
    );
    return photo;
  }

  File? coverFor(Anniversary? event) {
    final photo = displayedCover(event);
    return photo == null ? null : repository.thumbnailFile(photo);
  }

  Future<List<Anniversary>> takeDayReminders() async {
    final due = state.events.where((e) => reminderIsToday(e, clock())).toList();
    if (due.isEmpty) return [];
    final ids = await native.takeDayReminders(
      due.map((e) => e.id).toList(),
      clock().iso,
    );
    return due.where((e) => ids.contains(e.id)).toList();
  }

  Future<void> syncSavedReminders({bool refresh = false}) async {
    for (final event in state.events) {
      if (_closed) return;
      final signature =
          '${event.title}:${event.startDate.iso}:${event.repeatYearly}:${event.reminderEnabled}:${event.reminderMinute}';
      if (!refresh && _reminderSignatures[event.id] == signature) continue;
      _reminderSignatures[event.id] = signature;
      if (event.reminderEnabled || reminderStatus.containsKey(event.id)) {
        await syncReminder(event, request: false);
      }
    }
  }

  Future<String?> syncReminder(Anniversary event, {bool request = true}) {
    final result = _reminderTail.then((_) async {
      if (_closed) return null;
      try {
        final current =
            state.events.where((e) => e.id == event.id).firstOrNull ?? event;
        final status = await native.syncReminder(current, request: request);
        reminderStatus[event.id] = status;
        if (!_closed) notifyListeners();
        return status;
      } on PlatformException catch (error) {
        final status = error.message ?? '提醒尚未设置，请重试';
        reminderStatus[event.id] = status;
        if (!_closed) notifyListeners();
        return status;
      }
    });
    _reminderTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> select(String id) => repository.selectEvent(id);
  Future<void> saveEvent(Anniversary event) async {
    await repository.saveEvent(event);
    await repository.selectEvent(event.id);
    await syncReminder(event);
  }

  Future<void> setCover(MemoryPhoto photo) async {
    final event = selected;
    if (event != null)
      await repository.saveEvent(
        event.copyWith(coverPhotoId: photo.id, coverMode: CoverMode.fixed),
      );
  }

  void coverContrast(bool light) {
    final id = displayedCover(selected)?.id;
    if (id == null || _coverLight[id] == light) return;
    _coverLight[id] = light;
    _queueWidgetSync();
  }

  Future<int> addPhotos() async {
    final event = selected;
    if (event == null) throw const FormatException('先添加一个纪念日');
    final inputs = await native.pickPhotos();
    if (inputs == null || inputs.isEmpty) return 0;
    final count = await repository.ingestPhotos(event.id, inputs);
    if (event.coverPhotoId == null) {
      final first = state.photosFor(event.id).firstOrNull;
      if (first != null)
        await repository.saveEvent(event.copyWith(coverPhotoId: first.id));
    }
    return count;
  }

  Future<(int, int)> scanPhotos({
    required void Function(int) onProgress,
  }) async {
    final event = selected;
    if (event == null) throw const FormatException('先添加一个纪念日');
    if (_scanning) throw const FormatException('正在读取相册，请稍候');
    _scanning = true;
    cancelScan = false;
    try {
      var permission = await native.photoPermission();
      if (permission == 'notDetermined' && !_closed && !cancelScan) {
        permission = await native.photoPermission(request: true);
      }
      if (!_closed) {
        photoAccess = permission;
        notifyListeners();
      }
      if (permission != 'full' && permission != 'limited') return (0, 0);
      var offset = 0;
      var added = 0;
      var unavailable = 0;
      while (!cancelScan && !_closed) {
        final page = await native.scanPhotos(event, offset);
        try {
          if (cancelScan || _closed) break;
          final relevant = page.items
              .where(
                (p) => isPhotoInAnniversaryWindow(
                  CalendarDate.fromDateTime(p.capturedAt.toLocal()),
                  event.startDate,
                  windowDays: event.windowDays,
                ),
              )
              .toList();
          if (relevant.isNotEmpty) {
            added += await repository.ingestPhotos(
              event.id,
              relevant,
              automatic: true,
            );
            // Read the latest event so scanning cannot restore an old title or date.
            final current = state.events
                .where((e) => e.id == event.id)
                .firstOrNull;
            final first = state.photosFor(event.id).firstOrNull;
            if (current != null &&
                current.coverPhotoId == null &&
                first != null) {
              await repository.saveEvent(
                current.copyWith(coverPhotoId: first.id),
              );
            }
          }
        } finally {
          await repository.discardPhotoInputs(page.items);
        }
        unavailable += page.unavailable;
        onProgress(added);
        final next = page.nextOffset;
        if (next == null) break;
        if (next <= offset) throw const FormatException('相册扫描未能继续，请稍后重试');
        offset = next;
      }
      return (added, unavailable);
    } finally {
      _scanning = false;
    }
  }

  Future<bool> refreshPhotoAccess() async {
    final value = await native.photoPermission();
    if (_closed || photoAccess == value) return false;
    photoAccess = value;
    notifyListeners();
    return true;
  }

  Future<void> confirm(Iterable<String> ids) async {
    final event = selected;
    if (event == null) return;
    await repository.confirmPhotos(event.id, ids);
    if (event.coverPhotoId == null) {
      final first = state.photosFor(event.id).firstOrNull;
      if (first != null)
        await repository.saveEvent(event.copyWith(coverPhotoId: first.id));
    }
  }

  Map<String, dynamic> widgetSnapshot() => {
    'version': 1,
    'selectedEventId': state.selectedEventId,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'events': state.events
        .map(
          (e) => {
            'id': e.id,
            'title': e.title,
            'startDate': e.startDate.iso,
            'repeatYearly': e.repeatYearly,
            'coverPath': coverFor(e)?.path,
            'lightText': _coverLight[displayedCover(e)?.id] ?? true,
          },
        )
        .toList(),
  };
  void _queueWidgetSync() {
    if (_closed) return;
    _widgetTail = _widgetTail.then((_) async {
      if (_closed) return;
      try {
        await native.updateWidgets(widgetSnapshot(), coverFor(selected)?.path);
        widgetError = null;
      } catch (error) {
        widgetError = error is PlatformException
            ? error.message
            : error.toString();
      }
    });
  }

  Future<void> syncWidgets() async {
    _queueWidgetSync();
    await _widgetTail;
  }

  Future<void> handleLink(String value) async {
    final uri = Uri.tryParse(value);
    if (uri?.scheme != 'shiri' ||
        uri?.host != 'anniversary' ||
        uri!.pathSegments.isEmpty)
      return;
    final id = uri.pathSegments.first;
    if (state.events.any((e) => e.id == id)) await select(id);
  }

  Future<void> close() async {
    _closed = true;
    cancelScan = true;
    await _subscription.cancel();
    await _widgetTail;
    await _reminderTail;
    await repository.close();
    await native.dispose();
    super.dispose();
  }
}
