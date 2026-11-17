import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'models.dart';

const maxOriginalBytes = 512 * 1024 * 1024;
const maxThumbnailBytes = 16 * 1024 * 1024;
const maxLibraryJsonBytes = 32 * 1024 * 1024;

Future<String> fileSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

class MergeCounts {
  const MergeCounts({
    required this.newEvents,
    required this.newPhotos,
    required this.duplicatePhotos,
    required this.newAssociations,
    required this.conflicts,
  });
  final int newEvents;
  final int newPhotos;
  final int duplicatePhotos;
  final int newAssociations;
  final List<String> conflicts;
}

MergeCounts compareLibraries(LibraryState existing, LibraryState incoming) {
  final events = {for (final e in existing.events) e.id: e};
  final photos = {for (final p in existing.photos) p.id: p};
  final links = {for (final a in existing.associations) a.key: a};
  final conflicts = <String>[];
  for (final e in incoming.events) {
    if (events.containsKey(e.id) &&
        !sameJson(events[e.id]!.toJson(), e.toJson())) {
      conflicts.add('纪念日「${e.title}」：保留本机内容');
    }
  }
  for (final p in incoming.photos) {
    if (photos.containsKey(p.id) &&
        !sameJson(photos[p.id]!.toJson(), p.toJson())) {
      conflicts.add('照片「${p.originalName}」：保留本机日期与信息');
    }
  }
  for (final a in incoming.associations) {
    if (links.containsKey(a.key) && links[a.key]!.status != a.status) {
      conflicts.add('照片归集状态：保留本机选择');
    }
  }
  return MergeCounts(
    newEvents: incoming.events.where((e) => !events.containsKey(e.id)).length,
    newPhotos: incoming.photos.where((p) => !photos.containsKey(p.id)).length,
    duplicatePhotos: incoming.photos
        .where((p) => photos.containsKey(p.id))
        .length,
    newAssociations: incoming.associations
        .where((a) => !links.containsKey(a.key))
        .length,
    conflicts: List.unmodifiable(conflicts),
  );
}

/// App-private, content-addressed media with a single atomic metadata commit.
/// Media is durable before metadata references it; interrupted writes cannot
/// expose partially copied originals. No sample content is created automatically.
class LibraryRepository {
  LibraryRepository._(this.directory, this._state);
  final Directory directory;
  LibraryState _state;
  LibraryState get state => _state;
  int revision = 0;
  Future<void> _tail = Future.value();
  final _changes = StreamController<LibraryState>.broadcast();
  Stream<LibraryState> get changes => _changes.stream;
  bool _closed = false;

  static Future<LibraryRepository> open(Directory directory) async {
    await directory.create(recursive: true);
    for (final child in ['originals', 'thumbnails', 'imports', 'staging']) {
      await Directory('${directory.path}/$child').create(recursive: true);
    }
    final stateFile = File('${directory.path}/library.json');
    var state = LibraryState();
    if (await stateFile.exists()) {
      if (await stateFile.length() > maxLibraryJsonBytes)
        throw const FormatException('本机资料过大');
      state = LibraryState.fromJson(
        jsonObject(jsonDecode(await stateFile.readAsString())),
      );
    }
    return LibraryRepository._(directory, state);
  }

  File originalFile(MemoryPhoto photo) =>
      File('${directory.path}/${photo.originalRelativePath}');
  File thumbnailFile(MemoryPhoto photo) =>
      File('${directory.path}/${photo.thumbnailRelativePath}');

  /// Discards native-generated picker/scan copies that were not ingested.
  /// User library assets and paths outside this app's imports are never removed.
  Future<void> discardPhotoInputs(Iterable<PhotoInput> inputs) =>
      _serial(() async {
        final root = await Directory(
          '${directory.path}/imports',
        ).resolveSymbolicLinks();
        final paths = inputs
            .expand((p) => [p.originalPath, p.thumbnailPath])
            .toSet();
        for (final path in paths) {
          try {
            final file = File(path);
            if (!await file.exists()) continue;
            final resolved = await file.resolveSymbolicLinks();
            if (resolved.startsWith('$root/')) await File(resolved).delete();
          } on FileSystemException {
            /* Stale or concurrently cleaned picker copy. */
          }
        }
      });

  Future<T> _serial<T>(Future<T> Function() operation) {
    if (_closed) return Future.error(StateError('资料库已关闭'));
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _persist(LibraryState next) async {
    final bytes = utf8.encode(jsonEncode(next.toJson()));
    if (bytes.length > maxLibraryJsonBytes)
      throw const FormatException('本机资料超过限制');
    final temporary = File('${directory.path}/staging/state-${newId()}.json');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename('${directory.path}/library.json');
      _state = next;
      revision++;
      _changes.add(next);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> saveEvent(Anniversary event) => _serial(() async {
    final events = [...state.events];
    final index = events.indexWhere((e) => e.id == event.id);
    if (index < 0) {
      events.add(event);
    } else {
      events[index] = event;
    }
    await _persist(
      state.copyWith(
        events: events,
        selectedEventId: state.selectedEventId ?? event.id,
      ),
    );
  });

  Future<void> selectEvent(String id) => _serial(() async {
    if (!state.events.any((e) => e.id == id))
      throw const FormatException('纪念日不存在');
    await _persist(state.copyWith(selectedEventId: id));
  });

  Future<(String, int)> _archiveInput(
    File source,
    String kind,
    int maxBytes,
  ) async {
    // Only the native picker/scan's app-private imports are accepted.
    final importsPath = await Directory(
      '${directory.path}/imports',
    ).resolveSymbolicLinks();
    final resolved = await source.resolveSymbolicLinks();
    if (!resolved.startsWith('$importsPath/'))
      throw const FormatException('照片必须来自本机相册导入');
    final size = await source.length();
    if (size <= 0 || size > maxBytes)
      throw const FormatException('照片大小超过限制或文件为空');
    final temporary = File('${directory.path}/staging/media-${newId()}');
    try {
      await source.copy(temporary.path);
      if (await temporary.length() != size)
        throw const FormatException('复制期间照片发生变化');
      final hash = await fileSha256(temporary);
      final suffix = kind == 'originals' ? 'bin' : 'jpg';
      final target = File('${directory.path}/$kind/$hash.$suffix');
      if (await target.exists()) {
        if (await target.length() != size || await fileSha256(target) != hash) {
          throw const FormatException('本机照片校验失败');
        }
      } else {
        // Ensure original bytes reach the filesystem before the JSON commit.
        final handle = await temporary.open(mode: FileMode.append);
        try {
          await handle.flush();
        } finally {
          await handle.close();
        }
        await temporary.rename(target.path);
      }
      return (hash, size);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<int> ingestPhotos(
    String eventId,
    List<PhotoInput> inputs, {
    bool pending = false,
    bool automatic = false,
  }) => _serial(() async {
    if (!state.events.any((e) => e.id == eventId))
      throw const FormatException('纪念日不存在');
    final photos = {for (final p in state.photos) p.id: p};
    final associations = {for (final a in state.associations) a.key: a};
    final importedPaths = <String>{};
    var added = 0;
    for (final input in inputs) {
      final original = await _archiveInput(
        File(input.originalPath),
        'originals',
        maxOriginalBytes,
      );
      final thumbnail = await _archiveInput(
        File(input.thumbnailPath),
        'thumbnails',
        maxThumbnailBytes,
      );
      importedPaths.add(await File(input.originalPath).resolveSymbolicLinks());
      importedPaths.add(await File(input.thumbnailPath).resolveSymbolicLinks());
      final photo = MemoryPhoto(
        id: original.$1,
        sourceId: input.sourceId,
        capturedAt: input.capturedAt,
        originalName: input.originalName,
        mimeType: input.mimeType,
        originalHash: original.$1,
        thumbnailHash: thumbnail.$1,
        originalBytes: original.$2,
        thumbnailBytes: thumbnail.$2,
      );
      photos.putIfAbsent(photo.id, () => photo);
      final key = '$eventId:${photo.id}';
      if (automatic && associations[key]?.status == AssociationStatus.excluded)
        continue;
      if (!associations.containsKey(key)) {
        associations[key] = PhotoAssociation(
          eventId: eventId,
          photoId: photo.id,
          status: pending
              ? AssociationStatus.pending
              : AssociationStatus.confirmed,
        );
        added++;
      } else if (!pending &&
          associations[key]!.status != AssociationStatus.confirmed) {
        associations[key] = PhotoAssociation(
          eventId: eventId,
          photoId: photo.id,
          status: AssociationStatus.confirmed,
        );
        added++;
      }
    }
    await _persist(
      state.copyWith(
        photos: photos.values.toList(),
        associations: associations.values.toList(),
      ),
    );
    // These are generated picker copies, never the user's system-photo assets.
    // Remove them only after all archived media and metadata are durable.
    final importsPath = await Directory(
      '${directory.path}/imports',
    ).resolveSymbolicLinks();
    for (final path in importedPaths.where(
      (path) => path.startsWith('$importsPath/'),
    )) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        /* A successful commit remains successful. */
      }
    }
    return added;
  });

  Future<void> confirmPhotos(String eventId, Iterable<String> photoIds) =>
      _serial(() async {
        final ids = photoIds.toSet();
        final associations = state.associations
            .map(
              (a) => a.eventId == eventId && ids.contains(a.photoId)
                  ? PhotoAssociation(
                      eventId: a.eventId,
                      photoId: a.photoId,
                      status: AssociationStatus.confirmed,
                    )
                  : a,
            )
            .toList();
        await _persist(state.copyWith(associations: associations));
      });

  Future<void> updatePhotoDate(String id, DateTime capturedAt) =>
      _serial(() async {
        if (!state.photos.any((p) => p.id == id))
          throw const FormatException('照片不存在');
        await _persist(
          state.copyWith(
            photos: state.photos
                .map((p) => p.id == id ? p.withDate(capturedAt) : p)
                .toList(),
          ),
        );
      });

  /// Exclusions survive scans and backups; no original bytes are deleted.
  Future<void> removeAssociation(String eventId, String photoId) =>
      removeAssociations(eventId, [photoId]);

  Future<void> removeAssociations(String eventId, Iterable<String> photoIds) =>
      _serial(() async {
        final ids = photoIds.toSet();
        final events = state.events
            .map(
              (e) => e.id != eventId
                  ? e
                  : e.copyWith(
                      clearCover: ids.contains(e.coverPhotoId),
                      coverPhotoIds: e.coverPhotoIds
                          .where((id) => !ids.contains(id))
                          .toList(),
                    ),
            )
            .toList();
        await _persist(
          state.copyWith(
            events: events,
            associations: state.associations
                .map(
                  (a) => a.eventId == eventId && ids.contains(a.photoId)
                      ? PhotoAssociation(
                          eventId: a.eventId,
                          photoId: a.photoId,
                          status: AssociationStatus.excluded,
                        )
                      : a,
                )
                .toList(),
          ),
        );
      });

  Future<void> associatePhotos(String eventId, Iterable<String> photoIds) =>
      _serial(() async {
        if (!state.events.any((e) => e.id == eventId))
          throw const FormatException('纪念日不存在');
        final ids = photoIds.toSet();
        final known = state.photos.map((p) => p.id).toSet();
        if (!known.containsAll(ids)) throw const FormatException('照片不存在');
        final links = {for (final a in state.associations) a.key: a};
        for (final id in ids) {
          final a = PhotoAssociation(
            eventId: eventId,
            photoId: id,
            status: AssociationStatus.confirmed,
          );
          links[a.key] = a;
        }
        await _persist(state.copyWith(associations: links.values.toList()));
      });

  Future<void> markBackedUp() =>
      _serial(() => _persist(state.copyWith(lastBackupAt: DateTime.now())));

  /// Used only after full archive validation. Merge is re-evaluated under the
  /// repository lock, so concurrent UI edits are always retained.
  Future<MergeCounts> mergeValidated(
    LibraryState incoming,
    Directory staging,
  ) => _serial(() async {
    final counts = compareLibraries(state, incoming);
    final photos = {for (final p in state.photos) p.id: p};
    final events = {for (final e in state.events) e.id: e};
    final associations = {for (final a in state.associations) a.key: a};
    for (final p in incoming.photos) {
      if (photos.containsKey(p.id)) continue;
      for (final item in [
        (p.originalRelativePath, p.originalHash, p.originalBytes),
        (p.thumbnailRelativePath, p.thumbnailHash, p.thumbnailBytes),
      ]) {
        final source = File('${staging.path}/${item.$1}');
        if (await source.length() != item.$3 ||
            await fileSha256(source) != item.$2) {
          throw const FormatException('待导入照片校验失败');
        }
        final target = File('${directory.path}/${item.$1}');
        if (await target.exists()) {
          if (await target.length() != item.$3 ||
              await fileSha256(target) != item.$2) {
            throw const FormatException('本机照片校验失败');
          }
        } else {
          final pending = File('${directory.path}/staging/merge-${newId()}');
          try {
            await source.copy(pending.path);
            final handle = await pending.open(mode: FileMode.append);
            try {
              await handle.flush();
            } finally {
              await handle.close();
            }
            await pending.rename(target.path);
          } finally {
            if (await pending.exists()) await pending.delete();
          }
        }
      }
      photos[p.id] = p;
    }
    for (final e in incoming.events) {
      events.putIfAbsent(e.id, () => e);
    }
    for (final a in incoming.associations) {
      associations.putIfAbsent(a.key, () => a);
    }
    final merged = LibraryState(
      events: events.values.toList(),
      photos: photos.values.toList(),
      associations: associations.values.toList(),
      selectedEventId:
          state.selectedEventId ??
          incoming.selectedEventId ??
          (events.isEmpty ? null : events.keys.first),
      lastBackupAt: state.lastBackupAt,
    );
    await _persist(merged);
    return counts;
  });

  Future<void> close() async {
    _closed = true;
    await _tail;
    await _changes.close();
  }
}
