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

  String _progress = 'Vorrichtung prüfen und Start bestätigen.';
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
      approvedValues: Map<int, int>.from(widget.approvedValues),
      onProgress: (message) {
        if (mounted) {
          setState(() => _progress = message);
        }
      },
      askVisual: _askVisual,
    );
  }

  Future<bool> _askVisual(String question) {
    final completer = Completer<bool>();
    _visualAnswer = completer;

    if (!mounted) {
      completer.complete(false);
      return completer.future;
    }

    setState(() => _question = question);

    return completer.future;
  }

  void _answerVisual(bool accepted) {
    final answer = _visualAnswer;

    if (answer == null || answer.isCompleted) return;

    setState(() {
      _question = null;
      _visualAnswer = null;
    });

    answer.complete(accepted);
  }

  void _abort() {
    _runner.abort();

    final answer = _visualAnswer;

    if (answer != null && !answer.isCompleted) {
      answer.complete(false);
    }

    if (mounted) {
      setState(() {
        _question = null;
        _visualAnswer = null;
        _progress = 'Abbruch angefordert. Ausgänge werden gestoppt …';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_running && state != AppLifecycleState.resumed) {
      _abort();
    }
  }

  Future<void> _start() async {
    if (_running || _started || !_fixtureReady) return;

    if (widget.history.operatorName.trim().isEmpty) {
      setState(() {
        _progress = 'Prüfername fehlt. Zur Parameterseite zurückgehen.';
      });
      return;
    }

    setState(() {
      _running = true;
      _started = true;
      _result = null;
      _saved = false;
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
        _progress = 'Prüfung konnte nicht abgeschlossen werden: $error';
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

  Future<void> _retrySave() async {
    try {
      await widget.history.ensureSaved();

      if (!mounted) return;

      setState(() {
        _saved = true;
        _progress = 'CSV erfolgreich gespeichert.';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _saved = false;
        _progress = 'Speichern weiterhin fehlgeschlagen: $error';
      });
    }
  }

  Future<void> _openHistory() async {
    try {
      await widget.history.ensureSaved();

      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const TestHistoryPage(),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _progress = 'CSV-Speicherung fehlgeschlagen: $error';
      });
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

  @override
  Widget build(BuildContext context) {
    final result = _result;

    final functionPassed =
        result?.status == 'FUNCTION_PASS_INSTALLATION_PENDING';

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
                      widget.session.displayNumber,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('Gehäuse: ${widget.session.casingNumber}'),
                    Text(
                      'Steuerung: ${widget.session.controllerSerial}',
                    ),
                    Text('Prüfer: ${widget.history.operatorName}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Ablauf: UP 5 s → Stopp → DOWN 5 s → Stopp → '
                  'Licht niedrig/hoch → visuelle Bestätigung → '
                  'Licht hoch/niedrig → visuelle Bestätigung → Licht aus.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Die abschließende Installationsvorbereitung '
                  'wird in dieser Version nicht durchgeführt.',
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _fixtureReady,
              onChanged: _started
                  ? null
                  : (value) {
                setState(() => _fixtureReady = value ?? false);
              },
              title: const Text('Vorrichtung bereit'),
              subtitle: const Text(
                'Antrieb sicher befestigt, Bewegungsbereich frei '
                    'und ausreichend Verfahrweg in beiden Richtungen.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: !_started && _fixtureReady
                  ? _start
                  : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Funktionsprüfung starten'),
            ),
            if (_running) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                onPressed: _abort,
                icon: const Icon(Icons.stop),
                label: const Text('STOPP / ABBRECHEN'),
              ),
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 16),
            Text(
              _progress,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (_question != null) ...[
              const SizedBox(height: 20),
              Card(
                color: Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _question!,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => _answerVisual(true),
                        child: const Text('JA – akzeptiert'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: () => _answerVisual(false),
                        child: const Text('NEIN – nicht akzeptiert'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (result != null) ...[
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        !_saved
                            ? 'SPEICHERFEHLER – KEINE FREIGABE'
                            : functionPassed
                            ? 'FUNKTIONSPRÜFUNG BESTANDEN'
                            : result.status == 'ABORTED'
                            ? 'ABGEBROCHEN'
                            : 'FAIL',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: functionPassed && _saved
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(result.message),
                      const SizedBox(height: 12),
                      Text(
                        result.outputsVerifiedStopped
                            ? 'Stillstand und PWM-Aus bestätigt.'
                            : 'Endzustand NICHT bestätigt. '
                            'Antrieb vor Ort prüfen.',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _saved
                            ? 'CSV lokal gespeichert.'
                            : 'CSV-Speicherung nicht bestätigt.',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Installationsvorbereitung ausstehend. '
                            'Keine vollständige Installationsfreigabe.',
                      ),
                    ],
                  ),
                ),
              ),
              if (!_saved)
                OutlinedButton.icon(
                  onPressed: _retrySave,
                  icon: const Icon(Icons.save),
                  label: const Text('CSV erneut speichern'),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _openHistory,
                icon: const Icon(Icons.history),
                label: const Text('Prüfhistorie / CSV exportieren'),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _saved && result.outputsVerifiedStopped
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