const eventTypes = <String, String>{
  'rehearsal': 'Probe',
  'readthrough': 'Leseprobe',
  'technical': 'Technikprobe',
  'costume': 'Kostümprobe',
  'dress': 'Generalprobe',
  'performance': 'Aufführung',
  'meeting': 'Besprechung',
  'workshop': 'Workshop',
  'setup': 'Aufbau',
  'teardown': 'Abbau',
  'social': 'Feier / Ausflug',
  'other': 'Sonstiges',
};
String eventTypeLabel(String kind) => eventTypes[kind] ?? 'Sonstiges';
