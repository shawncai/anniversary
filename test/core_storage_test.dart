import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anniversary/core/core.dart';

void main() {
  late Directory temporary;
  final opened = <LibraryRepository>[];
  Future<LibraryRepository> repository(String name) async {
    final result = await LibraryRepository.open(
      Directory('${temporary.path}/$name'),
    );
    opened.add(result);
    return result;
  }

  Future<PhotoInput> photoInput(
    LibraryRepository repo, {
    String name = 'photo',
    int bytes = 150000,
  }) async {
    final original = File('${repo.directory.path}/imports/$name.heic');
    final thumbnail = File('${repo.directory.path}/imports/$name.jpg');
    await original.writeAsBytes(List.generate(bytes, (index) => index % 251));
    await thumbnail.writeAsBytes([1, 2, 3, 4, 5, 6]);
    return PhotoInput(
      sourceId: name,
      originalPath: original.path,
      thumbnailPath: thumbnail.path,
      capturedAt: DateTime(2025, 11, 20, 14),
      originalName: '$name.heic',
      mimeType: 'image/heic',
    );
  }

  final event = Anniversary(
    id: 'event-a',
    title: '在一起',
    startDate: CalendarDate(2022, 11, 20),
  );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('shiri-core-');
  });
  tearDown(() async {
    for (final repo in opened) {
      await repo.close();
    }
    opened.clear();
    await temporary.delete(recursive: true);
  });

  test(
    'empty library stays empty; state edits survive reopen and serialize',
    () async {
      final repo = await repository('a');
      expect(repo.state.events, isEmpty);
      expect(repo.state.photos, isEmpty);
      await repo.saveEvent(event);
      await repo.saveEvent(event.copyWith(title: '我们的纪念日'));
      final reopened = await repository('a');
      expect(reopened.state.events.single.title, '我们的纪念日');
      expect(reopened.state.selectedEventId, event.id);
      expect(
        LibraryState.fromJson(reopened.state.toJson()).events.single.startDate,
        event.startDate,
      );
      expect(
        (await Directory('${repo.directory.path}/staging').list().toList()),
        isEmpty,
      );
    },
  );

  test(
    'original bytes deduplicate and pending never downgrades confirmed',
    () async {
      final repo = await repository('a');
      await repo.saveEvent(event);
      final input = await photoInput(repo);
      expect(await repo.ingestPhotos(event.id, [input], pending: true), 1);
      expect(repo.state.photosFor(event.id), isEmpty);
      expect(
        repo.state.photosFor(event.id, status: AssociationStatus.pending),
        hasLength(1),
      );
      await repo.confirmPhotos(event.id, [repo.state.photos.single.id]);
      await repo.ingestPhotos(event.id, [
        await photoInput(repo, name: 'duplicate'),
      ], pending: true);
      expect(repo.state.photos, hasLength(1));
      expect(repo.state.photosFor(event.id), hasLength(1));
      final photo = repo.state.photos.single;
      expect(
        await repo.originalFile(photo).readAsBytes(),
        List.generate(150000, (index) => index % 251),
      );
      expect(repo.state.mediaBytes, 150006);
      expect(
        await Directory('${repo.directory.path}/imports').list().toList(),
        isEmpty,
      );
      await repo.saveEvent(event.copyWith(coverPhotoId: photo.id));
      await repo.updatePhotoDate(photo.id, DateTime(2024, 1, 2));
      expect(repo.state.photos.single.date.iso, '2024-01-02');
      final utcCapture = DateTime.utc(2025, 11, 20, 23, 30);
      await repo.updatePhotoDate(photo.id, utcCapture);
      expect(
        repo.state.photos.single.date,
        CalendarDate.fromDateTime(utcCapture.toLocal()),
      );
      await repo.removeAssociation(event.id, photo.id);
      expect(repo.state.events.single.coverPhotoId, isNull);
      expect(await repo.originalFile(photo).exists(), true);
    },
  );

  test('picker inputs outside app imports are rejected', () async {
    final repo = await repository('a');
    await repo.saveEvent(event);
    final outside = File('${temporary.path}/outside.jpg');
    await outside.writeAsBytes([1]);
    final input = PhotoInput(
      sourceId: 'outside',
      originalPath: outside.path,
      thumbnailPath: outside.path,
      capturedAt: DateTime.now(),
      originalName: 'x.jpg',
      mimeType: 'image/jpeg',
    );
    await expectLater(
      repo.ingestPhotos(event.id, [input]),
      throwsFormatException,
    );
    await repo.discardPhotoInputs([input]);
    expect(
      await outside.exists(),
      true,
      reason: 'Cleanup must not remove external user files',
    );
    expect(repo.state.photos, isEmpty);
  });

  test(
    'complete archive roundtrip preserves original, thumbnail, events and associations',
    () async {
      final first = await repository('source');
      final second = await repository('destination');
      await first.saveEvent(event);
      await first.ingestPhotos(event.id, [await photoInput(first)]);
      await first.saveEvent(
        event.copyWith(coverPhotoId: first.state.photos.single.id),
      );
      final archive = await ArchiveService(
        first,
      ).exportTo(File('${temporary.path}/all.shiri'));
      final service = ArchiveService(second);
      final preview = await service.previewImport(archive);
      expect(preview.newEvents, 1);
      expect(preview.newPhotos, 1);
      expect(second.state.events, isEmpty, reason: 'Preview must not commit');
      await service.applyImport(preview);
      expect(
        second.state.events.single.coverPhotoId,
        first.state.events.single.coverPhotoId,
      );
      expect(second.state.photosFor(event.id), hasLength(1));
      expect(
        await fileSha256(second.originalFile(second.state.photos.single)),
        first.state.photos.single.originalHash,
      );
      expect(
        await second.thumbnailFile(second.state.photos.single).readAsBytes(),
        [1, 2, 3, 4, 5, 6],
      );
      final again = await service.previewImport(archive);
      expect(again.newPhotos, 0);
      expect(again.duplicatePhotos, 1);
      await service.applyImport(again);
      expect(second.state.photos, hasLength(1));
      expect(
        (await Directory('${second.directory.path}/staging').list().toList()),
        isEmpty,
      );
      await expectLater(service.applyImport(again), throwsStateError);
    },
  );

  test(
    'conflicts retain current metadata including edits made after preview',
    () async {
      final first = await repository('source');
      final second = await repository('destination');
      await first.saveEvent(event);
      await second.saveEvent(event.copyWith(title: '已有名称'));
      final archive = await ArchiveService(
        first,
      ).exportTo(File('${temporary.path}/all.shiri'));
      final service = ArchiveService(second);
      final preview = await service.previewImport(archive);
      expect(preview.conflicts, hasLength(1));
      await second.saveEvent(event.copyWith(title: '预览期间修改'));
      await service.applyImport(preview);
      expect(second.state.events.single.title, '预览期间修改');
    },
  );

  test(
    'corruption, truncation, extra bytes and path traversal never mutate destination',
    () async {
      final first = await repository('source');
      final second = await repository('destination');
      await first.saveEvent(event);
      await first.ingestPhotos(event.id, [await photoInput(first)]);
      final archive = await ArchiveService(
        first,
      ).exportTo(File('${temporary.path}/all.shiri'));
      final original = await archive.readAsBytes();
      final service = ArchiveService(second);
      final corrupt = Uint8List.fromList(original)..[original.length - 1] ^= 1;
      final bad = File('${temporary.path}/bad.shiri');
      for (final bytes in [
        corrupt,
        original.sublist(0, original.length - 1),
        [...original, 0],
      ]) {
        await bad.writeAsBytes(bytes);
        await expectLater(service.previewImport(bad), throwsFormatException);
        expect(second.state.events, isEmpty);
        expect(
          (await Directory('${second.directory.path}/staging').list().toList()),
          isEmpty,
        );
      }
      final manifestLength = ByteData.sublistView(
        original,
        8,
        12,
      ).getUint32(0, Endian.big);
      final manifest =
          jsonDecode(utf8.decode(original.sublist(44, 44 + manifestLength)))
              as Map<String, dynamic>;
      (manifest['files'] as List).first['path'] = '../library.json';
      final editedManifest = utf8.encode(jsonEncode(manifest));
      final length = ByteData(4)
        ..setUint32(0, editedManifest.length, Endian.big);
      await bad.writeAsBytes([
        ...ascii.encode('SHIRI001'),
        ...length.buffer.asUint8List(),
        ...sha256.convert(editedManifest).bytes,
        ...editedManifest,
        ...original.sublist(44 + manifestLength),
      ]);
      await expectLater(service.previewImport(bad), throwsFormatException);
      expect(second.state.events, isEmpty);
    },
  );

  test(
    'cancelled preview removes only staging and missing media cannot export success',
    () async {
      final first = await repository('source');
      final second = await repository('destination');
      await first.saveEvent(event);
      await first.ingestPhotos(event.id, [await photoInput(first)]);
      final service = ArchiveService(first);
      final archive = await service.exportTo(
        File('${temporary.path}/all.shiri'),
      );
      final preview = await ArchiveService(second).previewImport(archive);
      await preview.dispose();
      expect(second.state.events, isEmpty);
      expect(
        (await Directory('${second.directory.path}/staging').list().toList()),
        isEmpty,
      );
      await first.originalFile(first.state.photos.single).delete();
      final destination = File('${temporary.path}/missing.shiri');
      await expectLater(service.exportTo(destination), throwsFormatException);
      expect(await destination.exists(), false);
      expect(first.state.lastBackupAt, isNull);
    },
  );
}
