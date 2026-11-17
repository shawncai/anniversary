import 'calendar.dart';
import 'models.dart';

/// Deterministic selection: reopening the app does not restart a timed cover.
MemoryPhoto? coverPhoto(LibraryState state, Anniversary event, DateTime time) {
  final photos = state.photosFor(event.id);
  if (event.coverMode == CoverMode.fixed) {
    return photos.where((p) => p.id == event.coverPhotoId).firstOrNull ??
        photos.firstOrNull;
  }
  final candidates =
      photos
          .where(
            (p) => switch (event.coverSource) {
              CoverSource.all => true,
              CoverSource.year =>
                anniversaryYearForPhoto(
                      p.date,
                      event.startDate,
                      windowDays: event.windowDays,
                    ) ==
                    event.coverYear,
              CoverSource.selection => event.coverPhotoIds.contains(p.id),
            },
          )
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
  if (candidates.isEmpty) return null;
  final local = time.toLocal();
  final int step;
  if (event.coverMode == CoverMode.daily) {
    step =
        CalendarDate.fromDateTime(local).daysSince(CalendarDate(1970, 1, 1)) -
        (local.hour * 60 + local.minute < event.coverChangeMinute ? 1 : 0);
  } else {
    step = time.millisecondsSinceEpoch ~/ (event.coverIntervalSeconds * 1000);
  }
  return candidates[step % candidates.length];
}

bool reminderIsToday(Anniversary event, CalendarDate today) =>
    event.reminderEnabled &&
    today.compareTo(event.startDate) >= 0 &&
    (event.repeatYearly
        ? occurrenceInYear(event.startDate, today.year) == today
        : event.startDate == today);
