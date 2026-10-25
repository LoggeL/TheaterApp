import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// Private form data is loaded on demand and never enters the snapshot cache
/// or offline outbox. The server remains authoritative for every submission.
class FormsApi {
  const FormsApi(this.controller);

  final AppController controller;

  Future<List<JsonMap>> templates() async => jsonList(
    (await controller.remote('/forms/templates'))['templates'],
  ).map(jsonMap).toList();

  Future<JsonMap> save(JsonMap template, {String? idempotencyKey}) async {
    final body = <String, dynamic>{...template, 'action': 'form.save'};
    final result = idempotencyKey == null
        ? await controller.performActionOnline(body)
        : await controller.remote(
            '/actions',
            method: 'POST',
            body: body,
            idempotencyKey: idempotencyKey,
          );
    return jsonMap(result['template']);
  }

  Future<void> archive(JsonMap template, bool archived) async {
    await controller.performActionOnline({
      'action': 'form.archive',
      'id': template['id'],
      'version': template['version'],
      'archived': archived,
    });
  }

  Future<JsonMap> message(String messageId) =>
      controller.remote('/forms/messages/${Uri.encodeComponent(messageId)}');

  Future<List<JsonMap>> submissions(String messageId) async => jsonList(
    (await controller.remote(
      '/forms/messages/${Uri.encodeComponent(messageId)}/submissions',
    ))['submissions'],
  ).map(jsonMap).toList();

  Future<JsonMap> submit(JsonMap response, {required String idempotencyKey}) =>
      controller.remote(
        '/actions',
        method: 'POST',
        body: {...response, 'action': 'form.submit'},
        idempotencyKey: idempotencyKey,
      );

  Future<void> withdraw(
    JsonMap submission, {
    required String idempotencyKey,
    bool forAdmin = false,
  }) async {
    final result = await controller.remote(
      '/actions',
      method: 'POST',
      body: {
        'action': 'form.withdraw',
        'messageId': submission['messageId'],
        'submittedAt': submission['submittedAt'],
        'receiptId': submission['receiptId'],
        if (forAdmin) 'personId': submission['personId'],
      },
      idempotencyKey: idempotencyKey,
    );
    if (result['ok'] != true) {
      throw 'Die Löschung wurde vom Server nicht bestätigt. Bitte erneut versuchen.';
    }
  }
}
