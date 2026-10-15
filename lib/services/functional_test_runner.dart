import 'dart:async';

import '../models/test_session.dart';
import 'test_history.dart';

class FunctionalTestIo {
  final Future<int> Function(int register) read;

  final Future<void> Function(
      String command,
      bool Function() allowed,
      ) write;

  final bool Function() isConnected;

  const FunctionalTestIo({
    required this.read,
    required this.write,
    required this.isConnected,
  });
}

class FunctionalTestResult {
  final String status;
  final String message;
  final bool outputsVerifiedStopped;
  final bool csvSaved;

  const FunctionalTestResult({
    required this.status,
    required this.message,
    required this.outputsVerifiedStopped,
    required this.csvSaved,
  });
}

class FunctionalTestRunner {
  final FunctionalTestIo io;
  final TestHistory history;
  final TestSession session;
  final Map<int, int> approvedValues;
  final void Function(String message) onProgress;
  final Future<bool> Function(String question) askVisual;

  static const movementDuration = Duration(seconds: 5);
  static const referenceTimeout = Duration(minutes: 3);

  // Raw register values. Confirm scaling for your firmware.
  static const testReferenceThreshold = 200;
  static const finalReferenceThreshold = 7000;

  static const lowPwm = 75;
  static const highPwm = 750;

  bool _abortRequested = false;
  bool _running = false;

  FunctionalTestRunner({
    required this.io,
    required this.history,
    required this.session,
    required this.approvedValues,
    required this.onProgress,
    required this.askVisual,
  });

  void abort() {
    _abortRequested = true;

    unawaited(
      io.write('#CMD idle 0\n', () => true).catchError(
            (Object error) {},
      ),
    );
  }

  void _check() {
    if (_abortRequested) {
      throw StateError('Prüfung durch Bediener abgebrochen.');
    }

    if (!io.isConnected()) {
      throw StateError('Bluetooth-Verbindung unterbrochen.');
    }
  }

  Future<int> _read(int register) async {
    _check();
    final value = await io.read(register);
    _check();
    return value;
  }

  Future<void> _write(String command) async {
    _check();

    await io.write(
      command,
          () => !_abortRequested && io.isConnected(),
    );

    _check();
  }

  Future<void> _record({
    required String stage,
    required String event,
    Object? register,
    Object? expected,
    Object? actual,
    String unit = '',
    String result = '',
    String details = '',
  }) {
    return history.record(
      stage: stage,
      event: event,
      register: register,
      expected: expected,
      actual: actual,
      unit: unit,
      result: result,
      details: details,
    );
  }

  Future<void> _pause(Duration duration) async {
    final clock = Stopwatch()..start();

    while (clock.elapsed < duration) {
      _check();

      await Future<void>.delayed(
        const Duration(milliseconds: 100),
      );
    }
  }

  Future<void> _verifyParameters() async {
    onProgress('Steuerungsnummer und Sollwerte prüfen …');

    final low = await _read(104);
    final high = await _read(105);
    final serial = (high * 65536 + low).toString();

    if (serial != session.controllerSerial) {
      throw StateError(
        'Steuerungsseriennummer stimmt nicht überein. '
            'Zugeordnet=${session.controllerSerial}; '
            'gelesen=$serial.',
      );
    }

    await _record(
      stage: 'Vorprüfung',
      event: 'Steuerungsseriennummer bestätigt',
      expected: session.controllerSerial,
      actual: serial,
      result: 'OK',
    );

    for (final entry in approvedValues.entries) {
      final actual = await _read(entry.key);
      final passed = actual == entry.value;

      await _record(
        stage: 'Vorprüfung',
        event: 'Sollwert erneut geprüft',
        register: entry.key,
        expected: entry.value,
        actual: actual,
        result: passed ? 'OK' : 'FAIL',
      );

      if (!passed) {
        throw StateError(
          'Register ${entry.key}: '
              'Soll=${entry.value}; Ist=$actual.',
        );
      }
    }

    final error = await _read(12002);

    await _record(
      stage: 'Vorprüfung',
      event: 'Fehlerstatus geprüft',
      register: 12002,
      expected: 0,
      actual: error,
      result: error == 0 ? 'OK' : 'FAIL',
    );

    if (error != 0) {
      throw StateError('Fehlerstatus=$error.');
    }
  }

  Future<void> _stopMotor() async {
    Object? firstError;

    for (final command in [
      '#CMD idle 0\n',
      '#R3502=0\n',
      '#R4002=0\n',
    ]) {
      try {
        await io.write(command, () => true);
      } catch (error) {
        firstError ??= error;
      }
    }

    if (firstError != null) {
      throw StateError(
        'Motor-Stopp nicht vollständig übertragen: $firstError',
      );
    }
  }

  Future<void> _waitUntilStopped() async {
    final clock = Stopwatch()..start();

    while (clock.elapsed < const Duration(seconds: 8)) {
      final moving = await io.read(12503);

      if (moving == 0) return;

      await Future<void>.delayed(
        const Duration(milliseconds: 150),
      );
    }

    throw TimeoutException(
      'Stillstand nicht bestätigt: Register 12503 ist nicht 0.',
    );
  }

  Future<void> _prepareNormalMode() async {
    onProgress('Referenzstatus und Betriebszustand lesen …');

    final reference = await _read(12010);
    final mode = await _read(12000);
    final state = await _read(12001);
    final moving = await _read(12503);

    await _record(
      stage: 'Referenz',
      event: 'Referenzstatus vor Prüfung',
      register: 12010,
      actual: reference,
      result: 'INFO',
      details:
      'Modus=$mode; Zustand=$state; Bewegung=$moving',
    );

    onProgress('Referenzmodus verlassen …');

    // Exit sequence from the supplied original app.
    const commands = [
      '#CMD idle 0\n',
      '#R3502=0\n',
      '#R4002=0\n',
      '#R4000=6\n',
      '#R4000=0\n',
      '#R4000=0\n',
      '#R4000=6\n',
      '#R4000=6\n',
      '#CMD idle 0\n',
    ];

    for (final command in commands) {
      await _write(command);
      await _pause(const Duration(milliseconds: 250));
    }

    await _pause(const Duration(milliseconds: 500));

    final clock = Stopwatch()..start();
    var lastReadings = '';

    while (clock.elapsed < const Duration(seconds: 12)) {
      final currentMode = await _read(12000);
      final currentState = await _read(12001);
      final currentMoving = await _read(12503);
      final currentReference = await _read(12010);
      final error = await _read(12002);

      lastReadings =
      '12000=$currentMode; '
          '12001=$currentState; '
          '12503=$currentMoving; '
          '12010=$currentReference; '
          '12002=$error';

      onProgress('Normalbetrieb prüfen: $lastReadings');

      if (error != 0) {
        throw StateError(
          'Fehler nach Referenzmodus-Ausgang: $lastReadings',
        );
      }

      if (currentMode == 6 &&
          currentState == 0 &&
          currentMoving == 0) {
        await _record(
          stage: 'Referenz',
          event: 'Normalbetrieb bestätigt',
          expected: '12000=6; 12001=0; 12503=0; 12002=0',
          actual: lastReadings,
          result: 'PASS',
        );

        return;
      }

      await _pause(const Duration(milliseconds: 250));
    }

    throw StateError(
      'Normalbetrieb nicht bestätigt. $lastReadings',
    );
  }

  Future<void> _setReferenceThreshold(int value) async {
    onProgress('Referenz-Stromschwelle auf $value einstellen …');

    await _write('#R29000=$value\n');
    await _pause(const Duration(milliseconds: 250));

    final actual = await _read(29000);

    await _record(
      stage: 'Referenz',
      event: 'Referenz-Stromschwelle eingestellt',
      register: 29000,
      expected: value,
      actual: actual,
      unit: 'Registerwert',
      result: actual == value ? 'PASS' : 'FAIL',
    );

    if (actual != value) {
      throw StateError(
        'Referenz-Stromschwelle nicht übernommen: '
            'Soll=$value; Ist=$actual.',
      );
    }
  }

  Future<void> _performInitialReferenceRun() async {
    var passed = false;
    String failureDetails = '';

    try {
      await _record(
        stage: 'Referenz',
        event: 'Referenzfahrt angefordert',
        register: 4004,
        expected: 0,
        result: 'REQUESTED',
        details:
        'Temporäre Stromschwelle=$testReferenceThreshold.',
      );

      onProgress('Referenzfahrt starten …');

      await _write('#R4004=0\n');

      final clock = Stopwatch()..start();
      var activeSeen = false;
      int? lastState;

      while (clock.elapsed < referenceTimeout) {
        final state = await _read(12010);
        final error = await _read(12002);

        if (state != lastState) {
          await _record(
            stage: 'Referenz',
            event: 'Referenzstatus geändert',
            register: 12010,
            actual: state,
            result: 'INFO',
          );

          lastState = state;
        }

        onProgress(
          'Referenzfahrt: Status=$state; '
              'Fehler=$error; ${clock.elapsed.inSeconds} s',
        );

        if (error != 0) {
          throw StateError(
            'Referenzfahrt: Fehlerstatus=$error.',
          );
        }

        if (state == 1) {
          activeSeen = true;
        }

        if (activeSeen && state == 2) {
          final position = await _read(11503);

          await _record(
            stage: 'Referenz',
            event: 'Referenz gefunden',
            register: 11503,
            actual: position,
            unit: 'mm',
            result: 'PASS',
            details:
            'Status 1 und anschließend 2 beobachtet; '
                'Dauer_ms=${clock.elapsedMilliseconds}.',
          );

          passed = true;
          return;
        }

        await _pause(const Duration(milliseconds: 200));
      }

      throw TimeoutException(
        'Referenzfahrt nach 3 Minuten nicht bestätigt. '
            'Letzter Status=$lastState; '
            'Aktiver Status beobachtet=$activeSeen.',
      );
    } catch (error) {
      failureDetails = error.toString();
      rethrow;
    } finally {
      if (!passed) {
        // Stop first. Persistence errors must not prevent stopping.
        try {
          await _stopMotor();
        } catch (_) {}

        try {
          await _record(
            stage: 'Referenz',
            event: 'Referenzfahrt fehlgeschlagen',
            result: _abortRequested ? 'ABORTED' : 'FAIL',
            details: failureDetails,
          );
        } catch (_) {}
      }
    }
  }

  Future<void> _restoreReferenceThreshold() async {
    // Restoration must remain possible after an operator abort.
    if (!io.isConnected()) {
      throw StateError(
        'Keine Verbindung zur Wiederherstellung der Stromschwelle.',
      );
    }

    onProgress('Referenz-Stromschwelle auf 7000 zurücksetzen …');

    await io.write(
      '#R29000=$finalReferenceThreshold\n',
          () => io.isConnected(),
    );

    await Future<void>.delayed(
      const Duration(milliseconds: 250),
    );

    final actual = await io.read(29000);

    await _record(
      stage: 'Referenz',
      event: 'Referenz-Stromschwelle wiederhergestellt',
      register: 29000,
      expected: finalReferenceThreshold,
      actual: actual,
      unit: 'Registerwert',
      result: actual == finalReferenceThreshold ? 'PASS' : 'FAIL',
    );

    if (actual != finalReferenceThreshold) {
      throw StateError(
        'Wiederherstellung fehlgeschlagen: '
            'Soll=$finalReferenceThreshold; Ist=$actual.',
      );
    }
  }

  Future<void> _move({required bool up}) async {
    _check();

    final direction = up ? 'UP' : 'DOWN';
    final command = up ? '#CMD up 0\n' : '#CMD down 0\n';

    final start = await _read(11503);
    final lower = await _read(20024);
    final upper = await _read(20025);

    if (lower >= upper ||
        start < lower ||
        start > upper ||
        (up && start >= upper) ||
        (!up && start <= lower)) {
      throw StateError(
        '$direction: Startposition oder Verfahrgrenzen ungültig. '
            'Position=$start; Untergrenze=$lower; Obergrenze=$upper.',
      );
    }

    await _record(
      stage: 'Bewegung $direction',
      event: 'Start',
      register: 11503,
      actual: start,
      unit: 'mm',
      result: 'STARTED',
      details: 'Sollzeit=5000 ms.',
    );

    onProgress('$direction: Bewegung für 5 Sekunden …');

    var active = true;
    var movementDetected = false;
    var previousPosition = start;
    Object? movementError;

    final samples = <Map<String, int>>[];
    final clock = Stopwatch()..start();
    final deadline = Completer<void>();

    final observedDeadline = deadline.future.then<void>(
          (_) {},
      onError: (Object error, StackTrace stackTrace) {
        movementError ??= error;
      },
    );

    final timer = Timer(movementDuration, () {
      active = false;

      unawaited(
        _stopMotor().then<void>(
              (_) {
            if (!deadline.isCompleted) deadline.complete();
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!deadline.isCompleted) {
              deadline.completeError(error, stackTrace);
            }
          },
        ),
      );
    });

    Future<void> repeatMovement() async {
      while (active && clock.elapsed < movementDuration) {
        _check();

        await io.write(
          command,
              () =>
          active &&
              !_abortRequested &&
              io.isConnected() &&
              clock.elapsed < movementDuration,
        );

        await Future<void>.delayed(
          const Duration(milliseconds: 800),
        );
      }
    }

    Future<void> monitorMovement() async {
      while (active) {
        final position = await _read(11503);
        if (!active) return;

        final moving = await _read(12503);
        if (!active) return;

        final error = await _read(12002);
        if (!active) return;

        samples.add({
          'elapsed': clock.elapsedMilliseconds,
          'position': position,
          'moving': moving,
          'error': error,
        });

        if (moving == 1) movementDetected = true;

        if (error != 0) {
          throw StateError('$direction: Fehlerstatus=$error.');
        }

        if (position < lower || position > upper) {
          throw StateError(
            '$direction: Position außerhalb der Grenzen.',
          );
        }

        if ((up && position < previousPosition - 1) ||
            (!up && position > previousPosition + 1)) {
          throw StateError(
            '$direction: Falsche Bewegungsrichtung.',
          );
        }

        if ((up && position >= upper) ||
            (!up && position <= lower)) {
          throw StateError(
            '$direction: Verfahrgrenze vorzeitig erreicht.',
          );
        }

        previousPosition = position;

        await _pause(const Duration(milliseconds: 100));
      }
    }

    final repeat = repeatMovement();
    final monitor = monitorMovement();

    try {
      await Future.wait<void>(
        [repeat, monitor],
        eagerError: true,
      );

      await observedDeadline;

      if (movementError != null) {
        throw StateError(movementError.toString());
      }

      _check();
    } catch (error) {
      movementError ??= error;
    } finally {
      active = false;
      timer.cancel();

      try {
        await _stopMotor();
      } catch (error) {
        movementError ??= error;
      }

      await Future.wait<void>([
        repeat.catchError((Object error) {}),
        monitor.catchError((Object error) {}),
      ]);

      if (!deadline.isCompleted) deadline.complete();
      await observedDeadline;
    }

    await _waitUntilStopped();

    final end = await io.read(11503);
    final finalError = await io.read(12002);
    final difference = end - start;

    final passed =
        movementError == null &&
            !_abortRequested &&
            movementDetected &&
            finalError == 0 &&
            (up ? difference > 0 : difference < 0);

    for (final sample in samples) {
      await _record(
        stage: 'Bewegung $direction',
        event: 'Messwert',
        register: 11503,
        actual: sample['position'],
        unit: 'mm',
        result: 'INFO',
        details:
        'Zeit_ms=${sample['elapsed']}; '
            'Bewegung=${sample['moving']}; '
            'Fehler=${sample['error']}',
      );
    }

    await _record(
      stage: 'Bewegung $direction',
      event: 'Ergebnis',
      register: 11503,
      expected: up ? 'Position steigt' : 'Position sinkt',
      actual: end,
      unit: 'mm',
      result: passed ? 'OK' : 'FAIL',
      details:
      'Start=$start; Ende=$end; Differenz=$difference; '
          'Sollzeit=5000 ms; '
          'Zeit_bis_Stillstandsprüfung_ms=${clock.elapsedMilliseconds}; '
          'Bewegung_erkannt=$movementDetected; Fehler=$finalError'
          '${movementError == null ? '' : '; Ursache=$movementError'}',
    );

    _check();

    if (!passed) {
      throw StateError(
        '$direction-Prüfung fehlgeschlagen. '
            '${movementError ?? 'Bewegung nicht bestätigt.'}',
      );
    }
  }

  Future<void> _ramp({
    required int from,
    required int to,
    required String event,
  }) async {
    for (var step = 0; step <= 10; step++) {
      final target = (from + (to - from) * step / 10).round();

      await _write('#R31087=$target\n');

      final actual = await _read(31087);
      final error = await _read(12002);
      final passed = actual == target && error == 0;

      await _record(
        stage: 'Beleuchtung',
        event: event,
        register: 31087,
        expected: target,
        actual: actual,
        result: passed ? 'REGISTER_OK' : 'FAIL',
        details: 'Fehlerstatus=$error',
      );

      if (!passed) {
        throw StateError(
          'PWM-Prüfung: Soll=$target; Ist=$actual; Fehler=$error.',
        );
      }

      await _pause(const Duration(milliseconds: 500));
    }

    await _record(
      stage: 'Beleuchtung',
      event: '$event abgeschlossen',
      result: 'PASS',
    );
  }

  Future<void> _visual({
    required String event,
    required String question,
  }) async {
    _check();
    onProgress(question);

    var completed = false;
    var accepted = false;
    Object? answerError;

    final answer = Future<bool>.sync(
          () => askVisual(question),
    ).then<void>(
          (value) {
        accepted = value;
        completed = true;
      },
      onError: (Object error, StackTrace stackTrace) {
        answerError = error;
        completed = true;
      },
    );

    final clock = Stopwatch()..start();

    while (!completed) {
      _check();

      if (clock.elapsed > const Duration(minutes: 2)) {
        throw TimeoutException(
          'Keine visuelle Bestätigung innerhalb von 2 Minuten.',
        );
      }

      final error = await _read(12002);

      if (error != 0) {
        throw StateError('Fehler während Sichtprüfung: $error.');
      }

      await _pause(const Duration(milliseconds: 500));
    }

    await answer;
    _check();

    await _record(
      stage: 'Beleuchtung',
      event: event,
      expected: 'JA',
      actual: accepted ? 'JA' : 'NEIN',
      result:
      accepted && answerError == null ? 'VISUAL_OK' : 'FAIL',
      details: answerError?.toString() ?? '',
    );

    if (!accepted || answerError != null) {
      throw StateError('Sichtprüfung nicht bestanden: $event.');
    }
  }

  Future<void> _lighting() async {
    onProgress('Beleuchtung: niedrig → hoch …');

    await _write('#R31087=$lowPwm\n');
    await _write('#R2702=1\n');

    await _ramp(
      from: lowPwm,
      to: highPwm,
      event: 'PWM niedrig nach hoch',
    );

    await _visual(
      event: 'Helligkeit angestiegen',
      question: 'Ist die Helligkeit sichtbar angestiegen?',
    );

    onProgress('Beleuchtung: hoch → niedrig …');

    await _ramp(
      from: highPwm,
      to: lowPwm,
      event: 'PWM hoch nach niedrig',
    );

    await _visual(
      event: 'Helligkeit abgesunken',
      question: 'Ist die Helligkeit sichtbar abgesunken?',
    );

    await _write('#R31087=0\n');
    await _write('#R2702=2\n');

    await _visual(
      event: 'Beleuchtung ausgeschaltet',
      question: 'Ist die Beleuchtung ausgeschaltet?',
    );
  }

  Future<void> _stopAllOutputs() async {
    Object? firstError;

    for (final command in [
      '#CMD idle 0\n',
      '#R3502=0\n',
      '#R4002=0\n',
      '#R31087=0\n',
      '#R2702=2\n',
    ]) {
      try {
        await io.write(command, () => true);
      } catch (error) {
        firstError ??= error;
      }
    }

    if (firstError != null) {
      throw StateError(
        'Abschaltbefehle nicht vollständig übertragen: $firstError',
      );
    }
  }

  Future<void> _saveFinalConfiguration() async {
    final threshold = await _read(29000);

    if (threshold != finalReferenceThreshold) {
      throw StateError(
        'Speichern gesperrt: Referenz-Stromschwelle=$threshold.',
      );
    }

    onProgress('Abschließende Konfiguration speichern …');

    await _write('#R3002=0\n');
    await _pause(const Duration(milliseconds: 500));

    final readback = await _read(29000);

    await _record(
      stage: 'Installation',
      event: 'Konfiguration speichern angefordert',
      register: 3002,
      actual: 0,
      result: 'COMMAND_SENT',
      details:
      'Register 29000 nach Speicherbefehl=$readback. '
          'Flash-Persistenz nicht durch Neustart verifiziert.',
    );

    if (readback != finalReferenceThreshold) {
      throw StateError(
        'Stromschwelle nach Speicherbefehl unerwartet: $readback.',
      );
    }
  }

  Future<void> _prepareCustomerInstallation() async {
    onProgress('Position für Kundeninstallation löschen …');

    await _record(
      stage: 'Installation',
      event: 'Positionsreset angefordert',
      register: 4009,
      expected: 0,
      result: 'REQUESTED',
    );

    // Require reference during customer installation.
    // Do not start another physical reference movement.
    await _write('#R4009=0\n');

    await _record(
      stage: 'Installation',
      event: 'Positionsreset gesendet',
      register: 4009,
      actual: 0,
      result: 'COMMAND_SENT',
      details:
      'Übertragung bestätigt; Wirkung des Positionsresets '
          'nicht unabhängig verifiziert.',
    );

    await _pause(const Duration(milliseconds: 500));

    final moving = await _read(12503);
    final pwm = await _read(31087);
    final error = await _read(12002);
    final reference = await _read(12010);

    final okay = moving == 0 && pwm == 0 && error == 0;

    await _record(
      stage: 'Installation',
      event: 'Zustand nach Positionsreset',
      actual:
      'Bewegung=$moving; PWM=$pwm; '
          'Fehler=$error; Referenzstatus=$reference',
      result: okay ? 'OUTPUTS_OK' : 'FAIL',
    );

    if (!okay) {
      throw StateError(
        'Unzulässiger Zustand nach Positionsreset: '
            'Bewegung=$moving; PWM=$pwm; Fehler=$error.',
      );
    }
  }

  Future<FunctionalTestResult> run() async {
    if (_running) {
      throw StateError('Prüfung läuft bereits.');
    }

    if (history.operatorName.trim().isEmpty) {
      throw StateError('Bitte zuerst den Prüfer eintragen.');
    }

    _running = true;

    var status = 'FAIL';
    var message = '';
    var outputsStopped = false;
    var csvSaved = false;
    var functionPassed = false;
    var thresholdRestored = false;
    var finalPreparationSent = false;
    var temporaryThresholdAttempted = false;

    void addMessage(String text) {
      message = message.trim().isEmpty ? text : '$message $text';
    }

    try {
      await _record(
        stage: 'Funktionsprüfung',
        event: 'Start',
        result: 'IN_PROGRESS',
        details:
        'Referenzfahrt mit Schwelle 200; '
            'UP/DOWN; Beleuchtung; Wiederherstellung 7000; '
            'Konfiguration speichern; Positionsreset.',
      );

      await _verifyParameters();

      // Stop/exit a previous reference operation first.
      await _prepareNormalMode();

      temporaryThresholdAttempted = true;
      await _setReferenceThreshold(testReferenceThreshold);

      await _performInitialReferenceRun();

      // Confirm Normal mode before UP/DOWN.
      await _prepareNormalMode();

      await _move(up: true);

      onProgress('Richtungspause …');
      await _pause(const Duration(seconds: 1));

      await _move(up: false);
      await _lighting();

      functionPassed = true;
    } catch (error) {
      addMessage(error.toString());
    }

    onProgress('Ausgänge stoppen und Stillstand prüfen …');

    try {
      await _stopAllOutputs();
      await _waitUntilStopped();

      final moving = await io.read(12503);
      final pwm = await io.read(31087);
      final error = await io.read(12002);

      outputsStopped = moving == 0 && pwm == 0;

      await _record(
        stage: 'Endzustand',
        event: 'Stillstand und PWM-Aus',
        expected: 'Bewegung=0; PWM=0',
        actual: 'Bewegung=$moving; PWM=$pwm',
        result: outputsStopped ? 'VERIFIED' : 'FAIL',
        details: 'Fehlerstatus=$error',
      );

      if (!outputsStopped || error != 0) {
        functionPassed = false;

        addMessage(
          'Endzustand nicht fehlerfrei: '
              'Bewegung=$moving; PWM=$pwm; Fehler=$error.',
        );
      }
    } catch (error) {
      functionPassed = false;
      outputsStopped = false;
      addMessage('Abschaltung/Endprüfung: $error');
    }

    // Restore even if the test failed or was aborted.
    if (temporaryThresholdAttempted) {
      try {
        await _restoreReferenceThreshold();
        thresholdRestored = true;
      } catch (error) {
        functionPassed = false;

        addMessage(
          'Wiederherstellung der Referenz-Stromschwelle '
              'nicht bestätigt: $error',
        );
      }
    }

    if (functionPassed &&
        outputsStopped &&
        thresholdRestored &&
        !_abortRequested) {
      try {
        await _saveFinalConfiguration();
        await _prepareCustomerInstallation();

        finalPreparationSent = true;
      } catch (error) {
        addMessage('Abschließende Vorbereitung: $error');

        try {
          await _stopAllOutputs();
          await _waitUntilStopped();

          final moving = await io.read(12503);
          final pwm = await io.read(31087);

          outputsStopped = moving == 0 && pwm == 0;
        } catch (_) {
          outputsStopped = false;
        }
      }
    }

    if (_abortRequested) {
      status = 'ABORTED';
      addMessage('Prüfung durch Bediener abgebrochen.');
    } else if (functionPassed &&
        outputsStopped &&
        thresholdRestored &&
        finalPreparationSent) {
      status = 'FUNCTION_PASS_INSTALLATION_PENDING';

      message =
      'Referenzfahrt, Parameter, Bewegung und Beleuchtung '
          'bestanden. Referenz-Stromschwelle 7000 zurückgelesen. '
          'Speicherbefehl und Positionsreset gesendet. '
          'Flash-Persistenz und Wirkung des Positionsresets '
          'sind noch nicht unabhängig verifiziert.';
    } else {
      status = 'FAIL';

      if (message.trim().isEmpty) {
        message = 'Prüfung nicht vollständig bestanden.';
      }
    }

    try {
      await _record(
        stage: 'Funktionsprüfung',
        event: 'Abgeschlossen',
        result: status,
        details: message.trim(),
      );

      await history.ensureSaved();
      csvSaved = true;
    } catch (error) {
      addMessage('CSV-Speicherung fehlgeschlagen: $error');
    }

    _running = false;
    onProgress('Prüfung beendet.');

    return FunctionalTestResult(
      status: status,
      message: message.trim(),
      outputsVerifiedStopped: outputsStopped,
      csvSaved: csvSaved,
    );
  }
}