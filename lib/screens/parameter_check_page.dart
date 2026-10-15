import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/test_session.dart';
import '../services/test_history.dart';
import 'test_history_page.dart';

class ParameterDefinition {
  final int register;
  final String label;
  final int defaultValue;

  const ParameterDefinition(
      this.register,
      this.label,
      this.defaultValue,
      );
}

class ParameterCheckPage extends StatefulWidget {
  final String casingNumber;
  final TestSession testSession;
  final TestHistory history;

  final Future<Map<int, int>> Function() readValues;

  final Future<void> Function(
      Map<int, int> approvedValues,
      ) runFunctionalTest;

  const ParameterCheckPage({
    super.key,
    required this.casingNumber,
    required this.testSession,
    required this.history,
    required this.readValues,
    required this.runFunctionalTest,
  });

  @override
  State<ParameterCheckPage> createState() =>
      _ParameterCheckPageState();
}

class _ParameterCheckPageState extends State<ParameterCheckPage> {
  static const orange = Color(0xFFF37216);
  static const storageKey = 'lmc_expected_parameters_v1';

  static const definitions = [
    ParameterDefinition(
      30001,
      'Übersetzungswert (Rohwert)',
      7420,
    ),
    ParameterDefinition(
      20000,
      'Verfahrweg (mm)',
      5000,
    ),
    ParameterDefinition(
      20010,
      'Beschleunigungszeit (Soll-Rohwert)',
      8000,
    ),
    ParameterDefinition(
      20012,
      'Verzögerungszeit (Soll-Rohwert)',
      700,
    ),
    ParameterDefinition(
      102,
      'Firmware (Rohwert)',
      50067,
    ),
  ];

  final _formKey = GlobalKey<FormState>();
  final _preferences = SharedPreferencesAsync();
  final _operatorController = TextEditingController();

  late final Map<int, TextEditingController> _controllers;

  Map<int, int> _savedTargets = {};
  Map<int, int>? _actual;
  Map<int, int>? _checkedTargets;

  bool _loaded = false;
  bool _busy = false;
  bool _editing = false;
  bool _hasSavedTargets = false;

  String _message = 'Sollwerte werden geladen …';
  DateTime? _checkedAt;

  @override
  void initState() {
    super.initState();

    _operatorController.text = widget.history.operatorName;

    _controllers = {
      for (final parameter in definitions)
        parameter.register: TextEditingController(
          text: parameter.defaultValue.toString(),
        ),
    };

    _loadTargets();
  }

  Map<int, int> _currentTargets() {
    return {
      for (final parameter in definitions)
        parameter.register: int.parse(
          _controllers[parameter.register]!.text.trim(),
        ),
    };
  }

  Future<void> _loadTargets() async {
    try {
      final saved = await _preferences.getString(storageKey);

      if (!mounted) return;

      if (saved != null) {
        final decoded = jsonDecode(saved);

        if (decoded is! Map<String, dynamic>) {
          throw const FormatException(
            'Ungültige Sollwertdatei.',
          );
        }

        for (final parameter in definitions) {
          final value = decoded[parameter.register.toString()];

          if (value is! int ||
              value < 0 ||
              value > 2147483647) {
            throw FormatException(
              'Ungültiger Sollwert für Register '
                  '${parameter.register}.',
            );
          }
        }

        for (final parameter in definitions) {
          _controllers[parameter.register]!.text =
              decoded[parameter.register.toString()].toString();
        }
      }

      setState(() {
        _loaded = true;
        _hasSavedTargets = saved != null;
        _savedTargets = _currentTargets();

        _message = saved == null
            ? 'Startwerte noch nicht freigegeben. '
            'Zum Prüfen und Speichern den Stift verwenden.'
            : 'Gespeicherte Sollwerte geladen.';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _loaded = false;
        _message =
        'Sollwerte konnten nicht geladen werden: $error';
      });
    }
  }

  void _clearComparison() {
    _actual = null;
    _checkedTargets = null;
    _checkedAt = null;
  }

  Future<void> _enableEditing() async {
    if (!_loaded || _busy || _editing) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Sollwerte bearbeiten?'),
          content: const SingleChildScrollView(
            child: Text(
              'Diese Sollwerte müssen durch eine fachgerechte '
                  'Prüfung freigegeben sein.\n\n'
                  'Änderungen beeinflussen die Bewertung der Antriebe. '
                  'Bitte sprechen Sie vor Änderungen mit der '
                  'zuständigen Entwicklung.\n\n'
                  'Möchten Sie die Bearbeitung freigeben?',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              child: const Text('Bearbeitung freigeben'),
            ),
          ],
        );
      },
    );

    if (!mounted || confirmed != true) return;

    setState(() {
      _editing = true;
      _clearComparison();

      _message =
      'Bearbeitung freigegeben. '
          'Nur freigegebene Sollwerte speichern.';
    });
  }

  void _cancelEditing() {
    if (_busy) return;

    FocusScope.of(context).unfocus();

    for (final entry in _savedTargets.entries) {
      _controllers[entry.key]!.text = entry.value.toString();
    }

    setState(() {
      _editing = false;
      _message =
      'Bearbeitung abgebrochen. Sollwerte unverändert.';
    });
  }

  Future<void> _saveTargets() async {
    if (_busy || !_loaded || !_editing) return;
    if (!_formKey.currentState!.validate()) return;

    final operatorName = _operatorController.text.trim();

    if (operatorName.isEmpty) {
      setState(() {
        _message =
        'Bitte zuerst Prüfername oder Personalnummer eingeben.';
      });
      return;
    }

    FocusScope.of(context).unfocus();

    final targets = _currentTargets();
    widget.history.operatorName = operatorName;

    setState(() => _busy = true);

    try {
      await widget.history.record(
        stage: 'Sollwerte',
        event: 'Speicherung angefordert',
        details: jsonEncode({
          for (final entry in targets.entries)
            entry.key.toString(): entry.value,
        }),
      );

      await _preferences.setString(
        storageKey,
        jsonEncode({
          for (final entry in targets.entries)
            entry.key.toString(): entry.value,
        }),
      );

      if (!mounted) return;

      setState(() {
        _savedTargets = Map<int, int>.from(targets);
        _hasSavedTargets = true;
        _editing = false;
        _clearComparison();
      });

      await widget.history.record(
        stage: 'Sollwerte',
        event: 'Sollwerte lokal gespeichert',
        result: 'OK',
      );

      if (!mounted) return;

      setState(() {
        _message =
        'Sollwerte gespeichert und gesperrt. '
            'Parameter erneut prüfen.';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _message =
        'Speicherung oder Protokollierung fehlgeschlagen: '
            '$error';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _checkParameters() async {
    if (_busy ||
        !_loaded ||
        _editing ||
        !_hasSavedTargets) {
      return;
    }

    final operatorName = _operatorController.text.trim();

    if (operatorName.isEmpty) {
      setState(() {
        _message =
        'Bitte Prüfername oder Personalnummer eingeben.';
      });
      return;
    }

    FocusScope.of(context).unfocus();

    final targets = <int, int>{
      ..._savedTargets,

      // Parameter check requires no controller error.
      12002: 0,
    };

    final history = widget.history;
    history.operatorName = operatorName;

    setState(() {
      _busy = true;
      _clearComparison();
      _message = 'Steuerungswerte werden gelesen …';
    });

    try {
      // Storage must work before testing continues.
      await history.record(
        stage: 'Parameterprüfung',
        event: 'Prüfung gestartet',
        result: 'IN_PROGRESS',
        details: 'Prüfer: $operatorName',
      );

      for (final entry in targets.entries) {
        await history.record(
          stage: 'Parameterprüfung',
          event: 'Verwendeter Sollwert',
          register: entry.key,
          expected: entry.value,
        );
      }

      final actual = await widget.readValues();

      if (!mounted) return;

      final requiredRegisters = [
        ...targets.keys,
        104,
        105,
        12010,
      ];

      final missing = requiredRegisters
          .where((register) => !actual.containsKey(register))
          .toList();

      if (missing.isNotEmpty) {
        throw StateError(
          'Antworten fehlen für Register: '
              '${missing.join(", ")}',
        );
      }

      final serial =
      (actual[105]! * 65536 + actual[104]!).toString();

      if (serial != widget.testSession.controllerSerial) {
        throw StateError(
          'Andere Steuerung erkannt. '
              'Keine gültige Parameterprüfung.',
        );
      }

      for (final entry in actual.entries) {
        final expected = targets[entry.key];

        await history.record(
          stage: 'Parameterprüfung',
          event: 'Register gelesen',
          register: entry.key,
          expected: expected,
          actual: entry.value,
          result: expected == null
              ? 'INFO'
              : expected == entry.value
              ? 'OK'
              : 'FAIL',
        );
      }

      final matches = targets.entries.every(
            (entry) => actual[entry.key] == entry.value,
      );

      await history.record(
        stage: 'Parameterprüfung',
        event: 'Parametervergleich abgeschlossen',
        result: matches
            ? 'PARAMETER_PASS'
            : 'PARAMETER_FAIL',
        details: matches
            ? 'Alle geforderten Parameter stimmen überein. '
            'Noch kein Gesamtergebnis der Endprüfung.'
            : 'Mindestens ein Parameter weicht ab.',
      );

      await history.ensureSaved();

      if (!mounted) return;

      setState(() {
        _actual = Map<int, int>.from(actual);
        _checkedTargets = Map<int, int>.from(targets);
        _checkedAt = DateTime.now();

        _message = matches
            ? 'Parameterprüfung bestanden. '
            'Weiter zur Funktionsprüfung möglich.'
            : 'Parameterprüfung nicht bestanden. '
            'Funktionsprüfung gesperrt.';
      });
    } catch (error) {
      var saveFailed = false;

      try {
        await history.record(
          stage: 'Parameterprüfung',
          event: 'Prüfung nicht erfolgreich abgeschlossen',
          result: 'ERROR',
          details: error.toString(),
        );
      } catch (_) {
        saveFailed = true;
      }

      if (!mounted) return;

      setState(() {
        _clearComparison();

        _message = saveFailed
            ? 'Speicherfehler. Keine gültige Freigabe. '
            'Bitte Speicherung erneut versuchen.'
            : 'Keine gültige Parameterprüfung: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _continueToFunctionalTest() async {
    final targets = _checkedTargets;

    if (_busy ||
        _editing ||
        _passed != true ||
        targets == null) {
      return;
    }

    final operatorName = _operatorController.text.trim();

    if (operatorName.isEmpty) {
      setState(() {
        _message = 'Bitte Prüfername eingeben.';
      });
      return;
    }

    FocusScope.of(context).unfocus();

    widget.history.operatorName = operatorName;

    String returnMessage =
        'Für eine weitere Prüfung die Parameter erneut lesen.';

    setState(() => _busy = true);

    try {
      await widget.history.record(
        stage: 'Übergang',
        event: 'Funktionsprüfung geöffnet',
        result: 'PARAMETER_GATE_PASSED',
      );

      await widget.runFunctionalTest(
        Map<int, int>.from(targets),
      );
    } catch (error) {
      returnMessage =
      'Funktionsprüfung nicht gestartet oder unterbrochen: '
          '$error';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _clearComparison();
          _message = returnMessage;
        });
      }
    }
  }

  bool? get _passed {
    final actual = _actual;
    final targets = _checkedTargets;

    if (actual == null || targets == null) return null;

    return targets.entries.every(
          (entry) => actual[entry.key] == entry.value,
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();

    String two(int value) {
      return value.toString().padLeft(2, '0');
    }

    return '${two(local.day)}.'
        '${two(local.month)}.'
        '${local.year} '
        '${two(local.hour)}:'
        '${two(local.minute)}:'
        '${two(local.second)}';
  }

  Future<void> _openHistory() async {
    if (_busy) return;

    setState(() => _busy = true);

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
        _message =
        'CSV konnte nicht gespeichert werden: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _parameterCard(ParameterDefinition parameter) {
    final actual = _actual?[parameter.register];
    final expected = _checkedTargets?[parameter.register];

    final checked = actual != null && expected != null;
    final matches = checked && actual == expected;

    final resultColor = matches ? Colors.green : Colors.red;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              parameter.label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text('Register ${parameter.register}'),
            const SizedBox(height: 12),
            if (_editing)
              TextFormField(
                controller: _controllers[parameter.register],
                enabled: _loaded && !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(
                  labelText: 'Sollwert',
                  border: OutlineInputBorder(),
                ),
                validator: (text) {
                  final value =
                  int.tryParse(text?.trim() ?? '');

                  if (value == null ||
                      value < 0 ||
                      value > 2147483647) {
                    return 'Ganze Zahl von 0 bis '
                        '2147483647 eingeben.';
                  }

                  return null;
                },
              )
            else
              Text(
                'Sollwert: '
                    '${_controllers[parameter.register]!.text}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Istwert: '
                        '${actual?.toString() ?? "Noch nicht geprüft"}',
                  ),
                ),
                if (checked) ...[
                  Icon(
                    matches
                        ? Icons.check_circle
                        : Icons.cancel,
                    color: resultColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    matches ? 'OK' : 'Abweichung',
                    style: TextStyle(
                      color: resultColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _operatorController.dispose();

    for (final controller in _controllers.values) {
      controller.dispose();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final passed = _passed;
    final errorCode = _actual?[12002];
    final station = widget.testSession.stationNumber;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Sollwerte / Istwerte'),
          actions: [
            IconButton(
              tooltip: 'Prüfhistorie',
              onPressed: _busy ? null : _openHistory,
              icon: const Icon(Icons.history),
            ),
            IconButton(
              tooltip: 'Sollwerte bearbeiten',
              onPressed: _loaded && !_busy && !_editing
                  ? _enableEditing
                  : null,
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment:
                    CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        'Prüfungsnummer: '
                            '${widget.testSession.displayNumber}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Gehäusenummer: ${widget.casingNumber}',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Steuerungsseriennummer: '
                            '${widget.testSession.controllerSerial ?? "—"}',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Prüfstation: '
                            '${station?.toString().padLeft(2, '0') ?? "—"}',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Prüfung angelegt: '
                            '${_formatDate(widget.testSession.createdAt)}',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _operatorController,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Prüfername / Personalnummer',
                  hintText: 'Zum Beispiel: Rahul / MA-123',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Sollwerte sind gesperrt. '
                    'Änderungen können über das Stiftsymbol '
                    'freigegeben werden. '
                    'Die Steuerung wird beim Speichern der '
                    'Sollwerte nicht verändert.',
              ),
              const SizedBox(height: 16),
              for (final parameter in definitions)
                _parameterCard(parameter),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment:
                    CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Fehlerstatus 12002: '
                            '${errorCode?.toString() ?? "—"} '
                            '(Sollwert: 0)',
                      ),
                      if (errorCode != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          errorCode == 0
                              ? 'OK'
                              : 'Fehler vorhanden',
                          style: TextStyle(
                            color: errorCode == 0
                                ? Colors.green
                                : Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        'Referenzstatus 12010: '
                            '${_actual?[12010]?.toString() ?? "—"}',
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Der Referenzstatus wird protokolliert. '
                            'Die Bewegungsbereitschaft wird vor '
                            'der Funktionsprüfung erneut geprüft. '
                            'Die abschließende Installationsvorbereitung '
                            'bleibt zurückgestellt.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_editing) ...[
                FilledButton.icon(
                  onPressed: _busy ? null : _saveTargets,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Sollwerte speichern'),
                ),
                TextButton(
                  onPressed: _busy ? null : _cancelEditing,
                  child: const Text('Abbrechen'),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton.icon(
                onPressed: _loaded &&
                    !_busy &&
                    !_editing &&
                    _hasSavedTargets
                    ? _checkParameters
                    : null,
                icon: const Icon(Icons.fact_check),
                label: Text(
                  _busy
                      ? 'Bitte warten …'
                      : 'Parameter prüfen',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: !_busy &&
                    !_editing &&
                    passed == true
                    ? _continueToFunctionalTest
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text(
                  'Weiter zur Funktionsprüfung',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _openHistory,
                icon: const Icon(Icons.history),
                label: const Text(
                  'Prüfhistorie / CSV exportieren',
                ),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: 16),
              Text(
                _message,
                style: TextStyle(
                  color: passed == null
                      ? orange
                      : passed
                      ? Colors.green
                      : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (_checkedAt != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Momentaufnahme: '
                      '${_formatDate(_checkedAt!)}',
                ),
              ],
              if (!_loaded && !_busy)
                TextButton(
                  onPressed: _loadTargets,
                  child: const Text(
                    'Sollwerte erneut laden',
                  ),
                ),
              const SizedBox(height: 16),
              const Text(
                'Diese Bewertung betrifft nur die '
                    'Parameterprüfung. Sie ist noch kein '
                    'Gesamtergebnis der Endprüfung.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}