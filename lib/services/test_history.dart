import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/test_session.dart';

class TestHistory {
  TestSession _session;

  final File file;

  String operatorName = '';
  Object? lastSaveError;

  final List<List<Object?>> _events = [];

  Future<void> _writes = Future<void>.value();

  TestHistory._({
    required TestSession session,
    required this.file,
  }) : _session = session;

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
      throw StateError(
        'Eine gültige Prüfungsnummer ist erforderlich.',
      );
    }

    final directory = await historyDirectory();

    final file = File('${directory.path}/$number.csv');

    if (await file.exists()) {
      throw StateError(
        'Prüfungsnummer existiert bereits. '
            'Der vorhandene Bericht wird nicht überschrieben.',
      );
    }

    final history = TestHistory._(
      session: session,
      file: file,
    );

    await history.record(
      stage: 'Sitzung',
      event: 'Prüfung angelegt',
      result: 'IN_PROGRESS',
    );

    await history.record(
      stage: 'Prüfumfang',
      event: 'Bewegungsprüfung vorgesehen',
      result: 'PENDING',
      details: 'UP 5 s und DOWN 5 s mit Positionsprüfung.',
    );

    await history.record(
      stage: 'Prüfumfang',
      event: 'Visuelle Beleuchtungsprüfung vorgesehen',
      result: 'PENDING',
      details: 'PWM niedrig/hoch und hoch/niedrig '
          'mit Bestätigung durch Prüfer.',
    );

    await history.record(
      stage: 'Prüfumfang',
      event: 'Abschließende Installationsvorbereitung',
      result: 'NOT_PERFORMED',
      details: 'Für diese Entwicklungsstufe zurückgestellt.',
    );

    return history;
  }

  Future<void> setPairing(TestSession session) async {
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
    _events.add([
      _events.length + 1,
      DateTime.now().toUtc().toIso8601String(),
      stage,
      event,
      register,
      expected,
      actual,
      unit,
      result,
      details,
    ]);

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

  Future<void> ensureSaved() {
    final contents = _buildCsv();

    final operation = _writes.then((_) async {
      final temporary = File('${file.path}.tmp');

      try {
        await temporary.writeAsString(
          contents,
          encoding: utf8,
          flush: true,
        );

        await temporary.rename(file.path);

        lastSaveError = null;
      } catch (error) {
        lastSaveError = error;
        rethrow;
      }
    });

    _writes = operation.then<void>(
          (_) {},
      onError: (Object error, StackTrace stackTrace) {
        lastSaveError = error;
      },
    );

    return operation;
  }

  String _buildCsv() {
    final rows = <List<Object?>>[
      [
        'Pruefungsnummer',
        'Pruefstation',
        'Gehaeusenummer',
        'Steuerungsseriennummer',
        'Pruefer',
        'Pruefung_angelegt_UTC',
        'Ereignisnummer',
        'Zeitstempel_UTC',
        'Pruefschritt',
        'Ereignis',
        'Register',
        'Sollwert',
        'Istwert',
        'Einheit',
        'Ergebnis',
        'Details',
      ],
      for (final event in _events)
        [
          _session.testNumber,
          _session.stationNumber,
          _session.casingNumber,
          _session.controllerSerial,
          operatorName,
          _session.createdAt.toIso8601String(),
          ...event,
        ],
    ];

    return '\uFEFF'
        '${rows.map((row) => row.map(_csvCell).join(';')).join('\r\n')}'
        '\r\n';
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