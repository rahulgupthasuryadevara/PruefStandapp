import 'dart:math';

/// Identity of one test attempt.
/// Permanent storage and cloud synchronization will be added later.
class TestSession {
  final String? testNumber;
  final int? stationNumber;

  final String casingNumber;
  final DateTime createdAt;

  final String? controllerSerial;
  final DateTime? pairedAt;

  const TestSession._({
    required this.casingNumber,
    required this.createdAt,
    this.testNumber,
    this.stationNumber,
    this.controllerSerial,
    this.pairedAt,
  });

  factory TestSession.create(String casingNumber) {
    return TestSession._(
      casingNumber: casingNumber,
      createdAt: DateTime.now().toUtc(),
    );
  }

  String get displayNumber => testNumber ?? 'Wird angelegt …';

  TestSession withTestNumber(String number, int station) {
    if (testNumber != null &&
        (testNumber != number || stationNumber != station)) {
      throw StateError(
        'Die Prüfungsnummer darf nicht geändert werden.',
      );
    }

    return TestSession._(
      testNumber: number,
      stationNumber: station,
      casingNumber: casingNumber,
      createdAt: createdAt,
      controllerSerial: controllerSerial,
      pairedAt: pairedAt,
    );
  }

  TestSession pairWith(String serial) {
    if (testNumber == null) {
      throw StateError(
        'Prüfungsnummer wurde noch nicht angelegt.',
      );
    }

    if (controllerSerial != null && controllerSerial != serial) {
      throw StateError(
        'Andere Steuerung erkannt. '
            'Bitte eine neue Prüfung anlegen.',
      );
    }

    return TestSession._(
      testNumber: testNumber,
      stationNumber: stationNumber,
      casingNumber: casingNumber,
      createdAt: createdAt,
      controllerSerial: serial,
      pairedAt: pairedAt ?? DateTime.now().toUtc(),
    );
  }

  Map<String, Object?> toJson() {
    if (testNumber == null) {
      throw StateError('Prüfungsnummer fehlt.');
    }

    return {
      'test_id': testNumber,
      'station_number': stationNumber,
      'casing_number': casingNumber,
      'controller_serial': controllerSerial,
      'created_at': createdAt.toIso8601String(),
      'paired_at': pairedAt?.toIso8601String(),
      'status': 'in_progress',
    };
  }
}