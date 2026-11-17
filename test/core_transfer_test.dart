import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anniversary/core/core.dart';

/// Deliberately fake cryptography for exercising protocol state, framing and
/// authentication failures on the host. Production uses CryptoKit / javax.crypto.
class _FakeCrypto implements TransferCrypto {
  final _pairs = <String, Uint8List>{};
  @override
  Future<TransferKeyPair> generateKeyPair() async {
    final handle = newId();
    final publicKey = Uint8List.fromList([4, ...randomBytes(64)]);
    _pairs[handle] = publicKey;
    return TransferKeyPair(handle, publicKey);
  }

  @override
  Future<Uint8List> deriveKey({
    required String handle,
    required Uint8List peerPublicKey,
    required Uint8List salt,
  }) async {
    final local = _pairs.remove(handle)!;
    final keys = [base64Encode(local), base64Encode(peerPublicKey)]..sort();
    return Uint8List.fromList(
      sha256.convert([...utf8.encode(keys.join('|')), ...salt]).bytes,
    );
  }

  @override
  Future<Uint8List> seal({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List aad,
  }) async {
    final encrypted = List.generate(
      plaintext.length,
      (index) => plaintext[index] ^ key[index % 32] ^ nonce[index % 12],
    );
    final tag = Hmac(
      sha256,
      key,
    ).convert([...nonce, ...aad, ...encrypted]).bytes.sublist(0, 16);
    return Uint8List.fromList([...encrypted, ...tag]);
  }

  @override
  Future<Uint8List> open({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List aad,
  }) async {
    if (ciphertext.length < 16)
      throw const FormatException('test authentication failed');
    final encrypted = ciphertext.sublist(0, ciphertext.length - 16);
    final tag = Hmac(
      sha256,
      key,
    ).convert([...nonce, ...aad, ...encrypted]).bytes.sublist(0, 16);
    if (base64Encode(tag) !=
        base64Encode(ciphertext.sublist(ciphertext.length - 16))) {
      throw const FormatException('test authentication failed');
    }
    return Uint8List.fromList(
      List.generate(
        encrypted.length,
        (index) => encrypted[index] ^ key[index % 32] ^ nonce[index % 12],
      ),
    );
  }
}

void main() {
  late Directory temporary;
  final receivers = <EncryptedTransferReceiver>[];
  final senders = <EncryptedTransferSender>[];
  final proxies = <HttpServer>[];
  final clients = <HttpClient>[];
  Future<EncryptedTransferReceiver> receiver() async {
    final value = await EncryptedTransferReceiver.start(
      crypto: _FakeCrypto(),
      temporaryDirectory: Directory('${temporary.path}/receive'),
      deviceName: '接收手机',
      address: InternetAddress.loopbackIPv4,
    );
    receivers.add(value);
    return value;
  }

  Future<EncryptedTransferSender> sender(int port) async {
    final value = await EncryptedTransferSender.connect(
      endpoint: Uri.parse('http://127.0.0.1:$port'),
      crypto: _FakeCrypto(),
      deviceName: '发送手机',
    );
    senders.add(value);
    return value;
  }

  Future<File> archive() async {
    final file = File('${temporary.path}/outgoing.shiri');
    // Transport verifies its bytes. ArchiveService separately validates format.
    await file.writeAsBytes(List.generate(150000, (index) => index % 251));
    return file;
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('shiri-transfer-');
  });
  tearDown(() async {
    for (final value in senders) {
      await value.close();
    }
    for (final value in receivers) {
      await value.close();
    }
    for (final value in clients) {
      value.close(force: true);
    }
    for (final value in proxies) {
      await value.close(force: true);
    }
    senders.clear();
    receivers.clear();
    clients.clear();
    proxies.clear();
    await temporary.delete(recursive: true);
  });

  test(
    'both matching SAS confirmations are required before any file transfer',
    () async {
      final receiving = await receiver();
      final sending = await sender(receiving.port);
      expect(sending.sas, receiving.sas);
      expect(sending.sas, matches(RegExp(r'^\d{6}$')));
      final file = await archive();
      await expectLater(sending.sendFile(file), throwsStateError);
      await sending.confirm();
      await expectLater(sending.sendFile(file), throwsStateError);
      expect(
        await Directory('${temporary.path}/receive').list().toList(),
        isEmpty,
      );
      await receiving.confirm();
      await sending.waitForPeerConfirmation(
        timeout: const Duration(seconds: 2),
      );
      final delivered = receiving.updates.firstWhere(
        (e) => e.phase == TransferPhase.received,
      );
      await sending.sendFile(file);
      final result = await delivered;
      expect(result.receivedFile, isNotNull);
      expect(
        await result.receivedFile!.readAsBytes(),
        await file.readAsBytes(),
      );
      await expectLater(sending.sendFile(file), throwsStateError);
    },
  );

  for (final attack in ['reorder', 'truncate', 'authenticate']) {
    test('$attack encrypted upload fails without accepted file', () async {
      final receiving = await receiver();
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxies.add(proxy);
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      clients.add(client);
      final handlers = <Future<void>>[];
      proxy.listen((request) {
        handlers.add(() async {
          try {
            final outbound = await client.postUrl(
              Uri.parse(
                'http://127.0.0.1:${receiving.port}${request.uri.path}',
              ),
            );
            final session = request.headers.value('x-shiri-session');
            if (session != null)
              outbound.headers.set('x-shiri-session', session);
            final bytes = BytesBuilder();
            await for (final chunk in request) {
              bytes.add(chunk);
            }
            var body = bytes.takeBytes();
            if (request.uri.path == '/upload') {
              expect(
                body.sublist(21, 65),
                isNot(equals(List.generate(44, (index) => index % 251))),
                reason: 'Archive bytes must not travel as plaintext',
              );
              if (attack == 'reorder')
                ByteData.sublistView(body).setUint32(4, 1, Endian.big);
              if (attack == 'truncate')
                body = Uint8List.sublistView(body, 0, body.length - 10);
              if (attack == 'authenticate') body[21] ^= 1;
            }
            outbound.add(body);
            final response = await outbound.close();
            request.response.statusCode = response.statusCode;
            await response.pipe(request.response);
          } catch (_) {
            try {
              request.response.statusCode = 502;
              await request.response.close();
            } catch (_) {}
          }
        }());
      });
      final sending = await sender(proxy.port);
      await sending.confirm();
      await receiving.confirm();
      await expectLater(sending.sendFile(await archive()), throwsA(anything));
      await receiving.close();
      await Future.wait(handlers);
      expect(
        await Directory('${temporary.path}/receive').list().toList(),
        isEmpty,
      );
    });
  }

  test(
    'cancelling pairing closes receiver and rejects later sender actions',
    () async {
      final receiving = await receiver();
      final sending = await sender(receiving.port);
      await sending.cancel();
      await receiving.close();
      await expectLater(sending.confirm(), throwsStateError);
      expect(
        await Directory('${temporary.path}/receive').list().toList(),
        isEmpty,
      );
    },
  );

  test('expired pairing closes its listener and leaves no files', () async {
    final receiving = await EncryptedTransferReceiver.start(
      crypto: _FakeCrypto(),
      temporaryDirectory: Directory('${temporary.path}/receive'),
      deviceName: 'receiver',
      address: InternetAddress.loopbackIPv4,
      sessionLifetime: const Duration(milliseconds: 300),
    );
    receivers.add(receiving);
    final expired = receiving.updates.firstWhere(
      (e) => e.phase == TransferPhase.expired,
    );
    final sending = await sender(receiving.port);
    await expired.timeout(const Duration(seconds: 2));
    await receiving.close();
    await expectLater(sending.confirm(), throwsA(anything));
    expect(
      await Directory('${temporary.path}/receive').list().toList(),
      isEmpty,
    );
  });

  test('failed handshake consumes its native ephemeral key handle', () async {
    final unavailable = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxies.add(unavailable);
    unavailable.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 503;
      await request.response.close();
    });
    final crypto = _FakeCrypto();
    await expectLater(
      EncryptedTransferSender.connect(
        endpoint: Uri.parse('http://127.0.0.1:${unavailable.port}'),
        crypto: crypto,
        deviceName: 'sender',
      ),
      throwsA(isA<HttpException>()),
    );
    expect(crypto._pairs, isEmpty);
  });

  test('sender rejects public endpoints and insecure URL schemes', () async {
    await expectLater(
      EncryptedTransferSender.connect(
        endpoint: Uri.parse('http://8.8.8.8:80'),
        crypto: _FakeCrypto(),
        deviceName: 'test',
      ),
      throwsFormatException,
    );
    await expectLater(
      EncryptedTransferSender.connect(
        endpoint: Uri.parse('https://127.0.0.1:443'),
        crypto: _FakeCrypto(),
        deviceName: 'test',
      ),
      throwsFormatException,
    );
  });
}
