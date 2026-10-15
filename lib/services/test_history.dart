import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/test_session.dart';

class TestHistory {
  static const summaryFilename = 'Pruefungen.csv';
  static const _storeFilename = 'pruefungen_store_v1.json';

  static Future<void> _writeQueue = Future<void>.value();

  static const _parameterNames = <int, String>{
    30001: 'Uebersetzung',
    20000: 'Verfahrweg',
    20010: 'Beschleunigung',
    20012: 'Verzoegerung',
    102: 'Firmware',
    12002: 'Fehlerstatus',
  };

  TestSession _session;

  final File file;

  String operatorName = '';
  Object? lastSaveError;

  final Map<String, Object?> _summary;
  final List<Map<String, Object?>> _events = [];

  TestHistory._({
    required TestSession session,
    required this.file,
  })  : _session = session,
        _summary = _initialSummary(session);

  static Map<String, Object?> _initialSummary(
      TestSession session,
      ) {
    final values = <String, Object?>{
      'Pruefungsnummer': session.testNumber,
      'Pruefstation': session.stationNumber,
      'Gehaeusenummer': session.casingNumber,
      'Steuerungsseriennummer': session.controllerSerial,
      'Pruefer': '',
      'Angelegt_UTC': session.createdAt.toIso8601String(),
      'Abgeschlossen_UTC': '',
      'Aktualisiert_UTC': '',
    };

    for (final entry in _parameterNames.entries) {
      final prefix = '${entry.value}_${entry.key}';

      values['${prefix}_Soll'] = '';
      values['${prefix}_Ist'] = '';
      values['${prefix}_Ergebnis'] = 'NICHT_GEPRUEFT';
    }

    values['Parameter_Ergebnis'] = 'NICHT_GEPRUEFT';
    values['Referenzstatus_12010'] = '';

    for (final direction in ['UP', 'DOWN']) {
      values['${direction}_Durchgefuehrt'] = 'NEIN';
      values['${direction}_Start_mm'] = '';
      values['${direction}_Ende_mm'] = '';
      values['${direction}_Differenz_mm'] = '';
      values['${direction}_Sollzeit_ms'] = 5000;
      values['${direction}_Zeit_bis_Stillstandspruefung_ms'] = '';
      values['${direction}_Ergebnis'] = 'NICHT_GEPRUEFT';
    }

    values.addAll({
      'PWM_Anstieg_Soll_Ist': '',
      'PWM_Anstieg_Registerergebnis': 'NICHT_GEPRUEFT',
      'PWM_Absenkung_Soll_Ist': '',
      'PWM_Absenkung_Registerergebnis': 'NICHT_GEPRUEFT',
      'Licht_Anstieg_Visuell': 'NICHT_GEPRUEFT',
      'Licht_Absenkung_Visuell': 'NICHT_GEPRUEFT',
      'Licht_Aus_Visuell': 'NICHT_GEPRUEFT',
      'Beleuchtung_Ergebnis': 'NICHT_GEPRUEFT',
      'Stillstand_und_PWM_Aus': 'NICHT_GEPRUEFT',
      'Installation': 'NICHT_DURCHGEFUEHRT',
      'Pruefumfang':
      'Parameter, UP/DOWN und visuelle Beleuchtungspruefung',
      'Ergebnis_Pruefumfang': 'IN_BEARBEITUNG',
      'Installationsfreigabe': 'AUSSTEHEND',
      'Ablaufstatus': 'IN_PROGRESS',
      'Bemerkung': '',
    });

    return values;
  }

  static Future<Directory> historyDirectory() async {
    final documents = await getApplicationDocumentsDirectory();

    final directory = Directory(
      '${documents.path}/pruefberichte',
    );

    await directory.create(recursive: true);

    return directory;
  }

  static Future<T> _locked<T>(
      Future<T> Function() action,
      ) {
    final completer = Completer<T>();

    _writeQueue = _writeQueue.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });

    return completer.future;
  }

  static Future<TestHistory> create(
      TestSession session,
      ) async {
    final number = session.testNumber;

    if (number == null ||
        !RegExp(r'^PR-\d{2}-\d{2}-\d{6}$').hasMatch(number)) {
      throw StateError(
        'Eine gültige Prüfungsnummer ist erforderlich.',
      );
    }

    final directory = await historyDirectory();

    // All tests use this ONE CSV file.
    final summaryFile = File(
      '${directory.path}/$summaryFilename',
    );

    final history = TestHistory._(
      session: session,
      file: summaryFile,
    );

    history._events.add({
      'timestamp_utc': DateTime.now().toUtc().toIso8601String(),
      'stage': 'Sitzung',
      'event': 'Prüfung angelegt',
      'result': 'IN_PROGRESS',
    });

    await history._persist(requireNew: true);

    return history;
  }

  Future<void> setPairing(
      TestSession session,
      ) async {
    if (session.testNumber != _session.testNumber) {
      throw StateError(
        'Prüfungsnummer stimmt nicht überein.',
      );
    }

    final previousSerial = _session.controllerSerial;

    if (previousSerial != null &&
        previousSerial != session.controllerSerial) {
      throw StateError(
        'Die Steuerungszuordnung darf nicht '
            'überschrieben werden.',
      );
    }

    _session = session;

    await record(
      stage: 'Identifikation',
      event: 'Gehäuse und Steuerung zugeordnet',
      actual: session.controllerSerial,
      result: 'OK',
    );
  }

  Future<void> record({
    required String stage,
    required String event,
    Object? register,
    Object? expected,
    Object? actual,
    String unit = '',
    String result = '',
    String details = '',
  }) {
    // Raw Bluetooth traffic remains in Android Studio.
    // It does not fill the summary CSV with communication rows.
    if (stage == 'Bluetooth') {
      return Future<void>.value();
    }

    final timestamp = DateTime.now().toUtc().toIso8601String();

    _events.add({
      'timestamp_utc': timestamp,
      'stage': stage,
      'event': event,
      'register': register,
      'expected': expected,
      'actual': actual,
      'unit': unit,
      'result': result,
      'details': details,
    });

    _applyEvent(
      stage: stage,
      event: event,
      register: register,
      expected: expected,
      actual: actual,
      result: result,
      details: details,
      timestamp: timestamp,
    );

    _updateResults();

    return _persist();
  }

  void recordBackground({
    required String stage,
    required String event,
    String details = '',
  }) {
    if (stage == 'Bluetooth') return;

    record(
      stage: stage,
      event: event,
      details: details,
    ).catchError((Object error) {
      lastSaveError = error;
    });
  }

  void _resetFunctionalResults() {
    for (final direction in ['UP', 'DOWN']) {
      _summary['${direction}_Durchgefuehrt'] = 'NEIN';
      _summary['${direction}_Start_mm'] = '';
      _summary['${direction}_Ende_mm'] = '';
      _summary['${direction}_Differenz_mm'] = '';
      _summary['${direction}_Sollzeit_ms'] = 5000;
      _summary['${direction}_Zeit_bis_Stillstandspruefung_ms'] = '';
      _summary['${direction}_Ergebnis'] = 'NICHT_GEPRUEFT';
    }

    for (final prefix in ['PWM_Anstieg', 'PWM_Absenkung']) {
      _summary['${prefix}_Soll_Ist'] = '';
      _summary['${prefix}_Registerergebnis'] = 'NICHT_GEPRUEFT';
    }

    for (final key in [
      'Licht_Anstieg_Visuell',
      'Licht_Absenkung_Visuell',
      'Licht_Aus_Visuell',
      'Beleuchtung_Ergebnis',
      'Stillstand_und_PWM_Aus',
    ]) {
      _summary[key] = 'NICHT_GEPRUEFT';
    }

    _summary['Abgeschlossen_UTC'] = '';
    _summary['Ablaufstatus'] = 'IN_PROGRESS';
    _summary['Ergebnis_Pruefumfang'] = 'IN_BEARBEITUNG';
    _summary['Bemerkung'] = '';
  }

  void _applyEvent({
    required String stage,
    required String event,
    required Object? register,
    required Object? expected,
    required Object? actual,
    required String result,
    required String details,
    required String timestamp,
  }) {
    if (stage == 'Parameterprüfung' &&
        event == 'Prüfung gestartet') {
      _resetFunctionalResults();

      _summary['Parameter_Ergebnis'] = 'IN_BEARBEITUNG';

      for (final entry in _parameterNames.entries) {
        final prefix = '${entry.value}_${entry.key}';

        _summary['${prefix}_Ist'] = '';
        _summary['${prefix}_Ergebnis'] = 'NICHT_GEPRUEFT';
      }
    }

    final registerId = register is int
        ? register
        : int.tryParse(register?.toString() ?? '');

    if ((stage == 'Parameterprüfung' || stage == 'Vorprüfung') &&
        registerId != null) {
      if (expected != null) {
        final name =
            _parameterNames[registerId] ?? 'Parameter';

        final prefix = '${name}_$registerId';

        _summary['${prefix}_Soll'] = expected;

        if (actual != null) {
          _summary['${prefix}_Ist'] = actual;

          final matches =
              expected.toString() == actual.toString();

          _summary['${prefix}_Ergebnis'] =
          matches ? 'PASS' : 'FAIL';

          if (!matches) {
            _summary['Parameter_Ergebnis'] = 'FAIL';
          }
        }
      }

      if (registerId == 12010 && actual != null) {
        _summary['Referenzstatus_12010'] = actual;
      }
    }

    if (stage == 'Parameterprüfung' &&
        event == 'Parametervergleich abgeschlossen') {
      _summary['Parameter_Ergebnis'] =
      result == 'PARAMETER_PASS' ? 'PASS' : 'FAIL';

      if (result != 'PARAMETER_PASS') {
        _summary['Bemerkung'] = details;
      }
    }

    if (stage == 'Parameterprüfung' && result == 'ERROR') {
      _summary['Parameter_Ergebnis'] = 'FAIL';
      _summary['Bemerkung'] = details;
    }

    if (stage == 'Funktionsprüfung' &&
        event == 'Prüfung gestartet; Vorrichtung bestätigt') {
      _resetFunctionalResults();
      _summary['Ablaufstatus'] = 'FUNCTION_RUNNING';
    }

    if (stage == 'Betriebsart' &&
        registerId == 12010 &&
        actual != null) {
      _summary['Referenzstatus_12010'] = actual;
    }

    if (stage == 'Bewegung UP' || stage == 'Bewegung DOWN') {
      final direction = stage == 'Bewegung UP' ? 'UP' : 'DOWN';

      if (event == 'Start') {
        _summary['${direction}_Durchgefuehrt'] = 'GESTARTET';
        _summary['${direction}_Start_mm'] = actual;
        _summary['${direction}_Ergebnis'] = 'IN_BEARBEITUNG';
      }

      if (event == 'Messwert') {
        _summary['${direction}_Ende_mm'] = actual;

        if (details.contains('12503=1')) {
          _summary['${direction}_Durchgefuehrt'] = 'JA';
        }
      }

      if (event == 'Ergebnis') {
        _summary['${direction}_Start_mm'] =
            _detailValue(details, 'Start') ??
                _summary['${direction}_Start_mm'];

        _summary['${direction}_Ende_mm'] =
            _detailValue(details, 'Ende') ?? actual;

        _summary['${direction}_Differenz_mm'] =
            _detailValue(details, 'Differenz') ?? '';

        _summary['${direction}_Sollzeit_ms'] =
            _detailValue(details, 'Sollzeit') ?? 5000;

        _summary['${direction}_Zeit_bis_Stillstandspruefung_ms'] =
            _detailValue(
              details,
              'Zeit_bis_Stillstandsprüfung_ms',
            ) ??
                '';

        final movementDetected =
        _detailValue(details, 'Bewegung_erkannt');

        _summary['${direction}_Durchgefuehrt'] =
        movementDetected == 'true' || result == 'OK'
            ? 'JA'
            : 'NEIN';

        _summary['${direction}_Ergebnis'] =
        result == 'OK' ? 'PASS' : 'FAIL';
      }
    }

    if (stage == 'Beleuchtung') {
      if (event == 'Helligkeit niedrig → hoch') {
        _addPwmPoint(
          prefix: 'PWM_Anstieg',
          expected: expected,
          actual: actual,
          result: result,
        );
      }

      if (event == 'Helligkeit hoch → niedrig') {
        _addPwmPoint(
          prefix: 'PWM_Absenkung',
          expected: expected,
          actual: actual,
          result: result,
        );
      }

      if (event == 'Ist die Helligkeit sichtbar angestiegen?') {
        _summary['Licht_Anstieg_Visuell'] =
        result == 'VISUAL_OK' ? 'PASS' : 'FAIL';
      }

      if (event == 'Ist die Helligkeit sichtbar abgesunken?') {
        _summary['Licht_Absenkung_Visuell'] =
        result == 'VISUAL_OK' ? 'PASS' : 'FAIL';
      }

      if (event == 'Ist die Beleuchtung ausgeschaltet?') {
        _summary['Licht_Aus_Visuell'] =
        result == 'VISUAL_OK' ? 'PASS' : 'FAIL';
      }
    }

    if (stage == 'Funktionsprüfung' &&
        event == 'Abgeschlossen') {
      _summary['Ablaufstatus'] = result;
      _summary['Abgeschlossen_UTC'] = timestamp;
      _summary['Bemerkung'] = details;

      if (result == 'FAIL' || result == 'ABORTED') {
        for (final direction in ['UP', 'DOWN']) {
          if (_summary['${direction}_Ergebnis'] ==
              'IN_BEARBEITUNG') {
            _summary['${direction}_Ergebnis'] =
            result == 'ABORTED' ? 'ABGEBROCHEN' : 'FAIL';
          }
        }
      }
    }

    if (stage == 'Endzustand' &&
        event == 'Stillstand und PWM-Aus') {
      _summary['Stillstand_und_PWM_Aus'] =
      result == 'VERIFIED' ? 'PASS' : 'FAIL';
    }
  }

  void _addPwmPoint({
    required String prefix,
    required Object? expected,
    required Object? actual,
    required String result,
  }) {
    final key = '${prefix}_Soll_Ist';
    final previous = _summary[key]?.toString() ?? '';
    final point = '$expected/$actual';

    _summary[key] =
    previous.isEmpty ? point : '$previous | $point';

    final resultKey = '${prefix}_Registerergebnis';

    if (_summary[resultKey] == 'FAIL') return;

    _summary[resultKey] =
    result == 'REGISTER_OK' ? 'PASS' : 'FAIL';
  }

  static String? _detailValue(
      String details,
      String key,
      ) {
    final expression = RegExp(
      r'(?:^|;\s*)' + RegExp.escape(key) + r'=([^;]+)',
    );

    return expression.firstMatch(details)?.group(1)?.trim();
  }

  void _updateResults() {
    const lightingKeys = [
      'PWM_Anstieg_Registerergebnis',
      'PWM_Absenkung_Registerergebnis',
      'Licht_Anstieg_Visuell',
      'Licht_Absenkung_Visuell',
      'Licht_Aus_Visuell',
    ];

    if (lightingKeys.any(
          (key) => _summary[key] == 'FAIL',
    )) {
      _summary['Beleuchtung_Ergebnis'] = 'FAIL';
    } else if (lightingKeys.every(
          (key) => _summary[key] == 'PASS',
    )) {
      _summary['Beleuchtung_Ergebnis'] = 'PASS';
    } else if (lightingKeys.any(
          (key) => _summary[key] == 'PASS',
    )) {
      _summary['Beleuchtung_Ergebnis'] = 'UNVOLLSTAENDIG';
    } else {
      _summary['Beleuchtung_Ergebnis'] = 'NICHT_GEPRUEFT';
    }

    final status = _summary['Ablaufstatus'];

    if (status == 'ABORTED') {
      _summary['Ergebnis_Pruefumfang'] = 'ABGEBROCHEN';
      return;
    }

    if (status == 'FAIL' ||
        _summary['Parameter_Ergebnis'] == 'FAIL') {
      _summary['Ergebnis_Pruefumfang'] = 'FAIL';
      return;
    }

    if (status == 'FUNCTION_PASS_INSTALLATION_PENDING') {
      const requiredResults = [
        'Parameter_Ergebnis',
        'UP_Ergebnis',
        'DOWN_Ergebnis',
        'Beleuchtung_Ergebnis',
        'Stillstand_und_PWM_Aus',
      ];

      final allPassed = requiredResults.every(
            (key) => _summary[key] == 'PASS',
      );

      _summary['Ergebnis_Pruefumfang'] =
      allPassed ? 'PASS' : 'UNVOLLSTAENDIG';

      return;
    }

    _summary['Ergebnis_Pruefumfang'] = 'IN_BEARBEITUNG';
  }

  Future<void> ensureSaved() {
    return _persist();
  }

  Future<void> _persist({
    bool requireNew = false,
  }) async {
    _summary['Pruefungsnummer'] = _session.testNumber;
    _summary['Pruefstation'] = _session.stationNumber;
    _summary['Gehaeusenummer'] = _session.casingNumber;
    _summary['Steuerungsseriennummer'] =
        _session.controllerSerial;
    _summary['Pruefer'] = operatorName;
    _summary['Aktualisiert_UTC'] =
        DateTime.now().toUtc().toIso8601String();

    final snapshot = jsonEncode({
      'summary': _summary,
      'events': _events,
    });

    try {
      await _locked<void>(() async {
        final directory = await historyDirectory();

        final storeFile = File(
          '${directory.path}/$_storeFilename',
        );

        var records = <String, dynamic>{};

        if (await storeFile.exists()) {
          final decoded = jsonDecode(
            await storeFile.readAsString(encoding: utf8),
          );

          if (decoded is! Map<String, dynamic> ||
              decoded['records'] is! Map<String, dynamic>) {
            throw const FormatException(
              'Gespeicherte Prüfhistorie ist ungültig. '
                  'Vorhandene Daten werden nicht überschrieben.',
            );
          }

          records = Map<String, dynamic>.from(
            decoded['records'] as Map,
          );
        }

        final number = _session.testNumber!;

        if (requireNew && records.containsKey(number)) {
          throw StateError(
            'Prüfungsnummer $number existiert bereits.',
          );
        }

        records[number] = jsonDecode(snapshot);

        final summaries = <Map<String, dynamic>>[];

        for (final record in records.values) {
          if (record is! Map ||
              record['summary'] is! Map) {
            throw const FormatException(
              'Ein gespeicherter Prüfbericht ist ungültig.',
            );
          }

          summaries.add(
            Map<String, dynamic>.from(
              record['summary'] as Map,
            ),
          );
        }

        summaries.sort(
              (a, b) => a['Pruefungsnummer']
              .toString()
              .compareTo(b['Pruefungsnummer'].toString()),
        );

        final columns = <String>[
          ..._initialSummary(_session).keys,
        ];

        final extraColumns = <String>{};

        for (final summary in summaries) {
          extraColumns.addAll(
            summary.keys.where(
                  (key) => !columns.contains(key),
            ),
          );
        }

        columns.addAll(
          extraColumns.toList()..sort(),
        );

        final rows = <List<Object?>>[
          columns,
          for (final summary in summaries)
            [
              for (final column in columns)
                summary[column] ?? '',
            ],
        ];

        final csv = '\uFEFF'
            '${rows.map((row) => row.map(_csvCell).join(';')).join('\r\n')}'
            '\r\n';

        // Save the internal structured history first.
        final temporaryStore = File(
          '${storeFile.path}.tmp',
        );

        await temporaryStore.writeAsString(
          jsonEncode({
            'schema_version': 1,
            'records': records,
          }),
          encoding: utf8,
          flush: true,
        );

        await temporaryStore.rename(storeFile.path);

        // Update the ONE combined CSV file.
        final temporaryCsv = File('${file.path}.tmp');

        await temporaryCsv.writeAsString(
          csv,
          encoding: utf8,
          flush: true,
        );

        await temporaryCsv.rename(file.path);
      });

      lastSaveError = null;
    } catch (error) {
      lastSaveError = error;
      rethrow;
    }
  }

  static String _csvCell(Object? value) {
    var text = value?.toString() ?? '';

    if (value is String &&
        RegExp(r'^[\s]*[=+\-@]').hasMatch(text)) {
      text = "'$text";
    }

    return '"${text.replaceAll('"', '""')}"';
  }
}