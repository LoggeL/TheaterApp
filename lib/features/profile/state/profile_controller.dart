part of '../../../core/app_controller.dart';

/// The signed-in member's profile.
extension ProfileController on AppController {
  /// [about] and [websiteHidden] stay unchanged when null.
  Future<void> saveProfile({
    required String? avatarId,
    required int version,
    String? about,
    bool? websiteHidden,
  }) async {
    await remote(
      '/profile',
      method: 'PUT',
      body: {
        'avatarId': avatarId,
        'profileVersion': version,
        'about': ?about,
        'websiteHidden': ?websiteHidden,
      },
    );
    await refresh();
  }
}
