import 'package:flutter/material.dart';

/// Solid white tick remains legible over both bright and dark photographs.
class PhotoSelectionMark extends StatelessWidget {
  const PhotoSelectionMark({super.key, required this.selected});
  final bool selected;
  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: selected ? Theme.of(context).colorScheme.primary : Colors.black26,
      border: selected ? null : Border.all(color: Colors.white, width: 1.5),
    ),
    child: selected
        ? const Icon(Icons.check, size: 18, color: Colors.white)
        : null,
  );
}
