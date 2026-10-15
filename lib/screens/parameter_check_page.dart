import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/test_session.dart';

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

  // BluetoothPage continues to own the Bluetooth connection.
  final Future<Map<int, int>> Function() readValues;

  const ParameterCheckPage({
    super.key,
    required this.casingNumber,
    required this.testSession,
    required this.readValues,
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
              'Ungültiger Sollwert für '
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

    FocusScope.of(context).unfocus();

    final targets = _currentTargets();

    setState(() => _busy = true);

    try {
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

        _message =
        'Sollwerte gespeichert und gesperrt. '
            'Parameter erneut prüfen.';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _message = 'Speichern fehlgeschlagen: $error';
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

    FocusScope.of(context).unfocus();

    final targets = <int, int>{
      ..._savedTargets,

      // A successful parameter check requires no current error.
      12002: 0,
    };

    setState(() {
      _busy = true;
      _clearComparison();
      _message = 'Steuerungswerte werden gelesen …';
    });

    try {
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

      final matches = targets.entries.every(
            (entry) => actual[entry.key] == entry.value,
      );

      setState(() {
        _actual = Map<int, int>.from(actual);
        _checkedTargets = Map<int, int>.from(targets);
        _checkedAt = DateTime.now();

        _message = matches
            ? 'Parameterprüfung bestanden.'
            : 'Parameterprüfung nicht bestanden: '
            'Abweichungen vorhanden.';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _clearComparison();
        _message = 'Keine gültige Parameterprüfung: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
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
    for (final controller in _controllers.values) {
      controller.dispose();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final passed = _passed;
    final errorCode = _actual?[12002];
    final stationNumber = widget.testSession.stationNumber;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Sollwerte / Istwerte'),
          actions: [
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
                            '${stationNumber?.toString().padLeft(2, '0') ?? "—"}',
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

              const SizedBox(height: 12),

              const Text(
                'Sollwerte werden nur in dieser App gespeichert. '
                    'Die Steuerung wird nicht verändert.',
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
                        'Referenzstatus wird angezeigt und '
                            'später im Funktionsablauf '
                            'separat bewertet.',
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