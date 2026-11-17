// Host-only test data tool. Never imported by lib/ or included in app assets.
import 'dart:convert';
import 'dart:io';

import 'package:anniversary/core/core.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run test/tools/seed_preview.dart /absolute/empty/output-directory',
    );
    exitCode = 64;
    return;
  }
  final output = Directory(arguments.single).absolute;
  if (await output.exists() && await output.list().isEmpty == false) {
    throw StateError('Refusing to seed a non-empty directory: ${output.path}');
  }
  final repository = await LibraryRepository.open(output);
  try {
    final together = Anniversary(
      id: 'test-together',
      title: '在一起',
      startDate: CalendarDate(2022, 11, 20),
    );
    final travel = Anniversary(
      id: 'test-travel',
      title: '第一次旅行',
      startDate: CalendarDate(2023, 8, 12),
    );
    final birthday = Anniversary(
      id: 'test-birthday',
      title: '生日',
      startDate: CalendarDate(2020, 7, 26),
    );
    for (final event in [together, travel, birthday]) {
      await repository.saveEvent(event);
    }

    Future<PhotoInput> input(
      String fixture,
      int year,
      int month,
      int day,
    ) async {
      final source = File.fromUri(
        Platform.script.resolve('../fixtures/$fixture.png'),
      );
      if (!await source.exists())
        throw FileSystemException('Missing test fixture', source.path);
      final id = newId();
      final original = await source.copy('${output.path}/imports/$id.png');
      final thumbnail = await source.copy(
        '${output.path}/imports/$id-thumb.jpg',
      );
      return PhotoInput(
        sourceId: 'test-fixture-$fixture',
        originalPath: original.path,
        thumbnailPath: thumbnail.path,
        capturedAt: DateTime(year, month, day, 12),
        originalName: '$fixture.png',
        mimeType: 'image/png',
      );
    }

    await repository.ingestPhotos(together.id, [
      await input('cover', 2025, 11, 20),
      await input('cake', 2024, 11, 20),
      await input('coffee', 2023, 11, 20),
    ]);
    // Associate the same real archived bytes with other test events; SHA256
    // deduplication must leave exactly three photos in the whole library.
    await repository.ingestPhotos(travel.id, [
      await input('cover', 2025, 11, 20),
    ]);
    await repository.ingestPhotos(birthday.id, [
      await input('cake', 2024, 11, 20),
    ]);
    for (final event in [together, travel, birthday]) {
      await repository.saveEvent(
        event.copyWith(
          coverPhotoId: repository.state.photosFor(event.id).first.id,
        ),
      );
    }
    await repository.selectEvent(together.id);
    if (repository.state.events.length != 3 ||
        repository.state.photos.length != 3 ||
        repository.state.photosFor(together.id).length != 3) {
      throw StateError('Unexpected fixture counts');
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'directory': output.path,
        'events': repository.state.events.length,
        'photos': repository.state.photos.length,
        'bytes': repository.state.mediaBytes,
        'selectedEventId': repository.state.selectedEventId,
        'notice':
            'TEST FIXTURES ONLY — inject into an isolated emulator, never a user phone.',
      }),
    );
  } finally {
    await repository.close();
    if (Platform.isMacOS) {
      final result = await Process.run('dot_clean', [
        './',
      ], workingDirectory: output.path);
      if (result.exitCode != 0) stderr.write(result.stderr);
    }
  }
}
