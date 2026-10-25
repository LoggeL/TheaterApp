import '../../../core/models.dart';

/// An editable starting point, never a published or server-saved template.
/// Each call returns new maps so edits cannot alter the next starting point.
JsonMap rehearsalWeekendPreset() => {
  'title': 'Anmeldung zur Probenfreizeit',
  'description': '',
  'deleteAfter': null,
  'fields': [
    {
      'id': 'participant_name',
      'type': 'text',
      'label': 'Name der teilnehmenden Person',
      'required': true,
    },
    {
      'id': 'health_details',
      'type': 'multiline',
      'label': 'Allergien, Unverträglichkeiten und Medikamenteneinnahme',
      'required': false,
    },
    {
      'id': 'age_at_event',
      'type': 'text',
      'label': 'Alter zu Beginn der Probenfreizeit',
      'required': true,
    },
    {
      'id': 'small_groups',
      'type': 'choice',
      'label':
          'Bei Minderjährigen: Mein Kind darf sich in Kleingruppen bewegen.',
      'required': true,
      'options': ['Ja', 'Nein', 'Nicht zutreffend'],
    },
    {
      'id': 'emergency_contact',
      'type': 'text',
      'label': 'Notfallkontakt (Name und Telefonnummer)',
      'required': true,
    },
    {
      'id': 'travel',
      'type': 'multiline',
      'label': 'Spätere Anreise oder frühere Abreise',
      'required': false,
    },
    {
      'id': 'notes',
      'type': 'multiline',
      'label': 'Weitere Hinweise',
      'required': false,
    },
    {
      'id': 'health_consent',
      'type': 'checkbox',
      'label':
          'Wenn ich Gesundheitsangaben mache, willige ich ausdrücklich ein, dass die Theaterleitung des Kolpingtheaters Ramsen diese zur sicheren Organisation und Betreuung der Probenfreizeit verarbeitet. Die Angaben sind freiwillig. Ich kann meine Einwilligung jederzeit für die Zukunft widerrufen, indem ich meine Abgabe lösche oder die Theaterleitung kontaktiere. Bei Angaben zu meinem minderjährigen Kind handle ich als sorgeberechtigte Person.',
      'required': true,
    },
  ],
  'signatureRequired': true,
  'confirmationText':
      'Ich bestätige die Angaben zu dieser Anmeldung und habe die oben aufgeführten Hinweise zur Kenntnis genommen. Bei einer Anmeldung für ein minderjähriges Kind bestätige ich als sorgeberechtigte Person.',
};
