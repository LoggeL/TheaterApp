import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../domain/account_roster.dart';

/// Loads people, accounts and productions of the admin account list.
Future<AccountRoster> fetchRoster(AppController c) async =>
    AccountRoster(jsonMap(await c.remote('/admin/accounts')));

/// Generates a link online; never saves it in the cache or offline queue.
Future<JsonMap> generatePasswordResetLink(
  AppController c,
  JsonMap account,
) => c.remote(
  '/admin/accounts/${Uri.encodeComponent(textValue(account['uid']))}/password-reset-link',
  method: 'POST',
  body: {'version': account['version']},
);
