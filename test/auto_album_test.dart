import 'dart:async';
import 'dart:io';

import 'package:anniversary/core/core.dart';
import 'package:anniversary/platform/native_platform.dart';
import 'package:anniversary/ui/app_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _AlbumHarness {
  late Directory directory;
  late LibraryRepository repository;
  late AppController controller;
  final channel = const MethodChannel('test.shiri.auto-album');
  final calls = <MethodCall>[];
  String permission = 'full';
  String requestedPermission = 'full';
  late Future<Map<String, dynamic>> Function(int offset) page;

  Future<void> open({CalendarDate? start, int window = 1}) async {
    directory = await Directory.systemTemp.createTemp('shiri-auto-album-');
    repository = await LibraryRepository.open(
      Directory('${directory.path}/documents'),
    );
    final temporary = await Directory('${directory.path}/temporary').create();
    await repository.saveEvent(
      Anniversary(
        id: 'event',
        title: '纪念日',
        startDate: start ?? CalendarDate(2022, 11, 20),
        windowDays: window,
      ),
    );
    page = (_) async => {
      'items': <Object>[],
      'nextOffset': null,
      'unavailable': 0,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'photoPermission':
              return permission;
            case 'requestPhotoPermission':
              return permission = requestedPermission;
            case 'scanPhotos':
              return page((call.arguments as Map)['offset'] as int);
            case 'updateWidgets':
            case 'stopDiscovery':
              return null;
            default:
              throw MissingPluginException(call.method);
          }
        });
    controller = AppController(
      repository: repository,
      native: NativePlatform(channel: channel),
      temporary: temporary,
    );
  }

  Future<Map<String, dynamic>> photo(String fixture, DateTime captured) async {
    final id = newId();
    final source = File('test/fixtures/$fixture.png');
    final original = await source.copy(
      '${repository.directory.path}/imports/$id.png',
    );
    final thumbnail = await source.copy(
      '${repository.directory.path}/imports/$id.thumb.jpg',
    );
    return {
      'sourceId': id,
      'originalPath': original.path,
      'thumbnailPath': thumbnail.path,
      'capturedAt': captured.toIso8601String(),
      'originalName': '$fixture.png',
      'mimeType': 'image/png',
    };
  }

  Future<(int, int)> scan({void Function(int)? progress}) =>
      controller.scanPhotos(onProgress: progress ?? (_) {});

  Future<void> expectNoStagingCopies() async {
    expect(
      await Directory('${repository.directory.path}/imports').list().toList(),
      isEmpty,
    );
  }

  Future<void> close() async {
    await controller.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _AlbumHarness h;
  setUp(() async {
    h = _AlbumHarness();
    await h.open();
  });
  tearDown(() => h.close());

  test(
    'automatic collection drains every page and sets a cover without confirmation',
    () async {
      h.page = (offset) async => {
        'items': [
          await h.photo(
            offset == 0 ? 'cover' : 'cake',
            DateTime(2025 - offset, 11, 20),
          ),
        ],
        'nextOffset': offset == 0 ? 1 : null,
        'unavailable': offset == 0 ? 0 : 2,
      };
      final progress = <int>[];
      expect(await h.scan(progress: progress.add), (2, 2));
      expect(progress, [1, 2]);
      expect(h.controller.photos, hasLength(2));
      expect(h.controller.pending, isEmpty);
      expect(h.controller.selected!.coverPhotoId, isNotNull);
      final calls = h.calls.where((c) => c.method == 'scanPhotos').toList();
      expect(calls.map((c) => (c.arguments as Map)['offset']), [0, 1]);
      expect((calls.first.arguments as Map)['startYear'], 2022);
      expect((calls.first.arguments as Map)['windowDays'], 1);
      await h.expectNoStagingCopies();
    },
  );

  test(
    'dates outside the inclusive window or before the first day are discarded',
    () async {
      h.page = (_) async => {
        'items': [
          await h.photo('cover', DateTime(2022, 11, 19)),
          await h.photo('cake', DateTime(2025, 11, 22)),
          await h.photo('coffee', DateTime(2025, 11, 19)),
        ],
        'nextOffset': null,
      };
      expect(await h.scan(), (1, 0));
      expect(h.controller.photos.single.originalName, 'coffee.png');
      await h.expectNoStagingCopies();
    },
  );

  test(
    'repeated scans deduplicate archived bytes and event associations',
    () async {
      h.page = (_) async => {
        'items': [await h.photo('cover', DateTime(2025, 11, 20))],
        'nextOffset': null,
      };
      expect(await h.scan(), (1, 0));
      expect(await h.scan(), (0, 0));
      expect(h.repository.state.photos, hasLength(1));
      expect(h.repository.state.associations, hasLength(1));
      await h.expectNoStagingCopies();
    },
  );

  test('new automatic scans promote a matching legacy pending photo', () async {
    final pending = await h.photo('cover', DateTime(2025, 11, 20));
    await h.repository.ingestPhotos('event', [
      PhotoInput.fromMap(pending),
    ], pending: true);
    h.page = (_) async => {
      'items': [await h.photo('cover', DateTime(2025, 11, 20))],
      'nextOffset': null,
    };
    expect(h.controller.pending, hasLength(1));
    expect(await h.scan(), (1, 0));
    expect(h.controller.pending, isEmpty);
    expect(h.controller.photos, hasLength(1));
  });

  test(
    'first authorization is requested and limited access remains explicit',
    () async {
      h.permission = 'notDetermined';
      h.requestedPermission = 'limited';
      h.page = (_) async => {
        'items': [await h.photo('cake', DateTime(2025, 11, 20))],
        'nextOffset': null,
      };
      expect(await h.scan(), (1, 0));
      expect(h.controller.photoAccess, 'limited');
      expect(
        h.calls.where((c) => c.method == 'requestPhotoPermission'),
        hasLength(1),
      );
      h.permission = 'full';
      expect(await h.controller.refreshPhotoAccess(), true);
      expect(h.controller.photoAccess, 'full');
      expect(await h.controller.refreshPhotoAccess(), false);
    },
  );

  test(
    'denied and restricted permissions never enumerate the photo library',
    () async {
      for (final permission in ['denied', 'restricted']) {
        h.permission = permission;
        expect(await h.scan(), (0, 0));
        expect(h.controller.photoAccess, permission);
      }
      expect(h.calls.where((c) => c.method == 'scanPhotos'), isEmpty);
      expect(
        h.calls.where((c) => c.method == 'requestPhotoPermission'),
        isEmpty,
      );
    },
  );

  test(
    'cancellation stops before the next page while keeping committed matches',
    () async {
      h.page = (_) async => {
        'items': [await h.photo('cover', DateTime(2025, 11, 20))],
        'nextOffset': 1,
      };
      expect(await h.scan(progress: (_) => h.controller.cancelScan = true), (
        1,
        0,
      ));
      expect(h.calls.where((c) => c.method == 'scanPhotos'), hasLength(1));
      expect(h.controller.photos, hasLength(1));
      await h.expectNoStagingCopies();
    },
  );

  test(
    'cancellation during native export discards uncommitted copies',
    () async {
      final entered = Completer<void>();
      final reply = Completer<Map<String, dynamic>>();
      h.page = (_) {
        entered.complete();
        return reply.future;
      };
      final scan = h.scan();
      await entered.future;
      h.controller.cancelScan = true;
      reply.complete({
        'items': [await h.photo('cover', DateTime(2025, 11, 20))],
        'nextOffset': null,
      });
      expect(await scan, (0, 0));
      expect(h.controller.photos, isEmpty);
      await h.expectNoStagingCopies();
    },
  );

  test(
    'invalid pagination fails and releases the scan guard for retry',
    () async {
      h.page = (_) async => {'items': <Object>[], 'nextOffset': 0};
      await expectLater(h.scan(), throwsFormatException);
      expect(h.controller.scanningPhotos, false);
      h.page = (_) async => {'items': <Object>[], 'nextOffset': null};
      expect(await h.scan(), (0, 0));
    },
  );
}
