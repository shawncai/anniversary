import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final directory = Directory(
    Platform.environment['SHIRI_SCREENSHOT_DIR'] ??
        'build/integration_screenshots',
  );
  await directory.create(recursive: true);
  final screenshots = <Map<String, Object>>[];
  await integrationDriver(
    onScreenshot:
        (String name, List<int> bytes, [Map<String, Object?>? args]) async {
          if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name) || bytes.length < 24)
            return false;
          const png = [137, 80, 78, 71, 13, 10, 26, 10];
          for (var i = 0; i < png.length; i++) {
            if (bytes[i] != png[i]) return false;
          }
          final header = ByteData.sublistView(
            Uint8List.fromList(bytes),
            16,
            24,
          );
          final width = header.getUint32(0), height = header.getUint32(4);
          if (width == 0 || height == 0) return false;
          final file = File('${directory.path}/$name.png');
          await file.writeAsBytes(bytes, flush: true);
          screenshots.add({
            'name': name,
            'file': file.absolute.path,
            'width': width,
            'height': height,
            'bytes': bytes.length,
          });
          stdout.writeln('Captured $name ($width × $height)');
          if (Platform.isMacOS)
            await Process.run('dot_clean', [
              './',
            ], workingDirectory: directory.path);
          return true;
        },
    responseDataCallback: (Map<String, dynamic>? data) async {
      final summary = Map<String, dynamic>.from(data ?? {})
        ..remove('screenshots');
      summary['screenshots'] = screenshots;
      const requiredScreenshots = {
        '01-home-font',
        '02-album-palette',
        '03-selection-palette',
        '04-data-font',
      };
      final captured = screenshots.map((item) => item['name']).toSet();
      final verified = summary['fontCollection'];
      final fullyVerified =
          verified is Map &&
          verified['completed'] == true &&
          verified['bundledWeights'] == 4 &&
          verified['creationCollected'] == 4 &&
          verified['afterEditAndReentry'] == 4 &&
          verified['afterManualCollection'] == 5 &&
          requiredScreenshots.difference(captured).isEmpty;
      summary['driverVerificationComplete'] = fullyVerified;
      await File('${directory.path}/results.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(summary),
        flush: true,
      );
      if (Platform.isMacOS)
        await Process.run('dot_clean', [
          './',
        ], workingDirectory: directory.path);
      if (!fullyVerified) {
        throw StateError(
          'Font and collection flow did not finish all assertions and screenshots.',
        );
      }
    },
    writeResponseOnFailure: true,
  );
}
