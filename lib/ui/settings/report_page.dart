/// "Segnala un problema": the last live trip's log, to copy or to post as a
/// GitHub issue. The issue gets the log without positions; the full log
/// (with positions, rounded to ~11 m) is only copied when the rider asks.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/app/app_update.dart' show installedVersion, openUrl;
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/location/trip_log.dart';
import 'package:piedemove/ui/theme/tokens.dart';

const _issues = 'https://github.com/LucaCraft89/piedemove/issues/new';

/// Characters of log tail in the issue link (a long URL is refused).
const _issueLogChars = 5000;

Future<void> openReport(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const ReportPage()));

/// The issue link: version, a place to describe the problem, and the end
/// of the log without positions.
Uri reportIssueUri(String? version, String log) {
  var tail = withoutPositions(log);
  if (tail.length > _issueLogChars) {
    tail = '…\n${tail.substring(tail.length - _issueLogChars)}';
  }
  final body = StringBuffer()
    ..writeln('**Versione:** ${version ?? 'sconosciuta'}')
    ..writeln()
    ..writeln('**Cosa è successo** (partenza, arrivo, linea, ora):')
    ..writeln()
    ..writeln()
    ..writeln('**Cosa mi aspettavo:**')
    ..writeln()
    ..writeln()
    ..writeln('<details><summary>Log dell\'ultimo viaggio (senza posizioni)</summary>')
    ..writeln()
    ..writeln('```')
    ..writeln(tail.isEmpty ? '(nessun viaggio registrato)' : tail)
    ..writeln('```')
    ..writeln('</details>');
  return Uri.parse(_issues).replace(queryParameters: {
    'title': 'Problema: ',
    'body': body.toString(),
  });
}

class ReportPage extends ConsumerStatefulWidget {
  const ReportPage({super.key});

  @override
  ConsumerState<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends ConsumerState<ReportPage> {
  String? _version;
  String? _log;

  @override
  void initState() {
    super.initState();
    installedVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
    // The running trip if there is one, else the last one saved.
    final live = ref.read(liveTripProvider) != null;
    if (live) {
      _log = ref.read(tripLogProvider).dump();
    } else {
      TripLog.loadLast().then((l) {
        if (mounted) setState(() => _log = l ?? '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final log = _log;
    return Scaffold(
      appBar: AppBar(title: const Text('Segnala un problema')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Gap.screen),
          children: [
            Text(
              'Apri una segnalazione su GitHub con la versione e il registro '
              'dell\'ultimo viaggio live (senza posizioni): descrivi cosa è '
              'successo, meglio con uno screenshot. Nulla viene inviato da '
              'solo: la pagina si apre nel browser e decidi tu.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.element),
            FilledButton.icon(
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('Apri segnalazione su GitHub'),
              onPressed: log == null
                  ? null
                  : () => openUrl(reportIssueUri(_version, log).toString()),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copia il registro completo'),
              onPressed: log == null || log.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: log));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Registro copiato (contiene le '
                              'posizioni del viaggio)')));
                    },
            ),
            const SizedBox(height: Gap.screen),
            Text('Registro dell\'ultimo viaggio',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            if (log == null)
              const LinearProgressIndicator()
            else if (log.isEmpty)
              const Text('Nessun viaggio live registrato.')
            else
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  log,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
