import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'repository.dart';

const archiveChunkBytes = 64 * 1024;
const maxArchiveBytes = 64 * 1024 * 1024 * 1024;
const maxArchiveFiles = 100000;
final _magic = ascii.encode('SHIRI001');

class DigestCollector implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

class ImportPreview {
  ImportPreview._(this.library, this.counts, this._staging, this._owner);
  final LibraryState library;
  final MergeCounts counts;
  final Directory _staging;
  final ArchiveService _owner;
  bool _consumed = false;
  int get newEvents => counts.newEvents;
  int get newPhotos => counts.newPhotos;
  int get duplicatePhotos => counts.duplicatePhotos;
  int get newAssociations => counts.newAssociations;
  List<String> get conflicts => counts.conflicts;
  Future<void> dispose() async {
    _consumed = true;
    if (await _staging.exists()) await _staging.delete(recursive: true);
  }
}

class _ArchiveEntry {
  const _ArchiveEntry(this.path, this.length, this.hash);
  final String path;
  final int length;
  final String hash;
  Map<String, dynamic> toJson() => {
    'path': path,
    'length': length,
    'sha256': hash,
  };
  factory _ArchiveEntry.fromJson(Map<String, dynamic> json) {
    final path = requiredString(json, 'path', max: 100);
    // Exact allowlist; no arbitrary paths, separators, archive nesting or links.
    if (!RegExp(
      r'^(originals/[0-9a-f]{64}\.bin|thumbnails/[0-9a-f]{64}\.jpg)$',
    ).hasMatch(path)) {
      throw const FormatException('备份中含不安全文件路径');
    }
    final hash = validatedHash(requiredString(json, 'sha256', max: 64));
    if (path.substring(path.indexOf('/') + 1, path.lastIndexOf('.')) != hash) {
      throw const FormatException('文件名与摘要不一致');
    }
    return _ArchiveEntry(
      path,
      requiredInt(
        json,
        'length',
        min: 1,
        max: path.startsWith('originals/')
            ? maxOriginalBytes
            : maxThumbnailBytes,
      ),
      hash,
    );
  }
}

List<_ArchiveEntry> _entriesFor(LibraryState state) {
  final entries = <String, _ArchiveEntry>{};
  for (final photo in state.photos) {
    for (final entry in [
      _ArchiveEntry(
        photo.originalRelativePath,
        photo.originalBytes,
        photo.originalHash,
      ),
      _ArchiveEntry(
        photo.thumbnailRelativePath,
        photo.thumbnailBytes,
        photo.thumbnailHash,
      ),
    ]) {
      final existing = entries[entry.path];
      if (existing != null && existing.length != entry.length)
        throw const FormatException('重复文件长度不一致');
      entries[entry.path] = entry;
    }
  }
  return entries.values.toList()..sort((a, b) => a.path.compareTo(b.path));
}

/// .shiri v1: SHIRI001 | uint32BE manifest length | manifest SHA256 (32 bytes)
/// | UTF8 JSON manifest | raw media concatenated in manifest order.
/// Manifest contains library metadata plus each media path, byte length and SHA256.
/// No compression avoids decompression bombs. Peak media buffer is 64 KiB.
class ArchiveService {
  ArchiveService(this.repository);
  final LibraryRepository repository;

  Future<File> exportTo(
    File destination, {
    void Function(double)? onProgress,
  }) async {
    if (await destination.exists()) throw const FileSystemException('导出目标已存在');
    final state = repository.state;
    final entries = _entriesFor(state);
    if (entries.length > maxArchiveFiles)
      throw const FormatException('照片数量超过备份限制');
    final totalMedia = entries.fold<int>(0, (sum, e) => sum + e.length);
    final manifest = utf8.encode(
      jsonEncode({
        'format': 'shiri',
        'version': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'library': state.toJson(),
        'files': entries.map((e) => e.toJson()).toList(),
      }),
    );
    if (manifest.length > maxLibraryJsonBytes ||
        totalMedia + manifest.length + 44 > maxArchiveBytes) {
      throw const FormatException('备份超过大小限制');
    }
    final temporary = File('${destination.path}.partial-${newId()}');
    await destination.parent.create(recursive: true);
    RandomAccessFile? output;
    var copied = 0;
    try {
      output = await temporary.open(mode: FileMode.write);
      final length = ByteData(4)..setUint32(0, manifest.length, Endian.big);
      await output.writeFrom(_magic);
      await output.writeFrom(length.buffer.asUint8List());
      await output.writeFrom(sha256.convert(manifest).bytes);
      await output.writeFrom(manifest);
      for (final entry in entries) {
        final file = File('${repository.directory.path}/${entry.path}');
        if (!await file.exists() || await file.length() != entry.length) {
          throw const FormatException('缺少原图或缩略图，无法导出完整备份');
        }
        final collector = DigestCollector();
        final hasher = sha256.startChunkedConversion(collector);
        var written = 0;
        await for (final chunk in file.openRead()) {
          written += chunk.length;
          if (written > entry.length) throw const FormatException('导出期间文件发生变化');
          hasher.add(chunk);
          await output.writeFrom(chunk);
          copied += chunk.length;
          onProgress?.call(totalMedia == 0 ? 1 : copied / totalMedia);
        }
        hasher.close();
        if (written != entry.length ||
            collector.value.toString() != entry.hash) {
          throw const FormatException('原图或缩略图校验失败');
        }
      }
      await output.flush();
      await output.close();
      output = null;
      await temporary.rename(destination.path);
      onProgress?.call(1);
      return destination;
    } finally {
      await output?.close();
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// Reads and validates every byte before returning a preview. Existing library
  /// state and media are untouched; cancel disposes only this import's staging.
  Future<ImportPreview> previewImport(
    File source, {
    void Function(double)? onProgress,
  }) async {
    final size = await source.length();
    if (size < 44 || size > maxArchiveBytes)
      throw const FormatException('备份大小不受支持');
    final input = await source.open();
    Directory? staging;
    try {
      final magic = await _readExactly(input, 8);
      if (!_equalBytes(magic, _magic)) throw const FormatException('不是拾日备份');
      final lengthBytes = await _readExactly(input, 4);
      final manifestLength = ByteData.sublistView(
        lengthBytes,
      ).getUint32(0, Endian.big);
      if (manifestLength == 0 ||
          manifestLength > maxLibraryJsonBytes ||
          manifestLength > size - 44) {
        throw const FormatException('备份清单大小无效');
      }
      final expectedManifestHash = await _readExactly(input, 32);
      final manifestBytes = await _readExactly(input, manifestLength);
      if (!_equalBytes(
        expectedManifestHash,
        sha256.convert(manifestBytes).bytes,
      )) {
        throw const FormatException('备份清单损坏');
      }
      final manifest = jsonObject(jsonDecode(utf8.decode(manifestBytes)));
      if (manifest['format'] != 'shiri' || manifest['version'] != 1) {
        throw const FormatException('不支持的备份版本');
      }
      final files = manifest['files'];
      if (files is! List || files.length > maxArchiveFiles)
        throw const FormatException('备份文件数量超限');
      final incoming = LibraryState.fromJson(jsonObject(manifest['library']));
      final entries = files
          .map((e) => _ArchiveEntry.fromJson(jsonObject(e)))
          .toList();
      final expected = {for (final e in _entriesFor(incoming)) e.path: e};
      if (entries.length != expected.length ||
          entries.map((e) => e.path).toSet().length != entries.length) {
        throw const FormatException('备份文件缺失或重复');
      }
      var expectedSize = 44 + manifestLength;
      for (final entry in entries) {
        final declaration = expected[entry.path];
        if (declaration == null ||
            declaration.hash != entry.hash ||
            declaration.length != entry.length) {
          throw const FormatException('照片与备份清单不一致');
        }
        expectedSize += entry.length;
        if (expectedSize > maxArchiveBytes)
          throw const FormatException('备份总大小超限');
      }
      if (expectedSize != size) throw const FormatException('备份被截断或包含多余数据');
      staging = await Directory(
        '${repository.directory.path}/staging',
      ).createTemp('import-');
      await Directory('${staging.path}/originals').create();
      await Directory('${staging.path}/thumbnails').create();
      var copied = 44 + manifestLength;
      for (final entry in entries) {
        final output = await File(
          '${staging.path}/${entry.path}',
        ).open(mode: FileMode.write);
        final collector = DigestCollector();
        final hasher = sha256.startChunkedConversion(collector);
        try {
          var remaining = entry.length;
          while (remaining > 0) {
            final count = remaining < archiveChunkBytes
                ? remaining
                : archiveChunkBytes;
            final chunk = await _readExactly(input, count);
            hasher.add(chunk);
            await output.writeFrom(chunk);
            remaining -= chunk.length;
            copied += chunk.length;
            onProgress?.call(copied / size);
          }
          hasher.close();
          if (collector.value.toString() != entry.hash)
            throw const FormatException('备份照片校验失败');
          await output.flush();
        } finally {
          await output.close();
        }
      }
      if ((await input.read(1)).isNotEmpty)
        throw const FormatException('备份含多余数据');
      final preview = ImportPreview._(
        incoming,
        compareLibraries(repository.state, incoming),
        staging,
        this,
      );
      staging = null; // Ownership passes to preview, which must be disposed.
      onProgress?.call(1);
      return preview;
    } finally {
      await input.close();
      if (staging != null && await staging.exists())
        await staging.delete(recursive: true);
    }
  }

  Future<MergeCounts> applyImport(ImportPreview preview) async {
    if (!identical(preview._owner, this) || preview._consumed)
      throw StateError('导入预览已过期');
    preview._consumed = true;
    try {
      return await repository.mergeValidated(preview.library, preview._staging);
    } finally {
      await preview.dispose();
    }
  }
}

Future<Uint8List> _readExactly(RandomAccessFile input, int count) async {
  final bytes = Uint8List(count);
  var offset = 0;
  while (offset < count) {
    final read = await input.readInto(bytes, offset, count);
    if (read == 0) throw const FormatException('备份被截断');
    offset += read;
  }
  return bytes;
}

bool _equalBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
