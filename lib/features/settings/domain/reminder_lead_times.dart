/// Offered personal reminder lead times in minutes.
const reminderLeadTimes = [15, 30, 45, 60, 180, 360, 720, 2880, 4320, 10080];

String reminderLeadTimeLabel(int? minutes) => switch (minutes) {
  null => 'Aus',
  10080 => '1 Woche vorher',
  1440 => '1 Tag vorher',
  >= 1440 when minutes % 1440 == 0 => '${minutes ~/ 1440} Tage vorher',
  60 => '1 Stunde vorher',
  >= 60 when minutes % 60 == 0 => '${minutes ~/ 60} Stunden vorher',
  _ => '$minutes Minuten vorher',
};
