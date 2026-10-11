import 'package:flutter/material.dart';

import '../../../../core/app_controller.dart';
import '../../../../core/models.dart';
import '../../../../shared/audience/audience_pickers.dart';

Widget messageAudience(AppController controller, JsonMap m) => AudienceBadge(
  controller: controller,
  roleIds: [for (final id in jsonList(m['roleIds'])) id.toString()],
  personIds: jsonList(m['recipientPersonIds']).map(intValue).toList(),
  productionIds: [for (final id in jsonList(m['productionIds'])) id.toString()],
);
