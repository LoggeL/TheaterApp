/// One app version in "Was ist neu".
class ChangelogEntry {
  const ChangelogEntry({
    required this.version,
    required this.date,
    required this.items,
  });

  /// Version name as in pubspec.yaml, e.g. "0.7.0".
  final String version;

  /// Release date as shown to members, e.g. "18. Oktober 2026".
  final String date;

  /// Short points in everyday language.
  final List<String> items;
}

/// Was ist neu – newest version first.
///
/// Written for ensemble members, not developers: say in the "du" form what
/// they can do now or what got better. No technical terms (server, sync,
/// push token, refactoring …) and no internal rebuilds. Things only the
/// admins see go into one short "Für die Theaterleitung: …" point.
///
/// Add an entry with every version bump; a test checks that the first entry
/// matches the app version.
const changelog = [
  ChangelogEntry(
    version: '0.8.0',
    date: '18. Oktober 2026',
    items: [
      'Sprechen mehrere Rollen eine Textstelle gemeinsam, steht sie im '
          'Drehbuch jetzt bei jeder dieser Rollen – auch beim Lernen.',
      'Unter „Unser Ensemble“ hat jede Person ein eigenes Profil mit Foto, '
          'Rollen und Aufgaben hinter den Kulissen. Unter „Profil bearbeiten“ '
          'schreibst du ein paar Sätze über dich.',
      'Die Theaterleitung kann dir auf dein Feedback antworten. Unter „Mein '
          'Feedback“ liest du die Antworten und schreibst zurück.',
      'Alle Neuerungen findest du jetzt auch unter „Mein Bereich → App → '
          'Changelog“.',
      'Im Browser startet und läuft die App auf vielen Geräten flüssiger.',
      'Auswahlknöpfe brechen ihre Beschriftung nicht mehr mitten im Wort um.',
      'Für die Theaterleitung: unter „Ensembles & Verteiler“ festlegen, wer zu '
          'welchem Stück gehört – neu Hinzugefügte bekommen eine '
          'Benachrichtigung – und Feedback direkt beantworten.',
    ],
  ),
  ChangelogEntry(
    version: '0.7.1',
    date: '18. Oktober 2026',
    items: [
      'Neu: Über „Mein Bereich → Feedback geben“ schickst du Ideen, Fehler '
          'oder Anregungen direkt an die Theaterleitung.',
      'Wartest du noch auf deine Freigabe, kannst du schon Benachrichtigungen '
          'einschalten – dann erfährst du sofort, wenn dein Zugang '
          'freigegeben ist.',
      'Im Browser scrollst du jetzt spürbar flüssiger durch Termine, '
          'Mitteilungen und Listen.',
      'Für die Theaterleitung: das Feedback der Mitglieder in der Verwaltung '
          'lesen, neue Anmeldungen mit Google direkt zuordnen und die Termine '
          'eines Stücks mit einem Tipp nur fürs Ensemble sichtbar machen.',
    ],
  ),
  ChangelogEntry(
    version: '0.7.0',
    date: '11. Oktober 2026',
    items: [
      'Aufgeräumte Navigation: Abstimmungen findest du jetzt bei '
          '„Mitteilungen“, den Terminfinder und „Abwesenheit melden“ bei '
          '„Termine“.',
      'Auf „Heute“ beantwortest du offene Termine und Abstimmungen mit einem '
          'Tipp.',
      'Bevor etwas gelöscht wird oder ungespeicherte Änderungen verloren '
          'gehen, fragt die App nach. Vieles lässt sich mit „Rückgängig“ '
          'zurücknehmen.',
      'Für die Theaterleitung: Abstimmungen per Benachrichtigung ankündigen '
          'und Terminserien „ab diesem Termin“ ändern.',
    ],
  ),
  ChangelogEntry(
    version: '0.6.0',
    date: '10. Oktober 2026',
    items: [
      'Mitteilungen haben einen eigenen Reiter. Du kannst nach ungelesenen '
          'filtern und alles auf einmal als gelesen markieren.',
      'Im Terminfinder suchst du dir ein freies Zeitfenster aus – es steht '
          'danach direkt bei deinen Terminen.',
      '„Heute“ zeigt das Wichtigste zuerst; Erledigtes klappt sich '
          'zusammen.',
      'Eine Stunde vor Beginn kannst du nicht mehr absagen. Zusagen oder '
          '„Komme später“ geht weiterhin.',
      'Auf dem iPhone zeigt dir eine Anleitung, wie du die App auf den '
          'Home-Bildschirm legst.',
      'Für die Theaterleitung: wiederkehrende Termine, „Besetzung & Team“ '
          'für jedes Stück und eine Übersicht aller Rückmeldungen mit '
          '„Offene erinnern“.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.1',
    date: '6. Oktober 2026',
    items: [
      'Der Terminplan zeigt Rückmeldungen kompakter, und alle Filter bleiben '
          'auch auf kleinen Bildschirmen sichtbar.',
      'Anmeldung und Kalender kommen besser mit großer Schrift zurecht.',
      'Hast du deine E-Mail-Adresse bestätigt, geht es beim Zurückkehren in '
          'die App direkt weiter.',
      'Viele kleine Verbesserungen im Drehbuch, in den Galerien und im '
          'Profil.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.0',
    date: '5. Oktober 2026',
    items: [
      'Das aktuelle Stück steht ganz oben und ist hervorgehoben; ältere '
          'Drehbücher findest du im Archiv.',
      'Abstimmungen können anonym oder mit Namen sein und auf Wunsch zu '
          'einem festen Zeitpunkt enden.',
      'Bei der Registrierung gibst du deinen Namen an, damit die '
          'Theaterleitung dich schnell zuordnen kann.',
      'Im Browser lässt sich die App wie eine normale App installieren.',
    ],
  ),
  ChangelogEntry(
    version: '0.4.1',
    date: '14. September 2026',
    items: [
      'Benachrichtigungen zu Terminen zeigen Datum, Uhrzeit und Ort.',
      'Unter Android antwortest du direkt in der Benachrichtigung mit '
          '„Komme“ oder „Komme nicht“.',
      'Kleine Zähler zeigen dir offene Rückmeldungen und ungelesene '
          'Mitteilungen.',
    ],
  ),
  ChangelogEntry(
    version: '0.4.0',
    date: '13. September 2026',
    items: [
      'Jeder Termin hat eine eigene Seite mit allen Details.',
      'Neu: Abstimmungen im Ensemble.',
    ],
  ),
];
