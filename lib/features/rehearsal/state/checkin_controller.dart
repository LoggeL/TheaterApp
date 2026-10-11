part of '../../../core/app_controller.dart';

/// Attendance check-in for a rehearsal.
extension CheckinController on AppController {
  Future<void> checkIn(String eventId, List<int> memberIds) async {
    if (_user?.isAdmin != true) {
      throw const ApiException(
        'Für den Check-in ist eine Adminrolle erforderlich.',
        statusCode: 403,
      );
    }
    if (!_events.any((e) => e.id == eventId)) {
      throw const ApiException(
        'Der Termin ist nicht verfügbar.',
        statusCode: 404,
      );
    }
    await _enqueue({
      'action': 'checkin.save',
      'eventId': eventId,
      'members': _members
          .where((m) => m.active)
          .map((m) => {'id': m.id, 'present': memberIds.contains(m.id)})
          .toList(),
    });
  }
}
