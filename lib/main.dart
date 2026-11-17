import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/repository.dart';
import 'platform/native_platform.dart';
import 'ui/app_controller.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const ShiriBootstrap());
}

class ShiriBootstrap extends StatefulWidget {
  const ShiriBootstrap({super.key});
  @override
  State<ShiriBootstrap> createState() => _ShiriBootstrapState();
}

class _ShiriBootstrapState extends State<ShiriBootstrap> {
  late Future<AppController> _future;
  AppController? _controller;
  @override
  void initState() {
    super.initState();
    _future = _open();
  }

  Future<AppController> _open() async {
    final native = NativePlatform();
    try {
      final paths = await native.paths();
      final repository = await LibraryRepository.open(
        Directory(paths['documents']!),
      );
      final controller = AppController(
        repository: repository,
        native: native,
        temporary: Directory(paths['temporary']!),
      );
      _controller = controller;
      final link = await native.initialLink();
      if (link != null) await controller.handleLink(link);
      unawaited(controller.syncWidgets());
      unawaited(controller.syncSavedReminders());
      return controller;
    } catch (_) {
      await native.dispose();
      rethrow;
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) unawaited(controller.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '拾日',
    debugShowCheckedModeBanner: false,
    theme: ShiriTheme.light,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: FutureBuilder<AppController>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasData) return AppShell(controller: snapshot.data!);
        if (snapshot.hasError)
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('暂时无法打开本机资料'),
                      const SizedBox(height: 12),
                      Text(
                        snapshot.error.toString(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () => setState(() => _future = _open()),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      },
    ),
  );
}
