import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'archive.dart';
import 'models.dart';

class TransferKeyPair {
  const TransferKeyPair(this.handle, this.publicKey);
  final String handle;
  final Uint8List publicKey;
}

/// P-256 ECDH, HKDF-SHA256 and AES-256-GCM are supplied by platform crypto.
/// Test implementations must never be used in the shipping app.
abstract class TransferCrypto {
  Future<TransferKeyPair> generateKeyPair();
  Future<Uint8List> deriveKey({
    required String handle,
    required Uint8List peerPublicKey,
    required Uint8List salt,
  });
  Future<Uint8List> seal({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List aad,
  });
  Future<Uint8List> open({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List aad,
  });
}

enum TransferPhase {
  waiting,
  pairing,
  ready,
  transferring,
  received,
  cancelled,
  failed,
  expired,
}

class TransferUpdate {
  const TransferUpdate(
    this.phase, {
    this.sas,
    this.peerName,
    this.progress = 0,
    this.message,
    this.receivedFile,
  });
  final TransferPhase phase;
  final String? sas;
  final String? peerName;
  final double progress;
  final String? message;
  final File? receivedFile;
}

const _sessionLifetime = Duration(minutes: 30);
const _requestTimeout = Duration(seconds: 30);
const _maxControlBytes = 16 * 1024;
const _maxFrameBytes = archiveChunkBytes + 16;

Uint8List _aad(String session, String context) =>
    Uint8List.fromList(utf8.encode('shiri-transfer-v1|$session|$context'));

String _sas(
  Uint8List key,
  String session,
  Uint8List senderKey,
  Uint8List receiverKey,
  Uint8List salt,
) {
  final digest = Hmac(sha256, key).convert([
    ...utf8.encode('shiri-sas-v1|$session|'),
    ...senderKey,
    ...receiverKey,
    ...salt,
  ]);
  final integer = ByteData.sublistView(
    Uint8List.fromList(digest.bytes),
  ).getUint32(0, Endian.big);
  return (integer % 1000000).toString().padLeft(6, '0');
}

Uint8List _decodeBytes(Map<String, dynamic> json, String field, int length) {
  final bytes = base64Decode(requiredString(json, field, max: 400));
  if (bytes.length != length) throw const FormatException('配对参数长度无效');
  return bytes;
}

Future<Uint8List> _boundedBytes(Stream<List<int>> stream, int maximum) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream.timeout(_requestTimeout)) {
    if (bytes.length + chunk.length > maximum)
      throw const FormatException('请求过大');
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<Map<String, dynamic>> _plainJson(Stream<List<int>> stream) async =>
    jsonObject(
      jsonDecode(utf8.decode(await _boundedBytes(stream, _maxControlBytes))),
    );

Future<Map<String, dynamic>> _sealedJson(
  TransferCrypto crypto,
  Uint8List key,
  String session,
  String context,
  Map<String, dynamic> value,
) async {
  final nonce = randomBytes(12);
  final ciphertext = await crypto.seal(
    key: key,
    nonce: nonce,
    plaintext: Uint8List.fromList(utf8.encode(jsonEncode(value))),
    aad: _aad(session, context),
  );
  return {'nonce': base64Encode(nonce), 'ciphertext': base64Encode(ciphertext)};
}

Future<Map<String, dynamic>> _openJson(
  TransferCrypto crypto,
  Uint8List key,
  String session,
  String context,
  Map<String, dynamic> envelope,
) async {
  final nonce = _decodeBytes(envelope, 'nonce', 12);
  final ciphertext = base64Decode(
    requiredString(envelope, 'ciphertext', max: _maxControlBytes),
  );
  if (ciphertext.length < 16 || ciphertext.length > _maxControlBytes)
    throw const FormatException('加密消息无效');
  return jsonObject(
    jsonDecode(
      utf8.decode(
        await crypto.open(
          key: key,
          nonce: nonce,
          ciphertext: ciphertext,
          aad: _aad(session, context),
        ),
      ),
    ),
  );
}

bool _isLocalAddress(InternetAddress address) {
  if (address.isLoopback) return true;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254);
  }
  return bytes[0] & 0xfe == 0xfc ||
      (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80);
}

class EncryptedTransferReceiver {
  EncryptedTransferReceiver._(
    this.crypto,
    this.temporaryDirectory,
    this.deviceName,
    this._server,
    this.sessionLifetime,
  );
  final TransferCrypto crypto;
  final Directory temporaryDirectory;
  final String deviceName;
  final HttpServer _server;
  final Duration sessionLifetime;
  final _updates = StreamController<TransferUpdate>.broadcast();
  Stream<TransferUpdate> get updates => _updates.stream;
  int get port => _server.port;
  String? sas;
  String? peerName;
  Uint8List? _key;
  String? _session;
  DateTime? _expires;
  Timer? _expiryTimer;
  bool _localConfirmed = false;
  bool _remoteConfirmed = false;
  bool _uploading = false;
  bool _handshaking = false;
  bool _completed = false;
  int? _expectedBytes;
  bool _closed = false;
  File? _partial;
  HttpRequest? _activeUpload;
  Future<void>? _processingUpload;
  Future<void>? _closing;

  static Future<EncryptedTransferReceiver> start({
    required TransferCrypto crypto,
    required Directory temporaryDirectory,
    required String deviceName,
    InternetAddress? address,
    int port = 0,
    Duration sessionLifetime = _sessionLifetime,
  }) async {
    if (sessionLifetime <= Duration.zero ||
        sessionLifetime > _sessionLifetime) {
      throw ArgumentError('配对有效期必须大于零且不超过 30 分钟');
    }
    await temporaryDirectory.create(recursive: true);
    final server = await HttpServer.bind(
      address ?? InternetAddress.anyIPv4,
      port,
      shared: false,
    );
    server.idleTimeout = _requestTimeout;
    final receiver = EncryptedTransferReceiver._(
      crypto,
      temporaryDirectory,
      deviceName,
      server,
      sessionLifetime,
    );
    // Listen immediately; each request has its own bounded, authenticated handler.
    server.listen(
      receiver._handle,
      onError: (Object error) {
        receiver._emit(TransferUpdate(TransferPhase.failed, message: '接收连接中断'));
        unawaited(receiver.close());
      },
    );
    receiver._expiryTimer = Timer(sessionLifetime, receiver._expire);
    return receiver;
  }

  void _emit(TransferUpdate update) {
    if (!_updates.isClosed) _updates.add(update);
  }

  void _expire() {
    _emit(TransferUpdate(TransferPhase.expired, message: '配对已过期'));
    unawaited(close());
  }

  bool get _expired =>
      _closed || (_expires != null && !DateTime.now().isBefore(_expires!));

  Future<void> _respond(
    HttpRequest request,
    Map<String, dynamic> value, {
    int status = 200,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (_expired) {
        await _respond(request, {'error': 'expired'}, status: 410);
        return;
      }
      if (request.method != 'POST') {
        await _respond(request, {'error': 'method'}, status: 405);
        return;
      }
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null || !_isLocalAddress(remote)) {
        await _respond(request, {'error': 'local-network-only'}, status: 403);
        return;
      }
      final path = request.uri.path;
      if (path == '/handshake') {
        await _handshake(request);
        return;
      }
      if (_key == null ||
          request.headers.value('x-shiri-session') != _session) {
        await _respond(request, {'error': 'session'}, status: 403);
        return;
      }
      if (path == '/upload') {
        if (!_localConfirmed ||
            !_remoteConfirmed ||
            _uploading ||
            _completed ||
            _expectedBytes == null) {
          await _respond(request, {
            'error': 'confirmation-required',
          }, status: 403);
          return;
        }
        _uploading = true;
        _activeUpload = request;
        final future = _receive(request);
        _processingUpload = future;
        try {
          await future;
        } finally {
          _activeUpload = null;
          _uploading = false;
          _processingUpload = null;
        }
        return;
      }
      if (!['/confirm', '/status', '/cancel', '/prepare'].contains(path)) {
        await _respond(request, {'error': 'route'}, status: 404);
        return;
      }
      final envelope = await _plainJson(request);
      final control = await _openJson(
        crypto,
        _key!,
        _session!,
        '$path:request',
        envelope,
      );
      if (path == '/prepare') {
        if (!_localConfirmed || !_remoteConfirmed || _uploading || _completed) {
          throw StateError('等待双方确认配对码');
        }
        _expectedBytes = requiredInt(
          control,
          'bytes',
          min: 44,
          max: maxArchiveBytes,
        );
      }
      if (path == '/confirm') _remoteConfirmed = true;
      if (path == '/cancel') {
        await _respond(
          request,
          await _sealedJson(crypto, _key!, _session!, '$path:response', {
            'cancelled': true,
          }),
        );
        _emit(TransferUpdate(TransferPhase.cancelled, message: '对方已取消'));
        unawaited(close());
        return;
      }
      if (_localConfirmed && _remoteConfirmed)
        _emit(
          TransferUpdate(TransferPhase.ready, sas: sas, peerName: peerName),
        );
      await _respond(
        request,
        await _sealedJson(crypto, _key!, _session!, '$path:response', {
          'confirmed': _localConfirmed && _remoteConfirmed,
          'expiresAt': _expires!.toUtc().toIso8601String(),
        }),
      );
    } catch (_) {
      try {
        await _respond(request, {
          'error': 'invalid-or-interrupted',
        }, status: 400);
      } catch (_) {}
      if (request.uri.path == '/upload') {
        _emit(TransferUpdate(TransferPhase.failed, message: '传输中断或校验失败'));
        unawaited(close());
      }
    }
  }

  Future<void> _handshake(HttpRequest request) async {
    if (_session != null || _handshaking) {
      await _respond(request, {'error': 'busy'}, status: 409);
      return;
    }
    _handshaking = true;
    try {
      final hello = await _plainJson(request);
      if (hello['version'] != 1) throw const FormatException('传输版本不受支持');
      final session = requiredString(hello, 'session', max: 32);
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(session))
        throw const FormatException('无效会话');
      final senderKey = _decodeBytes(hello, 'publicKey', 65);
      if (senderKey[0] != 4) throw const FormatException('无效公钥');
      final salt = _decodeBytes(hello, 'salt', 32);
      final name = requiredString(hello, 'name', max: 120);
      final pair = await crypto.generateKeyPair();
      final key = await crypto.deriveKey(
        handle: pair.handle,
        peerPublicKey: senderKey,
        salt: salt,
      );
      if (key.length != 32 || pair.publicKey.length != 65)
        throw const FormatException('平台加密不可用');
      if (_closed) {
        key.fillRange(0, key.length, 0);
        return;
      }
      _key = key;
      _session = session;
      peerName = name;
      sas = _sas(key, session, senderKey, pair.publicKey, salt);
      _expires = DateTime.now().add(sessionLifetime);
      _expiryTimer?.cancel();
      _expiryTimer = Timer(sessionLifetime, _expire);
      await _respond(request, {
        'version': 1,
        'name': deviceName,
        'publicKey': base64Encode(pair.publicKey),
        'session': session,
      });
      _emit(
        TransferUpdate(TransferPhase.pairing, sas: sas, peerName: peerName),
      );
    } finally {
      _handshaking = false;
    }
  }

  Future<void> confirm() async {
    if (_key == null || _expired) throw StateError('尚未建立配对或已过期');
    _localConfirmed = true;
    _emit(
      TransferUpdate(
        _remoteConfirmed ? TransferPhase.ready : TransferPhase.pairing,
        sas: sas,
        peerName: peerName,
        message: _remoteConfirmed ? null : '等待对方确认',
      ),
    );
  }

  Future<void> _receive(HttpRequest request) async {
    final partial = File(
      '${temporaryDirectory.path}/receive-${newId()}.partial',
    );
    _partial = partial;
    final output = await partial.open(mode: FileMode.write);
    final reader = _NetworkReader(request);
    final collector = DigestCollector();
    final hasher = sha256.startChunkedConversion(collector);
    var total = 0;
    var sequence = 0;
    var finished = false;
    try {
      _emit(
        TransferUpdate(
          TransferPhase.transferring,
          sas: sas,
          peerName: peerName,
        ),
      );
      while (!finished) {
        if (_expired) throw const FormatException('会话已过期');
        final header = await reader.exact(21);
        final view = ByteData.sublistView(header);
        final length = view.getUint32(0, Endian.big);
        final receivedSequence = view.getUint32(4, Endian.big);
        final kind = header[8];
        if (length < 16 ||
            length > _maxFrameBytes ||
            receivedSequence != sequence ||
            kind > 1) {
          throw const FormatException('分片顺序或大小无效');
        }
        final encrypted = await reader.exact(length);
        final plaintext = await crypto.open(
          key: _key!,
          nonce: Uint8List.sublistView(header, 9, 21),
          ciphertext: encrypted,
          aad: _aad(_session!, 'sender:$sequence:$kind'),
        );
        if (plaintext.length > archiveChunkBytes)
          throw const FormatException('分片过大');
        if (kind == 0) {
          if (plaintext.isEmpty) throw const FormatException('空分片');
          total += plaintext.length;
          if (total > _expectedBytes!) throw const FormatException('传输超过声明大小');
          hasher.add(plaintext);
          await output.writeFrom(plaintext);
          _emit(
            TransferUpdate(
              TransferPhase.transferring,
              sas: sas,
              peerName: peerName,
              progress: total / _expectedBytes!,
            ),
          );
        } else {
          hasher.close();
          final commit = jsonObject(jsonDecode(utf8.decode(plaintext)));
          if (total != _expectedBytes ||
              commit['bytes'] != total ||
              commit['sha256'] != collector.value.toString() ||
              total < 44) {
            throw const FormatException('完整文件校验失败');
          }
          if (await reader.hasMore()) throw const FormatException('结束后存在额外分片');
          finished = true;
        }
        sequence++;
      }
      await output.flush();
    } finally {
      await reader.cancel();
      await output.close();
      if (!finished && await partial.exists()) await partial.delete();
    }
    if (_expired) {
      if (await partial.exists()) await partial.delete();
      throw const FormatException('会话已关闭');
    }
    final completed = await partial.rename(
      '${temporaryDirectory.path}/received-${newId()}.shiri',
    );
    // Until the receipt reaches the sender, close/error cleanup owns this file.
    _partial = completed;
    _completed = true;
    await _respond(
      request,
      await _sealedJson(crypto, _key!, _session!, '/upload:response', {
        'bytes': total,
        'verified': true,
      }),
    );
    _partial = null;
    _emit(
      TransferUpdate(
        TransferPhase.received,
        sas: sas,
        peerName: peerName,
        progress: 1,
        receivedFile: completed,
      ),
    );
  }

  Future<void> cancel() async {
    _emit(TransferUpdate(TransferPhase.cancelled, message: '已取消'));
    await close();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _expiryTimer?.cancel();
    try {
      await _activeUpload?.response.detachSocket().then(
        (socket) => socket.destroy(),
      );
    } catch (_) {}
    await _server.close(force: true);
    try {
      await _processingUpload;
    } catch (_) {}
    if (_partial != null && await _partial!.exists()) await _partial!.delete();
    _key?.fillRange(0, _key!.length, 0);
    _key = null;
    await _updates.close();
  }
}

class EncryptedTransferSender {
  EncryptedTransferSender._(
    this.crypto,
    this.endpoint,
    this._client,
    this._key,
    this._session,
    this.sas,
    this.peerName,
  );
  final TransferCrypto crypto;
  final Uri endpoint;
  final HttpClient _client;
  final Uint8List _key;
  final String _session;
  final String sas;
  final String peerName;
  final DateTime _expires = DateTime.now().add(_sessionLifetime);
  Timer? _expiryTimer;
  bool _confirmed = false;
  bool _closed = false;
  bool _sent = false;
  bool _sending = false;
  bool _preparing = false;

  static Future<EncryptedTransferSender> connect({
    required Uri endpoint,
    required TransferCrypto crypto,
    required String deviceName,
  }) async {
    final address = InternetAddress.tryParse(endpoint.host);
    if (endpoint.scheme != 'http' ||
        address == null ||
        !_isLocalAddress(address) ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.port <= 0 ||
        endpoint.port > 65535 ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty && endpoint.path != '/')) {
      throw const FormatException('请输入同一 Wi-Fi 或热点中的设备地址');
    }
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    client.findProxy = (_) => 'DIRECT';
    TransferKeyPair? pendingPair;
    var deriveAttempted = false;
    Uint8List? derivedKey;
    try {
      final pair = await crypto.generateKeyPair();
      pendingPair = pair;
      final session = newId();
      final salt = randomBytes(32);
      final request = await client
          .postUrl(endpoint.resolve('/handshake'))
          .timeout(_requestTimeout);
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'version': 1,
          'session': session,
          'name': deviceName,
          'publicKey': base64Encode(pair.publicKey),
          'salt': base64Encode(salt),
        }),
      );
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != 200) throw const HttpException('无法配对，接收方可能正忙');
      final reply = await _plainJson(response);
      if (reply['version'] != 1 || reply['session'] != session)
        throw const FormatException('无效配对回复');
      final remotePublic = _decodeBytes(reply, 'publicKey', 65);
      if (remotePublic[0] != 4) throw const FormatException('无效公钥');
      deriveAttempted =
          true; // Native derive consumes the handle even on failure.
      final key = await crypto.deriveKey(
        handle: pair.handle,
        peerPublicKey: remotePublic,
        salt: salt,
      );
      derivedKey = key;
      if (key.length != 32) throw const FormatException('平台加密不可用');
      final sender = EncryptedTransferSender._(
        crypto,
        endpoint,
        client,
        key,
        session,
        _sas(key, session, pair.publicKey, remotePublic, salt),
        requiredString(reply, 'name', max: 120),
      );
      sender._expiryTimer = Timer(
        _sessionLifetime,
        () => unawaited(sender.close()),
      );
      return sender;
    } catch (_) {
      client.close(force: true);
      derivedKey?.fillRange(0, derivedKey.length, 0);
      if (!deriveAttempted && pendingPair != null) {
        // The bridge's derive operation consumes its ephemeral handle. If the
        // handshake never reached derive, consume it locally and discard output.
        try {
          final discarded = await crypto.deriveKey(
            handle: pendingPair.handle,
            peerPublicKey: pendingPair.publicKey,
            salt: randomBytes(32),
          );
          discarded.fillRange(0, discarded.length, 0);
        } catch (_) {
          /* Native lifecycle cleanup also clears expired handles. */
        }
      }
      rethrow;
    }
  }

  void _check() {
    if (_closed || !DateTime.now().isBefore(_expires))
      throw StateError('配对已关闭或过期');
  }

  Future<Map<String, dynamic>> _control(
    String path, {
    Map<String, dynamic> data = const {},
  }) async {
    _check();
    final request = await _client
        .postUrl(endpoint.resolve(path))
        .timeout(_requestTimeout);
    request.followRedirects = false;
    request.headers.set('x-shiri-session', _session);
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode(
        await _sealedJson(crypto, _key, _session, '$path:request', {
          'request': newId(),
          ...data,
        }),
      ),
    );
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode != 200) throw const HttpException('对方已关闭连接或配对已过期');
    return _openJson(
      crypto,
      _key,
      _session,
      '$path:response',
      await _plainJson(response),
    );
  }

  Future<void> confirm() async {
    await _control('/confirm');
    _confirmed = true;
  }

  Future<void> waitForPeerConfirmation({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (!_confirmed) throw StateError('请先核对并确认六位配对码');
    final until = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(until)) {
      if ((await _control('/status'))['confirmed'] == true) return;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    throw TimeoutException('等待对方确认超时');
  }

  Future<void> sendFile(File file, {void Function(double)? onProgress}) async {
    _check();
    if (!_confirmed || _sent || _sending || _preparing)
      throw StateError('请先确认配对；每次配对仅传输一次');
    _preparing = true;
    late final int size;
    try {
      if ((await _control('/status'))['confirmed'] != true)
        throw StateError('等待双方确认配对码');
      size = await file.length();
      if (size < 44 || size > maxArchiveBytes)
        throw const FormatException('备份大小超限');
      _sending = true;
    } finally {
      _preparing = false;
    }
    HttpClientRequest? request;
    RandomAccessFile? input;
    try {
      await _control('/prepare', data: {'bytes': size});
      request = await _client
          .postUrl(endpoint.resolve('/upload'))
          .timeout(_requestTimeout);
      request.followRedirects = false;
      request.headers.set('x-shiri-session', _session);
      request.headers.contentType = ContentType.binary;
      final collector = DigestCollector();
      final hasher = sha256.startChunkedConversion(collector);
      input = await file.open();
      var sent = 0;
      var sequence = 0;
      while (sent < size) {
        _check();
        final chunk = await input.read(archiveChunkBytes);
        if (chunk.isEmpty) throw const FormatException('发送期间文件被截断');
        sent += chunk.length;
        if (sent > size) throw const FormatException('发送期间文件发生变化');
        hasher.add(chunk);
        await _writeFrame(request, chunk, sequence++, 0);
        onProgress?.call(sent / size);
      }
      if ((await input.read(1)).isNotEmpty)
        throw const FormatException('发送期间文件发生变化');
      hasher.close();
      final commit = Uint8List.fromList(
        utf8.encode(
          jsonEncode({'bytes': sent, 'sha256': collector.value.toString()}),
        ),
      );
      await _writeFrame(request, commit, sequence, 1);
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != 200) throw const HttpException('接收方未通过文件校验');
      final receipt = await _openJson(
        crypto,
        _key,
        _session,
        '/upload:response',
        await _plainJson(response),
      );
      if (receipt['verified'] != true || receipt['bytes'] != size)
        throw const FormatException('无效接收确认');
      _sent = true;
      onProgress?.call(1);
    } catch (_) {
      request?.abort();
      await close();
      rethrow;
    } finally {
      await input?.close();
      _sending = false;
    }
  }

  Future<void> _writeFrame(
    HttpClientRequest request,
    Uint8List bytes,
    int sequence,
    int kind,
  ) async {
    final nonce = randomBytes(12);
    final ciphertext = await crypto.seal(
      key: _key,
      nonce: nonce,
      plaintext: bytes,
      aad: _aad(_session, 'sender:$sequence:$kind'),
    );
    if (ciphertext.length != bytes.length + 16)
      throw const FormatException('平台加密输出无效');
    final header = ByteData(21)
      ..setUint32(0, ciphertext.length, Endian.big)
      ..setUint32(4, sequence, Endian.big)
      ..setUint8(8, kind);
    header.buffer.asUint8List().setRange(9, 21, nonce);
    request.add(header.buffer.asUint8List());
    request.add(ciphertext);
    await request.flush().timeout(_requestTimeout);
  }

  Future<void> cancel() async {
    if (!_closed && !_sending) {
      try {
        await _control('/cancel');
      } catch (_) {}
    }
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiryTimer?.cancel();
    _client.close(force: true);
    _key.fillRange(0, _key.length, 0);
  }
}

/// Backpressured frame reader. Retains at most one network chunk plus one frame.
class _NetworkReader {
  _NetworkReader(Stream<List<int>> source)
    : _iterator = StreamIterator(source.timeout(_requestTimeout));
  final StreamIterator<List<int>> _iterator;
  List<int> _current = const [];
  int _offset = 0;
  Future<Uint8List> exact(int count) async {
    final bytes = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (_offset == _current.length) {
        if (!await _iterator.moveNext()) throw const FormatException('加密传输被截断');
        _current = _iterator.current;
        _offset = 0;
      }
      final available = _current.length - _offset;
      final amount = available < count - written ? available : count - written;
      bytes.setRange(written, written + amount, _current, _offset);
      written += amount;
      _offset += amount;
    }
    return bytes;
  }

  Future<bool> hasMore() async {
    if (_offset < _current.length) return true;
    while (await _iterator.moveNext()) {
      if (_iterator.current.isNotEmpty) return true;
    }
    return false;
  }

  Future<void> cancel() => _iterator.cancel();
}
