import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/transfer.dart';

class PhotoScanPage {
  const PhotoScanPage(this.items, this.nextOffset, this.unavailable);
  final List<PhotoInput> items;
  final int? nextOffset;
  final int unavailable;
}

class NativePlatform implements TransferCrypto {
  NativePlatform({MethodChannel? channel})
    : channel =
          channel ?? const MethodChannel('com.shiri.anniversary/platform') {
    this.channel.setMethodCallHandler((call) async {
      if (call.method == 'onDeepLink' && call.arguments is String) {
        _links.add(call.arguments as String);
      } else if (call.method == 'onDiscoveryError' &&
          call.arguments is String) {
        _discoveryErrors.add(call.arguments as String);
      } else if (call.method == 'onNearbyDevice' && call.arguments is Map) {
        _nearby.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      return null;
    });
  }
  final MethodChannel channel;
  final _links = StreamController<String>.broadcast();
  final _discoveryErrors = StreamController<String>.broadcast();
  Stream<String> get discoveryErrors => _discoveryErrors.stream;
  final _nearby = StreamController<Map<String, dynamic>>.broadcast();
  Stream<String> get deepLinks => _links.stream;
  Stream<Map<String, dynamic>> get nearbyDevices => _nearby.stream;

  Future<Map<String, String>> paths() async {
    final result = await channel.invokeMapMethod<String, dynamic>('paths');
    if (result == null ||
        result['documents'] is! String ||
        result['temporary'] is! String) {
      throw const FormatException('无法打开本机资料目录');
    }
    return {
      'documents': result['documents'] as String,
      'temporary': result['temporary'] as String,
    };
  }

  Future<String> photoPermission({bool request = false}) async =>
      await channel.invokeMethod<String>(
        request ? 'requestPhotoPermission' : 'photoPermission',
      ) ??
      'denied';

  Future<List<PhotoInput>?> pickPhotos() async {
    final values = await channel.invokeMethod<List<dynamic>>('pickPhotos');
    return values
        ?.map((e) => PhotoInput.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<PhotoScanPage> scanPhotos(
    Anniversary event,
    int offset, {
    int limit = 20,
  }) async {
    final map = await channel.invokeMapMethod<String, dynamic>('scanPhotos', {
      'startYear': event.startDate.year,
      'month': event.startDate.month,
      'day': event.startDate.day,
      'windowDays': event.windowDays,
      'offset': offset,
      'limit': limit,
    });
    if (map == null) throw const FormatException('无法读取照片');
    return PhotoScanPage(
      (map['items'] as List? ?? [])
          .map((e) => PhotoInput.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      map['nextOffset'] as int?,
      (map['unavailable'] as num?)?.toInt() ?? 0,
    );
  }

  Future<String> syncReminder(Anniversary event, {bool request = true}) async =>
      await channel.invokeMethod<String>('syncReminder', {
        ...event.toJson(),
        'requestPermissions': request,
      }) ??
      '提醒尚未设置';

  Future<List<String>> takeDayReminders(List<String> ids, String date) async =>
      (await channel.invokeListMethod<String>('takeDayReminders', {
        'ids': ids,
        'date': date,
      })) ??
      [];

  Future<String?> importFile() => channel.invokeMethod<String>('importFile');
  Future<bool> exportFile(File file) async =>
      await channel.invokeMethod<bool>('exportFile', {
        'path': file.path,
        'name': file.uri.pathSegments.last,
      }) ??
      false;
  Future<void> updateWidgets(
    Map<String, dynamic> snapshot,
    String? coverPath,
  ) => channel.invokeMethod<void>('updateWidgets', {
    'json': jsonEncode(snapshot),
    'coverPath': coverPath,
  });
  Future<bool> requestPinWidget() async =>
      await channel.invokeMethod<bool>('requestPinWidget') ?? false;
  Future<String?> initialLink() => channel.invokeMethod<String>('initialLink');
  Future<void> openSettings() => channel.invokeMethod<void>('openSettings');
  Future<String> deviceName() async =>
      await channel.invokeMethod<String>('deviceName') ?? '这部手机';
  Future<bool> startDiscovery({
    required String name,
    required String host,
    required int port,
  }) async =>
      await channel.invokeMethod<bool>('startDiscovery', {
        'name': name,
        'host': host,
        'port': port,
      }) ??
      false;
  Future<void> stopDiscovery() => channel.invokeMethod<void>('stopDiscovery');

  Uint8List _bytes(dynamic value) {
    if (value is Uint8List) return value;
    if (value is List) return Uint8List.fromList(value.cast<int>());
    throw const FormatException('系统加密接口返回无效数据');
  }

  @override
  Future<TransferKeyPair> generateKeyPair() async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'cryptoKeyPair',
    );
    if (result == null) throw const FormatException('无法建立加密连接');
    return TransferKeyPair(
      result['handle'] as String,
      _bytes(result['publicKey']),
    );
  }

  @override
  Future<Uint8List> deriveKey({
    required String handle,
    required Uint8List peerPublicKey,
    required Uint8List salt,
  }) async => _bytes(
    await channel.invokeMethod<dynamic>('cryptoDerive', {
      'handle': handle,
      'peerPublicKey': peerPublicKey,
      'salt': salt,
    }),
  );
  @override
  Future<Uint8List> seal({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List aad,
  }) async => _bytes(
    await channel.invokeMethod<dynamic>('cryptoSeal', {
      'key': key,
      'nonce': nonce,
      'plaintext': plaintext,
      'aad': aad,
    }),
  );
  @override
  Future<Uint8List> open({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List aad,
  }) async => _bytes(
    await channel.invokeMethod<dynamic>('cryptoOpen', {
      'key': key,
      'nonce': nonce,
      'ciphertext': ciphertext,
      'aad': aad,
    }),
  );

  Future<void> dispose() async {
    await stopDiscovery().catchError((_) {});
    channel.setMethodCallHandler(null);
    await _links.close();
    await _discoveryErrors.close();
    await _nearby.close();
  }
}
