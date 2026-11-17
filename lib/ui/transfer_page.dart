import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/archive.dart';
import '../core/models.dart';
import '../core/transfer.dart';
import 'app_controller.dart';
import 'app_shell.dart' show previewAndImport;
import 'theme.dart';

class TransferPage extends StatefulWidget {
  const TransferPage({
    super.key,
    required this.controller,
    required this.receive,
  });
  final AppController controller;
  final bool receive;
  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage>
    with WidgetsBindingObserver {
  AppController get c => widget.controller;
  final _addressInput = TextEditingController();
  final Map<String, Map<String, dynamic>> _devices = {};
  StreamSubscription<Map<String, dynamic>>? _discovery;
  StreamSubscription<String>? _discoveryErrors;
  StreamSubscription<TransferUpdate>? _updates;
  EncryptedTransferReceiver? _receiver;
  EncryptedTransferSender? _sender;
  String _host = '';
  String _name = '这部手机';
  String? _endpoint;
  String? _sas;
  String? _peer;
  String _status = '准备连接';
  String? _error;
  bool _working = false;
  bool _confirmed = false;
  bool _done = false;
  bool _closing = false;
  double? _progress;
  File? _sendArchive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _discovery = c.native.nearbyDevices.listen((device) {
      final host = device['host'];
      final port = device['port'];
      if (!mounted || host is! String || port is! num || port <= 0) return;
      setState(() => _devices['$host:$port'] = device);
    });
    _discoveryErrors = c.native.discoveryErrors.listen((message) {
      if (mounted) setState(() => _error = '$message，可输入地址连接');
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      interfaces.sort((a, b) {
        int rank(NetworkInterface n) =>
            n.name.contains('wlan') || n.name == 'en0' ? 0 : 1;
        return rank(a).compareTo(rank(b));
      });
      final addresses = interfaces
          .expand((e) => e.addresses)
          .where(
            (a) =>
                a.address.startsWith('10.') ||
                a.address.startsWith('192.168.') ||
                (a.rawAddress[0] == 172 &&
                    a.rawAddress[1] >= 16 &&
                    a.rawAddress[1] <= 31),
          )
          .toList();
      if (addresses.isEmpty) throw const FormatException('请连接 Wi-Fi 或另一部手机的热点');
      _host = addresses.first.address;
      _name = await c.native.deviceName();
      if (_closing) return;
      if (widget.receive) {
        _receiver = await EncryptedTransferReceiver.start(
          crypto: c.native,
          temporaryDirectory: c.temporary,
          deviceName: _name,
        );
        if (_closing) {
          await _receiver!.close();
          return;
        }
        _endpoint = '$_host:${_receiver!.port}';
        _updates = _receiver!.updates.listen(_onReceive);
      }
      if (mounted)
        setState(() => _status = widget.receive ? '等待发送设备' : '选择接收设备');
      try {
        final supported = await c.native.startDiscovery(
          name: _name,
          host: _host,
          port: _receiver?.port ?? 0,
        );
        if (!supported && mounted) setState(() => _error = '附近发现暂不可用，可输入地址连接');
      } catch (_) {
        if (mounted) setState(() => _error = '附近发现暂不可用，可输入地址连接');
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _error = _friendly(e);
          _status = '连接未启动';
        });
    }
  }

  String _friendly(Object e) => e is PlatformException
      ? e.message ?? '系统操作未完成'
      : e.toString().replaceFirst('FormatException: ', '');
  void _onReceive(TransferUpdate update) {
    if (!mounted || _closing) return;
    setState(() {
      _sas = update.sas ?? _sas;
      _peer = update.peerName ?? _peer;
      _progress = update.phase == TransferPhase.transferring
          ? update.progress
          : _progress;
      _status = switch (update.phase) {
        TransferPhase.waiting => '等待发送设备',
        TransferPhase.pairing => '请核对两台手机上的配对码',
        TransferPhase.ready => '已确认配对',
        TransferPhase.transferring => '正在接收原图与纪念日',
        TransferPhase.received => '校验完成',
        TransferPhase.cancelled => '已取消',
        TransferPhase.failed => '传输失败',
        TransferPhase.expired => '配对已过期',
      };
      if (update.phase == TransferPhase.failed ||
          update.phase == TransferPhase.expired) {
        _error = update.message ?? _status;
        _done = true;
      }
    });
    if (update.receivedFile != null) unawaited(_received(update.receivedFile!));
  }

  Future<void> _received(File file) async {
    try {
      await _receiver?.close();
      await c.native.stopDiscovery();
      if (!mounted || _closing) return;
      setState(() {
        _working = true;
        _status = '检查接收的备份';
      });
      await previewAndImport(context, c, file);
      if (mounted)
        setState(() {
          _done = true;
          _status = '接收完成';
          _progress = 1;
        });
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (await file.exists()) await file.delete();
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _connect(String address) async {
    if (_working || _sender != null) return;
    setState(() {
      _working = true;
      _error = null;
      _status = '建立加密连接';
    });
    try {
      final uri = Uri.tryParse(
        address.trim().startsWith('http://')
            ? address.trim()
            : 'http://${address.trim()}',
      );
      if (uri == null) throw const FormatException('地址格式应为 192.168.1.2:端口');
      final sender = await EncryptedTransferSender.connect(
        endpoint: uri,
        crypto: c.native,
        deviceName: _name,
      );
      if (_closing) {
        await sender.close();
        return;
      }
      _sender = sender;
      if (mounted)
        setState(() {
          _sas = sender.sas;
          _peer = sender.peerName;
          _status = '请核对两台手机上的配对码';
        });
    } catch (e) {
      if (mounted)
        setState(() {
          _error = _friendly(e);
          _status = '连接未完成';
        });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (widget.receive) {
        await _receiver!.confirm();
        if (mounted)
          setState(() {
            _confirmed = true;
            _status = '等待对方确认并发送';
          });
      } else {
        await _sender!.confirm();
        if (mounted)
          setState(() {
            _confirmed = true;
            _status = '等待对方确认';
          });
        await _sender!.waitForPeerConfirmation();
        if (_closing) return;
        if (mounted) setState(() => _status = '准备完整备份');
        _sendArchive = File('${c.temporary.path}/send-${newId()}.shiri');
        await ArchiveService(c.repository).exportTo(_sendArchive!);
        if (_closing) return;
        if (mounted) setState(() => _status = '正在发送原图与纪念日');
        await _sender!.sendFile(
          _sendArchive!,
          onProgress: (value) {
            if (mounted && !_closing) setState(() => _progress = value);
          },
        );
        if (mounted)
          setState(() {
            _done = true;
            _status = '发送完成，对方将确认导入';
            _progress = 1;
          });
        await _sender!.close();
        await c.native.stopDiscovery();
      }
    } catch (e) {
      await _sender?.close();
      await _receiver?.close();
      await c.native.stopDiscovery().catchError((_) {});
      if (mounted && !_closing)
        setState(() {
          _error = _friendly(e);
          _done = true;
        });
    } finally {
      final file = _sendArchive;
      if (file != null && await file.exists()) await file.delete();
      _sendArchive = null;
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _stop() async {
    if (_closing) return;
    _closing = true;
    await _updates?.cancel();
    await _receiver?.close();
    await _sender?.close();
    await c.native.stopDiscovery().catchError((_) {});
    final file = _sendArchive;
    if (file != null && await file.exists()) await file.delete();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(_stop());
      if (mounted)
        setState(() {
          _done = true;
          _working = false;
          _status = '已停止传输';
          _error = '返回后重新进入互传页面即可连接';
        });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _addressInput.dispose();
    _discovery?.cancel();
    _discoveryErrors?.cancel();
    unawaited(_stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.receive ? '接收资料' : '发送资料')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(_status, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          const Text(
            '两部手机连接同一 Wi-Fi 或热点，并核对配对码。',
            style: TextStyle(color: ShiriTheme.muted, fontSize: 14),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFB42318)),
              ),
            ),
          if (_endpoint != null && _sas == null) ...[
            const SizedBox(height: 28),
            const Text('本机地址', style: TextStyle(color: ShiriTheme.muted)),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _endpoint!,
                    style: const TextStyle(fontSize: 21),
                  ),
                ),
                IconButton(
                  tooltip: '复制地址',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _endpoint!)),
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
          ],
          if (!widget.receive && _sas == null) ...[
            const SizedBox(height: 28),
            ..._devices.values.map(
              (d) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phone_android),
                title: Text(d['name'] as String? ?? '附近手机'),
                subtitle: Text('${d['host']}:${d['port']}'),
                onTap: _working
                    ? null
                    : () => _connect('${d['host']}:${d['port']}'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _addressInput,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '接收方地址',
                hintText: '192.168.1.2:端口',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _working ? null : () => _connect(_addressInput.text),
              child: const Text('连接'),
            ),
          ],
          if (_sas != null) ...[
            const SizedBox(height: 28),
            Text(
              _peer ?? '另一部手机',
              style: const TextStyle(color: ShiriTheme.muted),
            ),
            const SizedBox(height: 16),
            SelectableText(
              _sas!,
              style: const TextStyle(
                fontSize: 46,
                letterSpacing: 7,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 18),
            if (!_confirmed && !_done)
              FilledButton(
                onPressed: _working ? null : _confirm,
                child: const Text('两台配对码相同，确认连接'),
              ),
          ],
          if (_working || _progress != null) ...[
            const SizedBox(height: 28),
            LinearProgressIndicator(value: _progress?.clamp(0, 1)),
            if (_progress != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('${(_progress! * 100).floor()}%'),
              ),
          ],
          const SizedBox(height: 24),
          TextButton(
            onPressed: () async {
              await _stop();
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(_done ? '完成' : '取消传输'),
          ),
        ],
      ),
    ),
  );
}
