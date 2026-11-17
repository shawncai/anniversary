import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'calendar.dart';

String newId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Uint8List randomBytes(int count) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(count, (_) => random.nextInt(256)));
}

Map<String, dynamic> jsonObject(dynamic value) {
  if (value is! Map<String, dynamic>) throw const FormatException('无效 JSON 对象');
  return value;
}

String requiredString(
  Map<String, dynamic> value,
  String key, {
  int max = 1024,
}) {
  final result = value[key];
  if (result is! String ||
      result.isEmpty ||
      result.length > max ||
      result.contains('\u0000')) {
    throw FormatException('无效字段 $key');
  }
  return result;
}

int requiredInt(
  Map<String, dynamic> value,
  String key, {
  int min = 0,
  int max = 1 << 53,
}) {
  final result = value[key];
  if (result is! int || result < min || result > max)
    throw FormatException('无效字段 $key');
  return result;
}

String validatedHash(String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value))
    throw const FormatException('无效文件摘要');
  return value;
}

String validatedId(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value))
    throw const FormatException('无效标识');
  return value;
}

enum CoverMode { fixed, slideshow, daily, interval }

enum CoverSource { all, year, selection }

class Anniversary {
  Anniversary({
    required this.id,
    required this.title,
    required this.startDate,
    this.coverPhotoId,
    this.windowDays = 1,
    this.repeatYearly = true,
    this.reminderEnabled = false,
    this.reminderMinute = 540,
    this.coverMode = CoverMode.fixed,
    this.coverSource = CoverSource.all,
    this.coverYear,
    List<String> coverPhotoIds = const [],
    this.coverIntervalSeconds = 10,
    this.coverChangeMinute = 540,
  }) : coverPhotoIds = List.unmodifiable(coverPhotoIds) {
    validatedId(id);
    if (title.trim().isEmpty ||
        title.length > 200 ||
        title.contains('\u0000')) {
      throw const FormatException('请输入 1–200 字的纪念日名称');
    }
    if (windowDays < 0 || windowDays > 31)
      throw const FormatException('归集范围必须在 0–31 天内');
    if (coverPhotoId != null) validatedHash(coverPhotoId!);
    if (reminderMinute < 0 ||
        reminderMinute > 1439 ||
        coverChangeMinute < 0 ||
        coverChangeMinute > 1439 ||
        coverIntervalSeconds < 5 ||
        coverIntervalSeconds > 86400 ||
        (coverYear != null && (coverYear! < 1 || coverYear! > 9999))) {
      throw const FormatException('无效的时间设置');
    }
    if (coverPhotoIds.length > 200000 ||
        coverPhotoIds.toSet().length != coverPhotoIds.length)
      throw const FormatException('无效封面组');
    for (final id in coverPhotoIds) {
      validatedHash(id);
    }
  }
  final String id;
  final String title;
  final CalendarDate startDate;
  final String? coverPhotoId;
  final int windowDays;
  final bool repeatYearly;
  final bool reminderEnabled;
  final int reminderMinute;
  final CoverMode coverMode;
  final CoverSource coverSource;
  final int? coverYear;
  final List<String> coverPhotoIds;
  final int coverIntervalSeconds;
  final int coverChangeMinute;

  Anniversary copyWith({
    String? title,
    CalendarDate? startDate,
    String? coverPhotoId,
    bool clearCover = false,
    int? windowDays,
    bool? repeatYearly,
    bool? reminderEnabled,
    int? reminderMinute,
    CoverMode? coverMode,
    CoverSource? coverSource,
    int? coverYear,
    List<String>? coverPhotoIds,
    int? coverIntervalSeconds,
    int? coverChangeMinute,
  }) => Anniversary(
    id: id,
    title: title ?? this.title,
    startDate: startDate ?? this.startDate,
    coverPhotoId: clearCover ? null : coverPhotoId ?? this.coverPhotoId,
    windowDays: windowDays ?? this.windowDays,
    repeatYearly: repeatYearly ?? this.repeatYearly,
    reminderEnabled: reminderEnabled ?? this.reminderEnabled,
    reminderMinute: reminderMinute ?? this.reminderMinute,
    coverMode: coverMode ?? this.coverMode,
    coverSource: coverSource ?? this.coverSource,
    coverYear: coverYear ?? this.coverYear,
    coverPhotoIds: coverPhotoIds ?? this.coverPhotoIds,
    coverIntervalSeconds: coverIntervalSeconds ?? this.coverIntervalSeconds,
    coverChangeMinute: coverChangeMinute ?? this.coverChangeMinute,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'startDate': startDate.iso,
    'coverPhotoId': coverPhotoId,
    'windowDays': windowDays,
    'repeatYearly': repeatYearly,
    'reminderEnabled': reminderEnabled,
    'reminderMinute': reminderMinute,
    'coverMode': coverMode.name,
    'coverSource': coverSource.name,
    'coverYear': coverYear,
    'coverPhotoIds': coverPhotoIds,
    'coverIntervalSeconds': coverIntervalSeconds,
    'coverChangeMinute': coverChangeMinute,
  };
  factory Anniversary.fromJson(Map<String, dynamic> json) => Anniversary(
    id: requiredString(json, 'id', max: 128),
    title: requiredString(json, 'title', max: 200),
    startDate: CalendarDate.parse(requiredString(json, 'startDate', max: 10)),
    coverPhotoId: json['coverPhotoId'] as String?,
    windowDays: requiredInt(json, 'windowDays', max: 31),
    repeatYearly: json['repeatYearly'] as bool? ?? true,
    reminderEnabled: json['reminderEnabled'] as bool? ?? false,
    reminderMinute: json['reminderMinute'] as int? ?? 540,
    coverMode: CoverMode.values.byName(json['coverMode'] as String? ?? 'fixed'),
    coverSource: CoverSource.values.byName(
      json['coverSource'] as String? ?? 'all',
    ),
    coverYear: json['coverYear'] as int?,
    coverPhotoIds: (json['coverPhotoIds'] as List? ?? []).cast<String>(),
    coverIntervalSeconds: json['coverIntervalSeconds'] as int? ?? 10,
    coverChangeMinute: json['coverChangeMinute'] as int? ?? 540,
  );
}

class PhotoInput {
  const PhotoInput({
    required this.sourceId,
    required this.originalPath,
    required this.thumbnailPath,
    required this.capturedAt,
    required this.originalName,
    required this.mimeType,
  });
  final String sourceId;
  final String originalPath;
  final String thumbnailPath;
  final DateTime capturedAt;
  final String originalName;
  final String mimeType;
  factory PhotoInput.fromMap(Map<String, dynamic> map) =>
      PhotoInput.fromJson(map);
  factory PhotoInput.fromJson(Map<String, dynamic> json) => PhotoInput(
    sourceId: requiredString(json, 'sourceId'),
    originalPath: requiredString(json, 'originalPath', max: 4096),
    thumbnailPath: requiredString(json, 'thumbnailPath', max: 4096),
    capturedAt: DateTime.parse(requiredString(json, 'capturedAt')),
    originalName: requiredString(json, 'originalName'),
    mimeType: requiredString(json, 'mimeType', max: 200),
  );
}

class MemoryPhoto {
  MemoryPhoto({
    required this.id,
    required this.sourceId,
    required this.capturedAt,
    required this.originalName,
    required this.mimeType,
    required this.originalHash,
    required this.thumbnailHash,
    required this.originalBytes,
    required this.thumbnailBytes,
  }) {
    validatedHash(id);
    validatedHash(originalHash);
    validatedHash(thumbnailHash);
    if (id != originalHash ||
        originalBytes <= 0 ||
        thumbnailBytes <= 0 ||
        sourceId.length > 1024 ||
        originalName.isEmpty ||
        originalName.length > 1024 ||
        mimeType.isEmpty ||
        mimeType.length > 200) {
      throw const FormatException('无效照片资料');
    }
  }
  final String id;
  final String sourceId;
  final DateTime capturedAt;
  final String originalName;
  final String mimeType;
  final String originalHash;
  final String thumbnailHash;
  final int originalBytes;
  final int thumbnailBytes;
  CalendarDate get date => CalendarDate.fromDateTime(capturedAt.toLocal());
  String get originalRelativePath => 'originals/$originalHash.bin';
  String get thumbnailRelativePath => 'thumbnails/$thumbnailHash.jpg';
  MemoryPhoto withDate(DateTime value) => MemoryPhoto(
    id: id,
    sourceId: sourceId,
    capturedAt: value,
    originalName: originalName,
    mimeType: mimeType,
    originalHash: originalHash,
    thumbnailHash: thumbnailHash,
    originalBytes: originalBytes,
    thumbnailBytes: thumbnailBytes,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'capturedAt': capturedAt.toIso8601String(),
    'originalName': originalName,
    'mimeType': mimeType,
    'originalHash': originalHash,
    'thumbnailHash': thumbnailHash,
    'originalBytes': originalBytes,
    'thumbnailBytes': thumbnailBytes,
  };
  factory MemoryPhoto.fromJson(Map<String, dynamic> json) => MemoryPhoto(
    id: requiredString(json, 'id'),
    sourceId: requiredString(json, 'sourceId'),
    capturedAt: DateTime.parse(requiredString(json, 'capturedAt', max: 64)),
    originalName: requiredString(json, 'originalName'),
    mimeType: requiredString(json, 'mimeType', max: 200),
    originalHash: requiredString(json, 'originalHash'),
    thumbnailHash: requiredString(json, 'thumbnailHash'),
    originalBytes: requiredInt(json, 'originalBytes', min: 1),
    thumbnailBytes: requiredInt(json, 'thumbnailBytes', min: 1),
  );
}

enum AssociationStatus { pending, confirmed, excluded }

class PhotoAssociation {
  const PhotoAssociation({
    required this.eventId,
    required this.photoId,
    required this.status,
  });
  final String eventId;
  final String photoId;
  final AssociationStatus status;
  String get key => '$eventId:$photoId';
  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'photoId': photoId,
    'status': status.name,
  };
  factory PhotoAssociation.fromJson(Map<String, dynamic> json) =>
      PhotoAssociation(
        eventId: validatedId(requiredString(json, 'eventId')),
        photoId: validatedHash(requiredString(json, 'photoId')),
        status: AssociationStatus.values.byName(requiredString(json, 'status')),
      );
}

class LibraryState {
  LibraryState({
    List<Anniversary> events = const [],
    List<MemoryPhoto> photos = const [],
    List<PhotoAssociation> associations = const [],
    this.selectedEventId,
    this.lastBackupAt,
  }) : events = List.unmodifiable(events),
       photos = List.unmodifiable(photos),
       associations = List.unmodifiable(associations) {
    final eventIds = this.events.map((e) => e.id).toSet();
    final photoIds = this.photos.map((e) => e.id).toSet();
    final confirmed = this.associations
        .where((a) => a.status == AssociationStatus.confirmed)
        .map((a) => a.key)
        .toSet();
    if (eventIds.length != this.events.length ||
        photoIds.length != this.photos.length ||
        this.associations.map((a) => a.key).toSet().length !=
            this.associations.length ||
        (selectedEventId != null && !eventIds.contains(selectedEventId))) {
      throw const FormatException('资料中存在重复或无效关联');
    }
    for (final association in this.associations) {
      if (!eventIds.contains(association.eventId) ||
          !photoIds.contains(association.photoId)) {
        throw const FormatException('找不到照片关联');
      }
    }
    for (final event in this.events) {
      if (event.coverPhotoIds.any(
        (id) => !confirmed.contains('${event.id}:$id'),
      ))
        throw const FormatException('封面组必须来自已确认照片');
      if (event.coverPhotoId != null &&
          !confirmed.contains('${event.id}:${event.coverPhotoId}')) {
        throw const FormatException('封面必须来自已确认照片');
      }
    }
  }

  final List<Anniversary> events;
  final List<MemoryPhoto> photos;
  final List<PhotoAssociation> associations;
  final String? selectedEventId;
  final DateTime? lastBackupAt;
  Anniversary? get selectedEvent {
    for (final e in events) {
      if (e.id == selectedEventId) return e;
    }
    return events.isEmpty ? null : events.first;
  }

  int get mediaBytes {
    final seen = <String>{};
    var total = 0;
    for (final p in photos) {
      if (seen.add(p.originalRelativePath)) total += p.originalBytes;
      if (seen.add(p.thumbnailRelativePath)) total += p.thumbnailBytes;
    }
    return total;
  }

  List<MemoryPhoto> photosFor(
    String eventId, {
    AssociationStatus status = AssociationStatus.confirmed,
  }) {
    final ids = associations
        .where((a) => a.eventId == eventId && a.status == status)
        .map((a) => a.photoId)
        .toSet();
    return photos.where((p) => ids.contains(p.id)).toList()
      ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
  }

  LibraryState copyWith({
    List<Anniversary>? events,
    List<MemoryPhoto>? photos,
    List<PhotoAssociation>? associations,
    String? selectedEventId,
    DateTime? lastBackupAt,
  }) => LibraryState(
    events: events ?? this.events,
    photos: photos ?? this.photos,
    associations: associations ?? this.associations,
    selectedEventId: selectedEventId ?? this.selectedEventId,
    lastBackupAt: lastBackupAt ?? this.lastBackupAt,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'events': events.map((e) => e.toJson()).toList(),
    'photos': photos.map((e) => e.toJson()).toList(),
    'associations': associations.map((e) => e.toJson()).toList(),
    'selectedEventId': selectedEventId,
    'lastBackupAt': lastBackupAt?.toIso8601String(),
  };
  factory LibraryState.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('不支持的资料版本');
    for (final key in ['events', 'photos', 'associations']) {
      if (json[key] is! List || (json[key] as List).length > 200000) {
        throw const FormatException('资料数量超过限制');
      }
    }
    return LibraryState(
      events: (json['events'] as List)
          .map((e) => Anniversary.fromJson(jsonObject(e)))
          .toList(),
      photos: (json['photos'] as List)
          .map((e) => MemoryPhoto.fromJson(jsonObject(e)))
          .toList(),
      associations: (json['associations'] as List)
          .map((e) => PhotoAssociation.fromJson(jsonObject(e)))
          .toList(),
      selectedEventId: json['selectedEventId'] as String?,
      lastBackupAt: json['lastBackupAt'] == null
          ? null
          : DateTime.parse(json['lastBackupAt'] as String),
    );
  }
}

bool sameJson(Map<String, dynamic> first, Map<String, dynamic> second) =>
    jsonEncode(first) == jsonEncode(second);
