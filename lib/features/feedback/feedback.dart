/// Public API of the feedback feature: members send feedback about the app,
/// admins read it. Not to be confused with `shared/feedback.dart`, which
/// shows SnackBars and error texts.
library;

export 'data/feedback_api.dart' show feedbackAvailable;
export 'ui/feedback_admin_screen.dart';
export 'ui/feedback_form_screen.dart';
