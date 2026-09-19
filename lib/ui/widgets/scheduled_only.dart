/// Phase 9 marker: the Regione Piemonte feed is a timetable and nothing else.
/// Approximate or absent data is always marked, never silently guessed.
library;

import 'package:flutter/material.dart';

class ScheduledOnlyNote extends StatelessWidget {
  const ScheduledOnlyNote({
    super.key,
    this.text = 'Solo orario · nessun dato in tempo reale',
  });

  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(color: color))),
        ],
      ),
    );
  }
}
