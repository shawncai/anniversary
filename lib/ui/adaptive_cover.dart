import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CoverInk {
  const CoverInk(this.light, this.scrimOpacity, [this.coverage = 1]);
  final double coverage;
  final bool light;
  final double scrimOpacity;
  Color get color => light ? Colors.white : const Color(0xFF141414);
  Color get scrim => light ? Colors.black : Colors.white;
}

/// Samples the rendered crop behind actual text blocks; mixed regions receive
/// a local scrim. The choice is stable until image/layout changes, never per frame.
class AdaptiveCover extends StatefulWidget {
  const AdaptiveCover({
    super.key,
    required this.file,
    required this.height,
    required this.builder,
    this.onInk,
    this.textKeys = const [],
  });
  final File? file;
  final List<GlobalKey> textKeys;
  final double height;
  final Widget Function(BuildContext, Color) builder;
  final ValueChanged<bool>? onInk;
  @override
  State<AdaptiveCover> createState() => _AdaptiveCoverState();
}

class _AdaptiveCoverState extends State<AdaptiveCover> {
  CoverInk _ink = const CoverInk(true, .7);
  final _surfaceKey = GlobalKey();
  @override
  void initState() {
    super.initState();
    if (widget.file == null) _ink = const CoverInk(false, 0);
  }

  @override
  void didUpdateWidget(covariant AdaptiveCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file?.path != widget.file?.path) {
      _key = null;
      _ink = widget.file == null
          ? const CoverInk(false, 0)
          : const CoverInk(true, .7);
    }
  }

  List<Rect> _textRegions(Size target) {
    final surface = _surfaceKey.currentContext?.findRenderObject();
    final regions = <Rect>[];
    if (surface is RenderBox && surface.hasSize) {
      for (final key in widget.textKeys) {
        final text = key.currentContext?.findRenderObject();
        if (text is RenderBox && text.hasSize && text.attached) {
          final bounds = MatrixUtils.transformRect(
            text.getTransformTo(surface),
            Offset.zero & text.size,
          ).inflate(3).intersect(Offset.zero & target);
          if (!bounds.isEmpty)
            regions.add(
              Rect.fromLTRB(
                bounds.left / target.width,
                bounds.top / target.height,
                bounds.right / target.width,
                bounds.bottom / target.height,
              ),
            );
        }
      }
    }
    // Missing layout keys use a conservative full cover sample, never a guessed
    // fixed rectangle that could miss the real title after text scaling.
    return regions.isEmpty ? [const Rect.fromLTWH(0, 0, 1, 1)] : regions;
  }

  String? _key;
  int _generation = 0;

  double _luminance(double r, double g, double b) {
    double f(double c) =>
        c <= .04045 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();
    return .2126 * f(r) + .7152 * f(g) + .0722 * f(b);
  }

  Future<void> _analyze(Size target) async {
    final path = widget.file?.path;
    final regions = _textRegions(target);
    final coverage = (regions.map((r) => r.right).reduce(math.max) + .03).clamp(
      0.0,
      1.0,
    );
    final key =
        '$path:${target.width.round()}:${target.height.round()}:$regions';
    if (_key == key) return;
    _key = key;
    final generation = ++_generation;
    if (path == null) {
      if (mounted) setState(() => _ink = const CoverInk(false, 0));
      return;
    }
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        await File(path).readAsBytes(),
        targetWidth: 180,
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return;
      final fit = applyBoxFit(
        BoxFit.cover,
        Size(image.width.toDouble(), image.height.toDouble()),
        target,
      );
      final source = Alignment.center.inscribe(
        fit.source,
        Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
      );
      final pixels = <(double, double, double)>[];
      // Actual render-box geometry includes crop, text scaling and FittedBox transforms.
      for (final rect in regions) {
        for (double y = rect.top; y < rect.bottom; y += .015) {
          for (double x = rect.left; x < rect.right; x += .015) {
            final px = (source.left + x * source.width).floor().clamp(
              0,
              image.width - 1,
            );
            final py = (source.top + y * source.height).floor().clamp(
              0,
              image.height - 1,
            );
            final i = (py * image.width + px) * 4;
            pixels.add((
              data.getUint8(i) / 255,
              data.getUint8(i + 1) / 255,
              data.getUint8(i + 2) / 255,
            ));
          }
        }
      }
      CoverInk? choice;
      for (var step = 0; step <= 14 && choice == null; step++) {
        final opacity = step * .05;
        for (final light in [true, false]) {
          var minimum = double.infinity;
          for (final p in pixels) {
            final bg = light ? 0.0 : 1.0;
            final l = _luminance(
              p.$1 * (1 - opacity) + bg * opacity,
              p.$2 * (1 - opacity) + bg * opacity,
              p.$3 * (1 - opacity) + bg * opacity,
            );
            final contrast = light
                ? 1.05 / (l + .05)
                : (l + .05) / (.0069954102 + .05);
            minimum = math.min(minimum, contrast);
          }
          if (minimum >= 4.5) {
            choice = CoverInk(light, opacity, coverage);
            break;
          }
        }
      }
      if (mounted && generation == _generation) {
        final result = choice ?? const CoverInk(true, .7);
        setState(() => _ink = result);
        widget.onInk?.call(result.light);
      }
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() => _ink = const CoverInk(true, .65));
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _analyze(Size(constraints.maxWidth, widget.height));
      });
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: _ink.light
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: _ink.light ? Brightness.dark : Brightness.light,
        ),
        child: SizedBox(
          key: _surfaceKey,
          height: widget.height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.file != null)
                Image.file(
                  widget.file!,
                  fit: BoxFit.cover,
                  cacheWidth: 1400,
                  errorBuilder: (_, __, ___) =>
                      const ColoredBox(color: Color(0xFF343C4B)),
                )
              else
                const ColoredBox(color: Color(0xFFF4F4F6)),
              if (widget.file != null && _ink.scrimOpacity > 0)
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _ink.scrim.withValues(alpha: _ink.scrimOpacity),
                        _ink.scrim.withValues(alpha: _ink.scrimOpacity),
                        _ink.scrim.withValues(alpha: 0),
                      ],
                      stops: [0, _ink.coverage, 1],
                    ),
                  ),
                ),
              widget.builder(context, _ink.color),
            ],
          ),
        ),
      );
    },
  );
}
