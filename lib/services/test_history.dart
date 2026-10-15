import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/test_session.dart';

class TestHistory {
  static const summaryFilename = 'Pruefungen.csv';
  static const _storeFilename = 'pruefungen_store_v1.json';

  static Future<void> _queue = Future<void>.value();

  TestSession _session;
  final File file;

  String operatorName = '';
  Object? lastSaveError;

  final List<Map<String, Object?>> _events = [];
  final Map<String, Object?> _summary = {};

  TestHistory._({
    required TestSession session,
    required this.file,
  }) : _session = session {
    _summary.addAll({
      'Pruefungsnummer': session.testNumber,
      'Pruefstation': session.stationNumber,
      'Gehaeusenummer': session.casingNumber,
      'Steuerungsseriennummer': session.controllerSerial,
      'Pruefer': '',
      'Pruefung_angelegt_UTC':
      session.createdAt.toUtc().toIso8601String(),
      'Pruefung_beendet_UTC': '',
      'Parameter_Ergebnis': 'NICHT_GEPRUEFT',
      'Referenzstatus_vor_Pruefung': '',
      'Normalbetrieb_Ergebnis': 'NICHT_GEPRUEFT',
      'Referenz_Test_Schwelle_Soll': '',
      'Referenz_Test_Schwelle_Ist': '',
      'Referenz_Test_Schwelle_Ergebnis': 'NICHT_GEPRUEFT',
      'Referenzfahrt_Ergebnis': 'NICHT_GEPRUEFT',
      'Referenz_Position_mm': '',
      'Referenzfahrt_Details': '',
      'Referenz_Ende_Schwelle_Soll': '',
      'Referenz_Ende_Schwelle_Ist': '',
      'Referenz_Ende_Schwelle_Ergebnis': 'NICHT_GEPRUEFT',
      'UP_Gestartet': 'NEIN',
      'UP_Start_mm': '',
      'UP_Ende_mm': '',
      'UP_Differenz_mm': '',
      'UP_Sollzeit_ms': 5000,
      'UP_Bewegung_erkannt': '',
      'UP_Ergebnis': 'NICHT_GEPRUEFT',
      'DOWN_Gestartet': 'NEIN',
      'DOWN_Start_mm': '',
      'DOWN_Ende_mm': '',
      'DOWN_Differenz_mm': '',
      'DOWN_Sollzeit_ms': 5000,
      'DOWN_Bewegung_erkannt': '',
      'DOWN_Ergebnis': 'NICHT_GEPRUEFT',
      'Licht_niedrig_hoch_Register': 'NICHT_GEPRUEFT',
      'Licht_niedrig_hoch_Soll_Ist_Folge': '',
      'Licht_hoch_niedrig_Register': 'NICHT_GEPRUEFT',
      'Licht_hoch_niedrig_Soll_Ist_Folge': '',
      'Licht_heller_visuell': 'NICHT_GEPRUEFT',
      'Licht_dunkler_visuell': 'NICHT_GEPRUEFT',
      'Licht_aus_visuell': 'NICHT_GEPRUEFT',
      'Stillstand_PWM_Aus': 'NICHT_GEPRUEFT',
      'Konfiguration_Speicherbefehl': 'NICHT_GESENDET',
      'Konfiguration_Speicherhinweis': '',
      'Positionsreset_4009': 'NICHT_GESENDET',
      'Installation_Wirkung_verifiziert': 'NEIN',
      'Installationsfreigabe': 'AUSSTEHEND',
      'Funktionspruefung_Ergebnis': 'IN_BEARBEITUNG',
      'Ablaufstatus': 'IN_PROGRESS',
      'Bemerkung': '',
    });

    for (final register in [
      30001,
      20000,
      20010,
      20012,
      102,
      12002,
    ]) {
      _summary['R${register}_Soll'] = '';
      _summary['R${register}_Ist'] = '';
      _summary['R${register}_Ergebnis'] = 'NICHT_GEPRUEFT';
    }
  }

  static Future<Directory> historyDirectory() async {
    final documents = await getApplicationDocumentsDirectory();

    final directory = Directory(
      '${documents.path}/pruefberichte',
    );

    await directory.create(recursive: true);
    return directory;
  }

  static Future<TestHistory> create(TestSession session) async {
    final number = session.testNumber;

    if (number == null ||
        !RegExp(r'^PR-\d{2}-\d{2}-\d{6}$').hasMatch(number)) {
      throw StateError('Ungültige Prüfungsnummer.');
    }

    final directory = await historyDirectory();

    final history = TestHistory._(
      session: session,
      file: File('${directory.path}/$summaryFilename'),
    );

    history._events.add({
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'stage': 'Sitzung',
      'event': 'Prüfung angelegt',
      'result': 'IN_PROGRESS',
    });

    await history._persist(requireNew: true);
    return history;
  }

  Future<void> setPairing(TestSession session) async {
    if (session.testNumber != _session.testNumber ||
        session.casingNumber != _session.casingNumber) {
      throw StateError('Prüfungszuordnung stimmt nicht überein.');
    }

    if (_session.controllerSerial != null &&
        _session.controllerSerial != session.controllerSerial) {
      throw StateError(
        'Steuerungszuordnung darf nicht überschrieben werden.',
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
    if (stage == 'Bluetooth') {
      return Future<void>.value();
    }

    final entry = <String, Object?>{
      'number': _events.length + 1,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'stage': stage,
      'event': event,
      'register': register,
      'expected': expected,
      'actual': actual,
      'unit': unit,
      'result': result,
      'details': details,
    };

    _events.add(entry);
    _apply(entry);

    return ensureSaved();
  }

  void recordBackground({
    required String stage,
    required String event,
    String details = '',
  }) {
    record(
      stage: stage,
      event: event,
      details: details,
    ).catchError((Object error) {
      lastSaveError = error;
    });
  }

  void _apply(Map<String, Object?> entry) {
    final stage = entry['stage']?.toString() ?? '';
    final event = entry['event']?.toString() ?? '';
    final result = entry['result']?.toString() ?? '';
    final details = entry['details']?.toString() ?? '';

    final register = int.tryParse(
      entry['register']?.toString() ?? '',
    );

    final expected = entry['expected'];
    final actual = entry['actual'];

    if ((stage == 'Parameter' || stage == 'Vorprüfung') &&
        register != null) {
      if (expected != null) {
        _summary['R${register}_Soll'] = expected;
      }

      if (actual != null) {
        _summary['R${register}_Ist'] = actual;
      }

      if (expected != null && actual != null) {
        _summary['R${register}_Ergebnis'] =
        expected.toString() == actual.toString()
            ? 'PASS'
            : 'FAIL';
      }
    }

    if (stage == 'Parameter') {
      if (result == 'PARAMETER_PASS') {
        _summary['Parameter_Ergebnis'] = 'PASS';
      } else if (result == 'PARAMETER_FAIL' ||
          result == 'ERROR' ||
          result == 'FAIL') {
        _summary['Parameter_Ergebnis'] = 'FAIL';
      }
    }

    if (stage == 'Referenz') {
      if (event == 'Referenzstatus vor Prüfung') {
        _summary['Referenzstatus_vor_Pruefung'] = actual;
      }

      if (event == 'Normalbetrieb bestätigt') {
        _summary['Normalbetrieb_Ergebnis'] = result;
      }

      if (event == 'Referenz-Stromschwelle eingestellt') {
        _summary['Referenz_Test_Schwelle_Soll'] = expected;
        _summary['Referenz_Test_Schwelle_Ist'] = actual;
        _summary['Referenz_Test_Schwelle_Ergebnis'] = result;
      }

      if (event == 'Referenzfahrt angefordert') {
        _summary['Referenzfahrt_Ergebnis'] = 'ANGEFORDERT';
      }

      if (event == 'Referenz gefunden') {
        _summary['Referenzfahrt_Ergebnis'] = 'PASS';
        _summary['Referenz_Position_mm'] = actual;
        _summary['Referenzfahrt_Details'] = details;
      }

      if (event == 'Referenzfahrt fehlgeschlagen') {
        _summary['Referenzfahrt_Ergebnis'] = result;
        _summary['Referenzfahrt_Details'] = details;
      }

      if (event == 'Referenz-Stromschwelle wiederhergestellt') {
        _summary['Referenz_Ende_Schwelle_Soll'] = expected;
        _summary['Referenz_Ende_Schwelle_Ist'] = actual;
        _summary['Referenz_Ende_Schwelle_Ergebnis'] = result;
      }
    }

    if (stage == 'Bewegung UP' ||
        stage == 'Bewegung DOWN') {
      final prefix = stage == 'Bewegung UP' ? 'UP' : 'DOWN';

      if (event == 'Start') {
        _summary['${prefix}_Gestartet'] = 'JA';
        _summary['${prefix}_Start_mm'] = actual;
        _summary['${prefix}_Sollzeit_ms'] = 5000;
        _summary['${prefix}_Ergebnis'] = 'IN_BEARBEITUNG';
      }

      if (event == 'Ergebnis') {
        _summary['${prefix}_Ergebnis'] =
        result == 'OK' ? 'PASS' : 'FAIL';

        _summary['${prefix}_Ende_mm'] = actual;
        _summary['${prefix}_Details'] = details;

        final mappings = {
          'Start': '${prefix}_Start_mm',
          'Ende': '${prefix}_Ende_mm',
          'Differenz': '${prefix}_Differenz_mm',
          'Bewegung_erkannt': '${prefix}_Bewegung_erkannt',
          'Zeit_bis_Stillstandsprüfung_ms':
          '${prefix}_Zeit_bis_Stillstandspruefung_ms',
        };

        for (final mapping in mappings.entries) {
          final match = RegExp(
            '(?:^|;\\s*)${RegExp.escape(mapping.key)}=([^;]*)',
          ).firstMatch(details);

          if (match != null) {
            _summary[mapping.value] = match.group(1)?.trim();
          }
        }
      }
    }

    if (stage == 'Beleuchtung') {
      if (event == 'PWM niedrig nach hoch' ||
          event == 'PWM hoch nach niedrig') {
        final key = event == 'PWM niedrig nach hoch'
            ? 'Licht_niedrig_hoch'
            : 'Licht_hoch_niedrig';

        final previous =
            _summary['${key}_Soll_Ist_Folge']?.toString() ?? '';

        final pair = '$expected/$actual';

        _summary['${key}_Soll_Ist_Folge'] =
        previous.isEmpty ? pair : '$previous | $pair';

        if (result == 'FAIL') {
          _summary['${key}_Register'] = 'FAIL';
        } else if (_summary['${key}_Register'] != 'FAIL') {
          _summary['${key}_Register'] = 'IN_BEARBEITUNG';
        }
      }

      if (event == 'PWM niedrig nach hoch abgeschlossen' &&
          _summary['Licht_niedrig_hoch_Register'] != 'FAIL') {
        _summary['Licht_niedrig_hoch_Register'] = 'PASS';
      }

      if (event == 'PWM hoch nach niedrig abgeschlossen' &&
          _summary['Licht_hoch_niedrig_Register'] != 'FAIL') {
        _summary['Licht_hoch_niedrig_Register'] = 'PASS';
      }

      final visualColumns = {
        'Helligkeit angestiegen': 'Licht_heller_visuell',
        'Helligkeit abgesunken': 'Licht_dunkler_visuell',
        'Beleuchtung ausgeschaltet': 'Licht_aus_visuell',
      };

      final column = visualColumns[event];

      if (column != null) {
        _summary[column] =
        result == 'VISUAL_OK' ? 'PASS' : 'FAIL';
      }
    }

    if (stage == 'Endzustand' &&
        event == 'Stillstand und PWM-Aus') {
      _summary['Stillstand_PWM_Aus'] =
      result == 'VERIFIED' ? 'PASS' : 'FAIL';
    }

    if (stage == 'Installation') {
      if (event == 'Konfiguration speichern angefordert') {
        _summary['Konfiguration_Speicherbefehl'] = result;
        _summary['Konfiguration_Speicherhinweis'] = details;
      }

      if (event == 'Positionsreset angefordert') {
        _summary['Positionsreset_4009'] = 'ANGEFORDERT';
      }

      if (event == 'Positionsreset gesendet') {
        _summary['Positionsreset_4009'] = 'BEFEHL_GESENDET';
      }

      if (event == 'Zustand nach Positionsreset') {
        _summary['Zustand_nach_Positionsreset'] = actual;
        _summary['Ausgaenge_nach_Positionsreset'] = result;
      }
    }

    if (stage == 'Funktionsprüfung' &&
        event == 'Abgeschlossen') {
      _summary['Ablaufstatus'] = result;
      _summary['Bemerkung'] = details;
      _summary['Pruefung_beendet_UTC'] = entry['timestamp'];

      if (result == 'FUNCTION_PASS_INSTALLATION_PENDING') {
        _summary['Funktionspruefung_Ergebnis'] = 'PASS';
      } else if (result == 'ABORTED') {
        _summary['Funktionspruefung_Ergebnis'] = 'ABGEBROCHEN';
      } else {
        _summary['Funktionspruefung_Ergebnis'] = 'FAIL';
      }

      for (final column in [
        'UP_Ergebnis',
        'DOWN_Ergebnis',
        'Licht_niedrig_hoch_Register',
        'Licht_hoch_niedrig_Register',
      ]) {
        if (_summary[column] == 'IN_BEARBEITUNG') {
          _summary[column] =
          result == 'ABORTED' ? 'ABGEBROCHEN' : 'FAIL';
        }
      }

      if (_summary['Referenzfahrt_Ergebnis'] == 'ANGEFORDERT') {
        _summary['Referenzfahrt_Ergebnis'] =
        result == 'ABORTED' ? 'ABGEBROCHEN' : 'FAIL';
      }
    }
  }

  Future<void> ensureSaved() {
    return _persist();
  }

  Future<void> _persist({bool requireNew = false}) {
    _summary.addAll({
      'Pruefungsnummer': _session.testNumber,
      'Pruefstation': _session.stationNumber,
      'Gehaeusenummer': _session.casingNumber,
      'Steuerungsseriennummer': _session.controllerSerial,
      'Pruefer': operatorName.trim(),
    });

    final snapshot = jsonEncode({
      'summary': _summary,
      'events': _events,
    });

    final operation = _queue.then<void>((_) async {
      try {
        final directory = await historyDirectory();

        final storeFile = File(
          '${directory.path}/$_storeFilename',
        );

        final records = <String, dynamic>{};

        if (await storeFile.exists()) {
          final decoded = jsonDecode(
            await storeFile.readAsString(),
          );

          if (decoded is! Map<String, dynamic>) {
            throw const FormatException(
              'Ungültiger interner Prüfspeicher.',
            );
          }

          final storedRecords = decoded['records'] ?? decoded;

          if (storedRecords is! Map<String, dynamic>) {
            throw const FormatException(
              'Ungültige Prüfdatensätze.',
            );
          }

          records.addAll(storedRecords);
        }

        final number = _session.testNumber!;

        if (requireNew && records.containsKey(number)) {
          throw StateError(
            'Prüfungsnummer $number existiert bereits.',
          );
        }

        records[number] = jsonDecode(snapshot);

        final identifiers = records.keys.toList()..sort();
        final summaries = <Map<String, dynamic>>[];

        for (final identifier in identifiers) {
          final record = records[identifier];

          if (record is! Map ||
              record['summary'] is! Map) {
            throw FormatException(
              'Ungültiger Datensatz: $identifier',
            );
          }

          final row = Map<String, dynamic>.from(
            record['summary'] as Map,
          );

          row['Ereignisse_JSON'] = jsonEncode(
            record['events'] ?? [],
          );

          summaries.add(row);
        }

        final columns = <String>[];
        final knownColumns = <String>{};

        for (final column in _summary.keys) {
          if (knownColumns.add(column)) {
            columns.add(column);
          }
        }

        for (final row in summaries) {
          for (final column in row.keys) {
            if (knownColumns.add(column)) {
              columns.add(column);
            }
          }
        }

        final rows = <List<Object?>>[
          columns,
          for (final row in summaries)
            [for (final column in columns) row[column]],
        ];

        final csv = '\uFEFF'
            '${rows.map(
              (row) => row.map(_csvCell).join(';'),
        ).join('\r\n')}'
            '\r\n';

        final storeTemporary = File('${storeFile.path}.tmp');

        await storeTemporary.writeAsString(
          jsonEncode(records),
          encoding: utf8,
          flush: true,
        );

        await storeTemporary.rename(storeFile.path);

        final csvTemporary = File('${file.path}.tmp');

        await csvTemporary.writeAsString(
          csv,
          encoding: utf8,
          flush: true,
        );

        await csvTemporary.rename(file.path);

        lastSaveError = null;
      } catch (error) {
        lastSaveError = error;
        rethrow;
      }
    });

    _queue = operation.then<void>(
          (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );

    return operation;
  }

  static String _csvCell(Object? value) {
    var text = value?.toString() ?? '';

    if (value is String &&
        RegExp(r'^\s*[=+\-@]').hasMatch(text)) {
      text = "'$text";
    }

    return '"${text.replaceAll('"', '""')}"';
  }
}