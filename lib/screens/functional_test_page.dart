import 'dart:async';

import 'package:flutter/material.dart';

import '../models/test_session.dart';
import '../services/functional_test_runner.dart';
import '../services/test_history.dart';
import 'test_history_page.dart';

class FunctionalTestPage extends StatefulWidget {
  final TestSession session;
  final TestHistory history;
  final Map<int, int> approvedValues;
  final FunctionalTestIo io;

  const FunctionalTestPage({
    super.key,
    required this.session,
    required this.history,
    required this.approvedValues,
    required this.io,
  });

  @override
  State<FunctionalTestPage> createState() =>
      _FunctionalTestPageState();
}

class _FunctionalTestPageState extends State<FunctionalTestPage>
    with WidgetsBindingObserver {
  late final FunctionalTestRunner _runner;

  bool _fixtureReady = false;
  bool _running = false;
  bool _started = false;
  bool _saved = false;

  String _progress = 'Bereit zur Funktionsprüfung.';
  String? _question;

  Completer<bool>? _visualAnswer;
  FunctionalTestResult? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _runner = FunctionalTestRunner(
      io: widget.io,
      history: widget.history,
      session: widget.session,
      approvedValues: widget.approvedValues,
      onProgress: (message) {
        if (!mounted) return;

        setState(() {
          _progress = message;
        });
      },
      askVisual: _askVisual,
    );
  }

  Future<bool> _askVisual(String question) {
    if (!mounted || !_running) {
      return Future<bool>.value(false);
    }

    final answer = Completer<bool>();

    setState(() {
      _question = question;
      _visualAnswer = answer;
    });

    return answer.future;
  }

  void _answer(bool accepted) {
    final answer = _visualAnswer;

    if (answer == null || answer.isCompleted) return;

    answer.complete(accepted);

    setState(() {
      _question = null;
      _visualAnswer = null;
    });
  }

  void _abort() {
    _runner.abort();

    final answer = _visualAnswer;

    if (answer != null && !answer.isCompleted) {
      answer.complete(false);
    }

    setState(() {
      _question = null;
      _visualAnswer = null;
      _progress = 'Abbruch angefordert. Ausgänge werden gestoppt …';
    });
  }

  Future<void> _start() async {
    if (_running || _started || !_fixtureReady) return;

    if (widget.history.operatorName.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Bitte auf der Parameterseite den Prüfer eintragen.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _running = true;
      _started = true;
      _saved = false;
      _result = null;
    });

    try {
      final result = await _runner.run();

      if (!mounted) return;

      setState(() {
        _result = result;
        _saved = result.csvSaved;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _result = FunctionalTestResult(
          status: 'FAIL',
          message: error.toString(),
          outputsVerifiedStopped: false,
          csvSaved: false,
        );
      });
    } finally {
      final answer = _visualAnswer;

      if (answer != null && !answer.isCompleted) {
        answer.complete(false);
      }

      if (mounted) {
        setState(() {
          _running = false;
          _question = null;
          _visualAnswer = null;
        });
      }
    }
  }

  Future<void> _saveAgain() async {
    try {
      await widget.history.ensureSaved();

      if (!mounted) return;

      setState(() {
        _saved = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('CSV erfolgreich gespeichert.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Speichern fehlgeschlagen: $error'),
        ),
      );
    }
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const TestHistoryPage(),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_running && state != AppLifecycleState.resumed) {
      _abort();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    if (_running) {
      _runner.abort();
    }

    final answer = _visualAnswer;

    if (answer != null && !answer.isCompleted) {
      answer.complete(false);
    }

    super.dispose();
  }

  Widget _resultCard(FunctionalTestResult result) {
    final passed =
        result.status == 'FUNCTION_PASS_INSTALLATION_PENDING';

    final color = passed ? Colors.green : Colors.red;

    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              passed
                  ? 'FUNKTIONSPRÜFUNG: PASS'
                  : result.status == 'ABORTED'
                  ? 'ABGEBROCHEN'
                  : 'FAIL',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 12),
            Text(result.message),
            const SizedBox(height: 16),
            Text(
              result.outputsVerifiedStopped
                  ? 'Stillstand und PWM-Aus bestätigt.'
                  : 'Stillstand/PWM-Aus nicht sicher bestätigt. '
                  'Antrieb an der Vorrichtung prüfen.',
            ),
            const SizedBox(height: 8),
            Text(
              _saved
                  ? 'Prüfergebnisse in Pruefungen.csv gespeichert.'
                  : 'CSV noch nicht erfolgreich gespeichert.',
            ),
            if (passed) ...[
              const SizedBox(height: 12),
              const Text(
                'Keine automatische Referenzfahrt durchgeführt. '
                    'Der Positionsreset wurde gesendet. '
                    'Eine vollständige Installationsfreigabe wird '
                    'ohne Verifikation dieses Resets nicht erteilt.',
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;

    return PopScope(
      canPop: !_running,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Funktionsprüfung'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.session.testNumber ?? '',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Gehäuse: ${widget.session.casingNumber}',
                    ),
                    Text(
                      'Steuerung: '
                          '${widget.session.controllerSerial ?? '—'}',
                    ),
                    Text(
                      'Prüfer: ${widget.history.operatorName}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Prüfablauf',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '1. Parameter und Identität erneut prüfen.\n'
                  '2. Aktiven Referenzmodus verlassen.\n'
                  '3. UP 5 Sekunden, stoppen und Richtungspause.\n'
                  '4. DOWN 5 Sekunden und stoppen.\n'
                  '5. Licht niedrig → hoch: visuell bestätigen.\n'
                  '6. Licht hoch → niedrig: visuell bestätigen.\n'
                  '7. Licht aus: visuell bestätigen.\n'
                  '8. Ausgänge abschalten und Stillstand prüfen.\n'
                  '9. Nur bei PASS: Position für die spätere '
                  'Kundeninstallation löschen.\n'
                  '10. Ergebnisse in einer CSV-Datei speichern.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Es wird keine automatische Fahrt zum '
                  'mechanischen Endanschlag gestartet.',
            ),
            const SizedBox(height: 20),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Vorrichtung bereit'),
              subtitle: const Text(
                'Antrieb sicher befestigt. Bewegungsbereich frei. '
                    'Ausreichend Verfahrweg für beide Richtungen. '
                    'Unabhängige Abschaltmöglichkeit verfügbar.',
              ),
              value: _fixtureReady,
              onChanged: _started
                  ? null
                  : (value) {
                setState(() {
                  _fixtureReady = value ?? false;
                });
              },
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed:
              _fixtureReady && !_running && !_started
                  ? _start
                  : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Funktionsprüfung starten'),
            ),
            if (_running) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                ),
                onPressed: _abort,
                icon: const Icon(Icons.stop),
                label: const Text('Prüfung abbrechen / stoppen'),
              ),
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 20),
            Text(
              _progress,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
            if (_question != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment:
                    CrossAxisAlignment.stretch,
                    children: [
                      const Icon(
                        Icons.visibility,
                        size: 36,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _question!,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => _answer(true),
                        child: const Text(
                          'Ja — visuell bestätigt',
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: () => _answer(false),
                        child: const Text(
                          'Nein — nicht bestanden',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (result != null) ...[
              const SizedBox(height: 20),
              _resultCard(result),
              if (!_saved) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _saveAgain,
                  icon: const Icon(Icons.save),
                  label: const Text(
                    'CSV-Speicherung erneut versuchen',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _openHistory,
                icon: const Icon(Icons.download),
                label: const Text(
                  'Prüfhistorie / CSV exportieren',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed:
                _saved && result.outputsVerifiedStopped
                    ? () {
                  Navigator.of(context).popUntil(
                        (route) => route.isFirst,
                  );
                }
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('Nächster Antrieb'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}