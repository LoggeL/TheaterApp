part of '../../../core/app_controller.dart';

/// The signed-in member's profile.
extension ProfileController on AppController {
  Future<void> saveProfile({
    required String? avatarId,
    required int version,
  }) async {
    await remote(
      '/profile',
      method: 'PUT',
      body: {'avatarId': avatarId, 'profileVersion': version},
    );
    await refresh();
  }
}
