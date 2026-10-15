import 'dart:async';

import '../models/test_session.dart';
import 'test_history.dart';

class FunctionalTestIo {
  final Future<int> Function(int register) read;

  // The transport must check allowed immediately before writing.
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

  bool _abortRequested = false;
  bool _running = false;

  static const movementDuration = Duration(seconds: 5);
  static const reversalPause = Duration(seconds: 1);

  // Values are within the range used by your original app.
  static const lowPwm = 75;
  static const highPwm = 750;

  FunctionalTestRunner({
    required this.io,
    required this.history,
    required this.session,
    required this.approvedValues,
    required this.onProgress,
    required this.askVisual,
  });

  bool get isRunning => _running;

  void abort() {
    _abortRequested = true;

    // Best-effort immediate stop. The run's finally block
    // also stops outputs and verifies the stopped state.
    io.write(
      '#CMD idle 0\n',
          () => true,
    ).catchError((Object _) {});
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

  Future<void> _record(
      String stage,
      String event, {
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

  Future<void> _verifyIdentityAndParameters() async {
    onProgress('Identität und Parameter erneut prüfen …');

    final low = await _read(104);
    final high = await _read(105);
    final serial = (high * 65536 + low).toString();

    if (serial != session.controllerSerial) {
      throw StateError(
        'Die verbundene Steuerung stimmt nicht '
            'mit der gespeicherten Zuordnung überein.',
      );
    }

    await _record(
      'Vorprüfung',
      'Steuerungsidentität bestätigt',
      actual: serial,
      result: 'OK',
    );

    for (final entry in approvedValues.entries) {
      final value = await _read(entry.key);
      final matches = value == entry.value;

      await _record(
        'Vorprüfung',
        'Sollwert erneut geprüft',
        register: entry.key,
        expected: entry.value,
        actual: value,
        result: matches ? 'OK' : 'FAIL',
      );

      if (!matches) {
        throw StateError(
          'Parameterabweichung bei Register ${entry.key}.',
        );
      }
    }

    final error = await _read(12002);

    if (error != 0) {
      throw StateError('Steuerungsfehler: $error');
    }
  }

  Future<void> _prepareNormalMode() async {
    onProgress('Betriebsart für Bewegungsprüfung vorbereiten …');

    await _write('#CMD idle 0\n');
    await _write('#R4002=0\n');

    final referenceState = await _read(12010);
    final mode = await _read(12000);

    await _record(
      'Betriebsart',
      'Ausgangszustand',
      register: 12010,
      actual: referenceState,
      details: 'Kanalbetriebsart 12000=$mode',
    );

    if (referenceState == 1 || mode != 6) {
      // Sequence taken from the original app's
      // _exitReferenceAndEnableMovement implementation.
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
    }

    final checkedMode = await _read(12000);
    final checkedReference = await _read(12010);
    final moving = await _read(12503);
    final error = await _read(12002);

    await _record(
      'Betriebsart',
      'Bewegungsbereitschaft geprüft',
      actual: checkedMode,
      expected: 6,
      result: checkedMode == 6 &&
          checkedReference != 1 &&
          moving == 0 &&
          error == 0
          ? 'OK'
          : 'FAIL',
      details: '12010=$checkedReference; '
          '12503=$moving; 12002=$error',
    );

    if (checkedMode != 6 ||
        checkedReference == 1 ||
        moving != 0 ||
        error != 0) {
      throw StateError(
        'Steuerung nicht für normale Bewegung bereit. '
            'Referenz/Installation muss separat geprüft werden.',
      );
    }
  }

  Future<void> _stopMotor() async {
    await io.write('#CMD idle 0\n', () => true);
    await io.write('#R4002=0\n', () => true);
  }

  Future<void> _waitUntilStopped() async {
    final clock = Stopwatch()..start();

    while (clock.elapsed < const Duration(seconds: 4)) {
      if (await io.read(12503) == 0) return;

      await Future<void>.delayed(
        const Duration(milliseconds: 150),
      );
    }

    throw StateError(
      'Stillstand wurde nicht rechtzeitig bestätigt.',
    );
  }

  Future<void> _move({
    required bool up,
  }) async {
    final name = up ? 'UP' : 'DOWN';
    final command = up ? '#CMD up 0\n' : '#CMD down 0\n';

    onProgress('$name: Bewegung für 5 Sekunden …');

    final start = await _read(11503);
    final lower = await _read(20024);
    final upper = await _read(20025);

    if (lower >= upper ||
        start < lower ||
        start > upper) {
      throw StateError(
        'Position oder Verfahrgrenzen sind ungültig.',
      );
    }

    if ((up && start >= upper - 1) ||
        (!up && start <= lower + 1)) {
      throw StateError(
        '$name-Test nicht möglich: '
            'Zu wenig Weg bis zur Verfahrgrenze.',
      );
    }

    await _record(
      'Bewegung $name',
      'Start',
      register: 11503,
      actual: start,
      unit: 'mm',
      details: 'Sollzeit=5000 ms; '
          'Untergrenze=$lower; Obergrenze=$upper',
    );

    _check();

    final samples = <Map<String, int>>[];
    final clock = Stopwatch()..start();
    var active = true;
    var sawMovement = false;

    final deadlineStop = Completer<void>();

    // Observe this future immediately, including errors.
    final observedDeadline = deadlineStop.future;
    observedDeadline.catchError((Object _) {});

    final deadlineTimer = Timer(movementDuration, () {
      active = false;

      _stopMotor().then(
            (_) {
          if (!deadlineStop.isCompleted) {
            deadlineStop.complete();
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!deadlineStop.isCompleted) {
            deadlineStop.completeError(error, stackTrace);
          }
        },
      );
    });

    Future<void> repeatMovementCommand() async {
      while (active && !_abortRequested) {
        await io.write(
          command,
              () =>
          active &&
              !_abortRequested &&
              io.isConnected() &&
              clock.elapsed < movementDuration,
        );

        if (!active || _abortRequested) break;

        await Future<void>.delayed(
          const Duration(milliseconds: 800),
        );
      }
    }

    Future<void> monitor() async {
      while (active && !_abortRequested) {
        _check();

        final position = await _read(11503);

        if (!active) break;

        final error = await _read(12002);

        if (!active) break;

        final moving = await _read(12503);

        if (!active) break;

        samples.add({
          'elapsed_ms': clock.elapsedMilliseconds,
          'position': position,
          'error': error,
          'moving': moving,
        });

        if (moving == 1) sawMovement = true;

        if (error != 0) {
          throw StateError(
            'Steuerungsfehler während $name: $error',
          );
        }

        if (position < lower || position > upper) {
          throw StateError(
            'Position außerhalb der Verfahrgrenzen.',
          );
        }

        if ((up && position < start - 1) ||
            (!up && position > start + 1)) {
          throw StateError(
            'Unerwartete Bewegungsrichtung bei $name.',
          );
        }

        if ((up && position >= upper) ||
            (!up && position <= lower)) {
          throw StateError(
            'Verfahrgrenze während $name erreicht.',
          );
        }

        if (clock.elapsedMilliseconds > 1500 && moving == 0) {
          throw StateError(
            '$name wurde vor Ablauf der Prüfzeit gestoppt.',
          );
        }

        await Future<void>.delayed(
          const Duration(milliseconds: 100),
        );
      }

      _check();
    }

    final repeatFuture = repeatMovementCommand();
    final monitorFuture = monitor();

    try {
      await Future.wait<void>(
        [repeatFuture, monitorFuture],
        eagerError: true,
      );

      await observedDeadline;
      _check();
    } finally {
      active = false;
      deadlineTimer.cancel();

      // Stop before waiting for any remaining read to finish.
      try {
        await _stopMotor();
      } finally {
        // Drain both tasks so they cannot overlap the next step.
        await Future.wait<void>(
          [repeatFuture, monitorFuture],
        ).catchError((Object _) {});
      }

      if (!deadlineStop.isCompleted) {
        deadlineStop.complete();
      }

      for (final sample in samples) {
        await _record(
          'Bewegung $name',
          'Messwert',
          register: 11503,
          actual: sample['position'],
          unit: 'mm',
          details: 'elapsed_ms=${sample['elapsed_ms']}; '
              '12002=${sample['error']}; '
              '12503=${sample['moving']}',
        );
      }
    }

    await _waitUntilStopped();

    final end = await _read(11503);
    final error = await _read(12002);
    final delta = end - start;

    final directionCorrect = up ? delta > 0 : delta < 0;

    final passed =
        sawMovement && directionCorrect && error == 0;

    await _record(
      'Bewegung $name',
      'Ergebnis',
      register: 11503,
      expected: up ? 'Position steigt' : 'Position sinkt',
      actual: end,
      unit: 'mm',
      result: passed ? 'OK' : 'FAIL',
      details: 'Start=$start; Ende=$end; Differenz=$delta; '
          'Sollzeit=5000 ms; '
          'Zeit_bis_Stillstandsprüfung_ms=${clock.elapsedMilliseconds}; '
          'Bewegung_erkannt=$sawMovement; Fehler=$error',
    );

    if (!passed) {
      throw StateError('$name-Bewegungsprüfung fehlgeschlagen.');
    }
  }

  Future<void> _ramp({
    required int from,
    required int to,
    required String name,
  }) async {
    onProgress(name);

    const steps = 10;

    for (var step = 0; step <= steps; step++) {
      final target =
      (from + (to - from) * step / steps).round();

      await _write('#R31087=$target\n');

      final actual = await _read(31087);
      final error = await _read(12002);

      await _record(
        'Beleuchtung',
        name,
        register: 31087,
        expected: target,
        actual: actual,
        result: actual == target && error == 0
            ? 'REGISTER_OK'
            : 'FAIL',
        details: 'Nur Registerprüfung; '
            'visuelle Bestätigung erfolgt separat.',
      );

      if (actual != target || error != 0) {
        throw StateError(
          'PWM-Rückmeldung oder Fehlerstatus nicht korrekt.',
        );
      }

      if (step < steps) {
        await _pause(const Duration(milliseconds: 500));
      }
    }
  }

  Future<bool> _visualQuestion(String question) async {
    onProgress('Visuelle Bestätigung durch Prüfer erforderlich.');

    var answered = false;
    var answer = false;

    final answerFuture = askVisual(question).then((value) {
      answer = value;
      answered = true;
    });

    final clock = Stopwatch()..start();

    try {
      while (!answered) {
        _check();

        if (clock.elapsed > const Duration(minutes: 2)) {
          throw StateError(
            'Zeitüberschreitung bei visueller Bestätigung.',
          );
        }

        // Keep communication active while waiting for the operator.
        final error = await _read(12002);

        if (error != 0) {
          throw StateError('Steuerungsfehler: $error');
        }

        await _pause(const Duration(milliseconds: 500));
      }

      await answerFuture;

      await _record(
        'Beleuchtung',
        question,
        actual: answer ? 'JA' : 'NEIN',
        result: answer ? 'VISUAL_OK' : 'VISUAL_FAIL',
        details: 'Prüfer: ${history.operatorName}',
      );

      return answer;
    } finally {
      // The page clears any outstanding question when the run ends.
    }
  }

  Future<void> _lighting() async {
    onProgress('Beleuchtung einschalten …');

    await _write('#R31087=$lowPwm\n');
    await _write('#R2702=1\n');

    await _ramp(
      from: lowPwm,
      to: highPwm,
      name: 'Helligkeit niedrig → hoch',
    );

    if (!await _visualQuestion(
      'Ist die Helligkeit sichtbar angestiegen?',
    )) {
      throw StateError(
        'Helligkeitsanstieg visuell nicht akzeptiert.',
      );
    }

    await _ramp(
      from: highPwm,
      to: lowPwm,
      name: 'Helligkeit hoch → niedrig',
    );

    if (!await _visualQuestion(
      'Ist die Helligkeit sichtbar abgesunken?',
    )) {
      throw StateError(
        'Helligkeitsabsenkung visuell nicht akzeptiert.',
      );
    }

    await _write('#R31087=0\n');
    await _write('#R2702=2\n');

    if (!await _visualQuestion(
      'Ist die Beleuchtung ausgeschaltet?',
    )) {
      throw StateError(
        'Ausschalten der Beleuchtung visuell nicht bestätigt.',
      );
    }
  }

  Future<void> _stopAllOutputs() async {
    final errors = <String>[];

    for (final command in [
      '#CMD idle 0\n',
      '#R4002=0\n',
      '#R31087=0\n',
      '#R2702=2\n',
    ]) {
      try {
        await io.write(command, () => true);
      } catch (error) {
        errors.add(error.toString());
      }
    }

    if (errors.isNotEmpty) {
      throw StateError(
        'Ausgänge konnten nicht vollständig gestoppt werden: '
            '${errors.join("; ")}',
      );
    }
  }

  Future<FunctionalTestResult> run() async {
    if (_running) {
      throw StateError('Prüfung läuft bereits.');
    }

    _running = true;

    var passed = false;
    var stopped = false;
    var csvSaved = false;
    var reason = '';

    try {
      await _record(
        'Funktionsprüfung',
        'Prüfung gestartet; Vorrichtung bestätigt',
        result: 'IN_PROGRESS',
        details: 'UP=5 s; DOWN=5 s; '
            'PWM=$lowPwm bis $highPwm; '
            'Installation zurückgestellt.',
      );

      await _verifyIdentityAndParameters();
      await _prepareNormalMode();

      await _move(up: true);

      onProgress('Stillstand und Pause vor Richtungswechsel …');
      await _waitUntilStopped();
      await _pause(reversalPause);

      await _move(up: false);

      await _lighting();

      passed = true;
      reason = 'Parameter-, Bewegungs- und '
          'visuelle Beleuchtungsprüfung bestanden.';
    } catch (error) {
      reason = error.toString();
    } finally {
      onProgress('Ausgänge stoppen und Endzustand prüfen …');

      try {
        await _stopAllOutputs();
        await _waitUntilStopped();

        final moving = await io.read(12503);
        final pwm = await io.read(31087);
        final error = await io.read(12002);

        stopped = moving == 0 && pwm == 0;

        if (!stopped || error != 0) {
          passed = false;
          reason = '$reason '
              'Endzustand: 12503=$moving; '
              '31087=$pwm; 12002=$error.';
        }
      } catch (error) {
        passed = false;
        stopped = false;
        reason = '$reason Endzustand nicht bestätigt: $error';
      }

      final status = _abortRequested
          ? 'ABORTED'
          : passed && stopped
          ? 'FUNCTION_PASS_INSTALLATION_PENDING'
          : 'FAIL';

      try {
        await _record(
          'Funktionsprüfung',
          'Abgeschlossen',
          result: status,
          details: reason,
        );

        await _record(
          'Endzustand',
          'Stillstand und PWM-Aus',
          result: stopped ? 'VERIFIED' : 'NOT_VERIFIED',
          details: 'Installationsvorbereitung nicht durchgeführt.',
        );

        await history.ensureSaved();
        csvSaved = true;
      } catch (error) {
        reason = '$reason CSV-Speicherfehler: $error';
      }

      _running = false;

      return FunctionalTestResult(
        status: status,
        message: reason,
        outputsVerifiedStopped: stopped,
        csvSaved: csvSaved,
      );
    }
  }
}