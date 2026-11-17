import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:anniversary/core/core.dart';
import 'package:anniversary/core/cover.dart';

void main() {
  final first = CalendarDate(2020, 2, 29);
  Anniversary event() =>
      Anniversary(id: 'event', title: '纪念日', startDate: first);
  MemoryPhoto photo(int n, int year) => MemoryPhoto(
    id: n.toRadixString(16).padLeft(64, '0'),
    sourceId: '$n',
    capturedAt: DateTime(year, 2, 28),
    originalName: '$n.jpg',
    mimeType: 'image/jpeg',
    originalHash: n.toRadixString(16).padLeft(64, '0'),
    thumbnailHash: (n + 100).toRadixString(16).padLeft(64, '0'),
    originalBytes: 1,
    thumbnailBytes: 1,
  );
  final photos = [photo(1, 2021), photo(2, 2022), photo(3, 2022)];
  LibraryState library(Anniversary e) => LibraryState(
    events: [e],
    photos: photos,
    associations: photos
        .map(
          (p) => PhotoAssociation(
            eventId: e.id,
            photoId: p.id,
            status: AssociationStatus.confirmed,
          ),
        )
        .toList(),
  );

  test(
    'old backups get fixed cover and annual repetition without new permissions',
    () {
      final old = {
        'id': 'event',
        'title': '原资料',
        'startDate': '2020-02-29',
        'coverPhotoId': null,
        'windowDays': 1,
      };
      final e = Anniversary.fromJson(old);
      expect(e.coverMode, CoverMode.fixed);
      expect(e.repeatYearly, true);
      expect(e.reminderEnabled, false);
    },
  );
  test('new cover and reminder settings survive JSON round trip', () {
    final e = event().copyWith(
      coverMode: CoverMode.daily,
      coverSource: CoverSource.selection,
      coverPhotoIds: photos.take(2).map((p) => p.id).toList(),
      coverChangeMinute: 725,
      repeatYearly: false,
      reminderEnabled: true,
      reminderMinute: 630,
    );
    final restored = LibraryState.fromJson(library(e).toJson());
    expect(restored.events.single.toJson(), e.toJson());
  });
  test('slideshow is deterministic and moves only at its interval', () {
    final e = event().copyWith(
      coverMode: CoverMode.slideshow,
      coverIntervalSeconds: 10,
    );
    final state = library(e);
    final t = DateTime.utc(2026, 1, 1);
    expect(
      coverPhoto(state, e, t)!.id,
      coverPhoto(state, e, t.add(const Duration(seconds: 9)))!.id,
    );
    expect(
      coverPhoto(state, e, t)!.id,
      isNot(coverPhoto(state, e, t.add(const Duration(seconds: 10)))!.id),
    );
  });
  test('daily change uses local scheduled time and survives restart', () {
    final e = event().copyWith(
      coverMode: CoverMode.daily,
      coverChangeMinute: 9 * 60,
    );
    final state = library(e);
    final before = coverPhoto(state, e, DateTime(2026, 11, 16, 8, 59))!.id;
    final after = coverPhoto(state, e, DateTime(2026, 11, 16, 9))!.id;
    expect(before, isNot(after));
    expect(
      after,
      coverPhoto(
        LibraryState.fromJson(state.toJson()),
        e,
        DateTime(2026, 11, 16, 23),
      )!.id,
    );
  });
  test(
    'year and custom sources never show photos outside the chosen group',
    () {
      final e = event().copyWith(
        coverMode: CoverMode.interval,
        coverSource: CoverSource.year,
        coverYear: 2022,
        coverIntervalSeconds: 3600,
      );
      for (var h = 0; h < 10; h++) {
        expect(
          coverPhoto(library(e), e, DateTime(2026, 1, 1, h))!.date.year,
          2022,
        );
      }
      final selected = e.copyWith(
        coverSource: CoverSource.selection,
        coverPhotoIds: [photos.first.id],
      );
      expect(
        coverPhoto(library(selected), selected, DateTime.now())!.id,
        photos.first.id,
      );
      final empty = selected.copyWith(coverPhotoIds: []);
      expect(coverPhoto(library(empty), empty, DateTime.now()), isNull);
    },
  );
  test('fixed cover never rotates', () {
    final e = event().copyWith(coverPhotoId: photos[1].id);
    expect(coverPhoto(library(e), e, DateTime(2026))!.id, photos[1].id);
    expect(coverPhoto(library(e), e, DateTime(2028))!.id, photos[1].id);
  });
  test('one-time dates stop counting down after their date', () {
    final p = anniversaryProgress(
      first,
      today: CalendarDate(2026, 2, 28),
      repeatYearly: false,
    );
    expect(p.countdownDays, 0);
    expect(p.nextDate, first);
    expect(p.anniversaryNumber, 0);
  });
  test('day reminders respect once, yearly, leap-day and first date', () {
    final e = event().copyWith(reminderEnabled: true);
    expect(reminderIsToday(e, CalendarDate(2026, 2, 28)), true);
    expect(reminderIsToday(e, CalendarDate(2028, 2, 28)), false);
    expect(reminderIsToday(e, CalendarDate(2028, 2, 29)), true);
    expect(reminderIsToday(e, CalendarDate(2019, 2, 28)), false);
    expect(reminderIsToday(e.copyWith(repeatYearly: false), first), true);
    expect(
      reminderIsToday(
        e.copyWith(repeatYearly: false),
        CalendarDate(2026, 2, 28),
      ),
      false,
    );
    expect(reminderIsToday(e.copyWith(reminderEnabled: false), first), false);
  });
  test(
    'invalid settings and invalid cover group references fail validation',
    () {
      expect(
        () => event().copyWith(reminderMinute: 1440),
        throwsFormatException,
      );
      expect(
        () => event().copyWith(coverIntervalSeconds: 0),
        throwsFormatException,
      );
      expect(
        () => LibraryState(
          events: [
            event().copyWith(coverPhotoIds: [photos.first.id]),
          ],
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'batch removal survives scans and archive transfer; manual add restores',
    () async {
      final dir = await Directory.systemTemp.createTemp('shiri-management-');
      final repo = await LibraryRepository.open(Directory('${dir.path}/a'));
      final other = await LibraryRepository.open(Directory('${dir.path}/b'));
      Future<PhotoInput> input() async {
        final original = File('${repo.directory.path}/imports/original.jpg');
        final thumbnail = File('${repo.directory.path}/imports/thumb.jpg');
        await original.writeAsBytes([1, 2, 3]);
        await thumbnail.writeAsBytes([4, 5, 6]);
        return PhotoInput(
          sourceId: 'one',
          originalPath: original.path,
          thumbnailPath: thumbnail.path,
          capturedAt: DateTime(2021, 2, 28),
          originalName: 'one.jpg',
          mimeType: 'image/jpeg',
        );
      }

      try {
        await repo.saveEvent(event());
        await repo.saveEvent(
          Anniversary(id: 'second', title: '另一纪念日', startDate: first),
        );
        await repo.ingestPhotos('event', [await input()]);
        final id = repo.state.photos.single.id;
        await repo.saveEvent(
          event().copyWith(
            coverPhotoId: id,
            coverSource: CoverSource.selection,
            coverPhotoIds: [id],
          ),
        );
        await repo.associatePhotos('second', [id]);
        await repo.removeAssociations('event', [id]);
        expect(repo.state.photosFor('event'), isEmpty);
        expect(repo.state.photosFor('second').length, 1);
        expect(repo.state.events.first.coverPhotoIds, isEmpty);
        expect(
          await repo.ingestPhotos('event', [await input()], automatic: true),
          0,
        );
        expect(repo.state.photosFor('event'), isEmpty);
        final archive = await ArchiveService(
          repo,
        ).exportTo(File('${dir.path}/backup.shiri'));
        final importer = ArchiveService(other);
        final preview = await importer.previewImport(archive);
        try {
          await importer.applyImport(preview);
        } finally {
          await preview.dispose();
        }
        expect(
          other.state.associations
              .firstWhere((a) => a.eventId == 'event')
              .status,
          AssociationStatus.excluded,
        );
        await repo.associatePhotos('event', [id]);
        expect(repo.state.photosFor('event').length, 1);
        expect(
          await repo.originalFile(repo.state.photos.single).readAsBytes(),
          [1, 2, 3],
        );
      } finally {
        await repo.close();
        await other.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
