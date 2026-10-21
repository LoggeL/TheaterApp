import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../domain/account_roster.dart';

/// Loads people, accounts and productions of the admin account list.
Future<AccountRoster> fetchRoster(AppController c) async =>
    AccountRoster(jsonMap(await c.remote('/admin/accounts')));
