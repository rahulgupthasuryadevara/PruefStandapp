import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/test_session.dart';
import '../services/station_service.dart';
import '../services/test_history.dart';
import 'parameter_check_page.dart';
import 'test_history_page.dart';
import '../services/functional_test_runner.dart';
import 'functional_test_page.dart';


class BluetoothPage extends StatefulWidget {
  final String casingNumber;

  const BluetoothPage({
    super.key,
    required this.casingNumber,
  });

  @override
  State<BluetoothPage> createState() => _BluetoothPageState();
}

class _BluetoothPageState extends State<BluetoothPage> {
  static const orange = Color(0xFFF37216);

  static final uartService =
  Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  static final uartWrite =
  Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
  static final uartNotify =
  Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  List<ScanResult> _results = [];

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _scanStateSubscription;
  StreamSubscription<BluetoothConnectionState>?
  _connectionSubscription;
  StreamSubscription<List<int>>? _notifySubscription;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeCharacteristic;

  final Map<int, Completer<int>> _pendingReads = {};
  Future<void> _functionalWriteTail = Future<void>.value();

  Timer? _statusPollTimer;

  late TestSession _testSession;
  TestHistory? _history;

  bool _stationReady = false;
  bool _stationInitializing = false;
  bool _scanning = false;
  bool _busy = false;
  bool _ready = false;
  bool _writeBusy = false;
  bool _readErrorNext = true;
  bool _disposed = false;

  int _session = 0;

  String _status = 'Prüfstation wird vorbereitet …';
  String _receiveBuffer = '';
  String _deviceName = '';

  int? _serialLow;
  int? _serialMid;
  DateTime? _lastResponseAt;

  int? get _serialNumber {
    final low = _serialLow;
    final mid = _serialMid;

    if (low == null || mid == null) return null;

    return mid * 65536 + low;
  }

  @override
  void initState() {
    super.initState();

    _testSession = TestSession.create(widget.casingNumber);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeStation();
    });

    _scanSubscription = FlutterBluePlus.onScanResults.listen(
          (results) {
        if (!mounted || _disposed) return;

        final filtered = results.where((result) {
          final advertisedName =
          result.advertisementData.advName.toUpperCase();
          final platformName =
          result.device.platformName.toUpperCase();

          return advertisedName.contains('LMC') ||
              platformName.contains('LMC');
        }).toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));

        setState(() => _results = filtered);
      },
      onError: (Object error) {
        _setStatus('Scanfehler: $error');
        _log('Scanfehler: $error');
      },
    );

    _scanStateSubscription = FlutterBluePlus.isScanning.listen(
          (scanning) {
        if (!mounted || _disposed) return;
        setState(() => _scanning = scanning);
      },
    );
  }

  void _log(String message) {
    debugPrint('BLE: $message');

    _history?.recordBackground(
      stage: 'Bluetooth',
      event: 'Kommunikation',
      details: message,
    );
  }

  void _setStatus(String message) {
    if (!mounted || _disposed) return;
    setState(() => _status = message);
  }

  bool _isCurrentSession(
      BluetoothDevice device,
      int session,
      ) {
    return !_disposed &&
        mounted &&
        session == _session &&
        _device == device;
  }

  void _checkConnection(
      BluetoothDevice device,
      int session,
      ) {
    if (!_isCurrentSession(device, session) ||
        !device.isConnected) {
      throw StateError(
        'Bluetooth-Verbindung nicht mehr verfügbar.',
      );
    }
  }

  Future<int?> _showStationSetup() async {
    int? selectedStation;
    final formKey = GlobalKey<FormState>();

    return showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Prüfstation einrichten'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Diese Einstellung ist nur einmal erforderlich.\n\n'
                        'Jedes Prüfgerät benötigt eine eigene '
                        'Prüfstationsnummer. Bitte die zugewiesene '
                        'Nummer eingeben.',
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    maxLength: 2,
                    decoration: const InputDecoration(
                      labelText: 'Prüfstationsnummer',
                      hintText: 'Zum Beispiel: 01',
                      border: OutlineInputBorder(),
                    ),
                    validator: (text) {
                      final value =
                      int.tryParse(text?.trim() ?? '');

                      if (value == null ||
                          value < 1 ||
                          value > 99) {
                        return 'Nummer von 01 bis 99 eingeben.';
                      }

                      return null;
                    },
                    onSaved: (text) {
                      selectedStation = int.parse(text!.trim());
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Später'),
            ),
            FilledButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;

                formKey.currentState!.save();

                Navigator.pop(dialogContext, selectedStation);
              },
              child: const Text('Speichern'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _initializeStation() async {
    if (!mounted ||
        _disposed ||
        _stationInitializing ||
        _stationReady) {
      return;
    }

    setState(() {
      _stationInitializing = true;
      _status = 'Prüfstation wird vorbereitet …';
    });

    try {
      final existing =
      await StationService.getStationNumber();

      if (!mounted || _disposed) return;

      if (existing == null) {
        final entered = await _showStationSetup();

        if (!mounted || _disposed) return;

        if (entered == null) {
          _setStatus('Bitte zuerst die Prüfstation einrichten.');
          return;
        }

        await StationService.configure(entered);
      }

      if (!mounted || _disposed) return;

      final allocation = await StationService.allocateNumber();

      if (!mounted || _disposed) return;

      final numberedSession = _testSession.withTestNumber(
        allocation.testNumber,
        allocation.stationNumber,
      );

      final history = await TestHistory.create(numberedSession);

      if (!mounted || _disposed) return;

      setState(() {
        _testSession = numberedSession;
        _history = history;
        _stationReady = true;
        _status = 'Steuerung einschalten und Scan starten.';
      });
    } catch (error) {
      _setStatus(
        'Prüfstation oder CSV konnte nicht '
            'vorbereitet werden: $error',
      );
    } finally {
      if (mounted && !_disposed) {
        setState(() => _stationInitializing = false);
      }
    }
  }

  Future<bool> _requestPermissions() async {
    final android = await DeviceInfoPlugin().androidInfo;

    if (android.version.sdkInt >= 31) {
      final permissions = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();

      return permissions.values.every(
            (status) => status.isGranted,
      );
    }

    return (await Permission.locationWhenInUse.request())
        .isGranted;
  }

  Future<void> _scan() async {
    if (!_stationReady ||
        _busy ||
        _scanning ||
        _device != null) {
      return;
    }

    setState(() {
      _busy = true;
      _results = [];
      _status = 'Berechtigungen werden geprüft …';
    });

    try {
      await _history!.ensureSaved();

      if (!await _requestPermissions()) {
        _setStatus(
          'Berechtigung fehlt. '
              'Bitte in den App-Einstellungen erlauben.',
        );
        return;
      }

      if (!mounted || _disposed) return;

      if (!await FlutterBluePlus.isSupported) {
        _setStatus('Bluetooth LE wird nicht unterstützt.');
        return;
      }

      final adapter = await FlutterBluePlus.adapterState
          .where(
            (state) => state != BluetoothAdapterState.unknown,
      )
          .first
          .timeout(const Duration(seconds: 5));

      if (adapter != BluetoothAdapterState.on) {
        _setStatus('Bitte Bluetooth am Handy einschalten.');
        return;
      }

      if (!mounted || _disposed) return;

      _setStatus('Suche nach LMC-Steuerungen …');
      _log('Scan gestartet');

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
      );
    } catch (error) {
      _setStatus('Scan oder Speicherung fehlgeschlagen: $error');
      _log('Scanfehler: $error');
    } finally {
      if (mounted && !_disposed) {
        setState(() => _busy = false);
      }
    }
  }

  String _name(ScanResult result) {
    final advertisedName = result.advertisementData.advName;

    if (advertisedName.isNotEmpty) return advertisedName;

    final platformName = result.device.platformName;

    return platformName.isEmpty
        ? 'Unbenannte Steuerung'
        : platformName;
  }

  void _handleReceivedBytes(
      List<int> bytes,
      BluetoothDevice device,
      int session,
      ) {
    if (!_isCurrentSession(device, session)) return;

    _receiveBuffer += String.fromCharCodes(bytes);

    while (_receiveBuffer.contains('\n')) {
      final end = _receiveBuffer.indexOf('\n');
      final line = _receiveBuffer.substring(0, end).trim();

      _receiveBuffer = _receiveBuffer.substring(end + 1);

      if (line.isEmpty) continue;

      _log('RX: $line');

      final match =
      RegExp(r'^#R(\d+)=(-?\d+)$').firstMatch(line);

      if (match == null) continue;

      final register = int.parse(match.group(1)!);
      final value = int.parse(match.group(2)!);

      final pending = _pendingReads.remove(register);

      if (pending != null && !pending.isCompleted) {
        pending.complete(value);
      }

      if (!mounted || _disposed) return;

      setState(() {
        _lastResponseAt = DateTime.now();

        switch (register) {
          case 104:
            _serialLow = value;
            break;
          case 105:
            _serialMid = value;
            break;
        }
      });
    }

    if (_receiveBuffer.length > 8192) {
      _receiveBuffer = '';
      _log('Empfangspuffer geleert: Zeilenende fehlt');
    }
  }

  Future<void> _sendRead(
      int register,
      BluetoothDevice device,
      int session,
      ) async {
    _checkConnection(device, session);

    final characteristic = _writeCharacteristic;

    if (characteristic == null) {
      throw StateError('UART-Schreibkanal nicht verfügbar.');
    }

    if (_writeBusy) {
      throw StateError(
        'Eine Bluetooth-Schreiboperation läuft bereits.',
      );
    }

    _writeBusy = true;

    try {
      final command = '#GR=$register\n';

      _log('TX: ${command.trim()}');

      await characteristic
          .write(
        command.codeUnits,
        withoutResponse:
        characteristic.properties.writeWithoutResponse,
      )
          .timeout(const Duration(seconds: 2));

      _checkConnection(device, session);
    } finally {
      _writeBusy = false;
    }
  }

  void _startStatusPolling(
      BluetoothDevice device,
      int session,
      ) {
    _statusPollTimer?.cancel();
    _readErrorNext = true;

    _statusPollTimer = Timer.periodic(
      const Duration(seconds: 1),
          (timer) async {
        if (!_isCurrentSession(device, session) ||
            !device.isConnected ||
            !_ready) {
          timer.cancel();
          return;
        }

        if (_writeBusy) return;

        final register = _readErrorNext ? 12002 : 12010;
        _readErrorNext = !_readErrorNext;

        try {
          await _sendRead(register, device, session);

          if (!_isCurrentSession(device, session)) return;

          final last = _lastResponseAt;

          if (last == null ||
              DateTime.now().difference(last) >
                  const Duration(seconds: 10)) {
            _setStatus(
              'Bluetooth verbunden, aber keine aktuellen '
                  'Registerantworten.',
            );
          } else if (_history?.lastSaveError != null) {
            _setStatus(
              'Bluetooth verbunden. CSV-Speicherfehler vorhanden.',
            );
          } else {
            _setStatus('Verbunden. Statusabfragen laufen.');
          }
        } catch (error) {
          timer.cancel();

          if (!_isCurrentSession(device, session)) return;

          _log('Statusabfrage fehlgeschlagen: $error');

          setState(() {
            _ready = false;
            _status = 'Statusabfrage fehlgeschlagen: $error';
          });
        }
      },
    );
  }

  Future<void> _clearListeners() async {
    _statusPollTimer?.cancel();
    _statusPollTimer = null;

    final connection = _connectionSubscription;
    final notify = _notifySubscription;

    _connectionSubscription = null;
    _notifySubscription = null;

    await connection?.cancel();
    await notify?.cancel();

    _writeCharacteristic = null;
    _receiveBuffer = '';
  }

  Future<void> _connect(ScanResult result) async {
    if (!_stationReady || _busy || _device != null) return;

    final device = result.device;
    final session = ++_session;

    setState(() {
      _busy = true;
      _ready = false;
      _serialLow = null;
      _serialMid = null;
      _lastResponseAt = null;
      _deviceName = _name(result);
      _status = 'Verbindung zu $_deviceName …';
    });

    try {
      await _history!.ensureSaved();
      await _clearListeners();
      await FlutterBluePlus.stopScan();

      await Future.delayed(
        const Duration(milliseconds: 500),
      );

      if (!mounted || _disposed || session != _session) return;

      _device = device;

      _log('Verbinden: $_deviceName / ${device.remoteId}');

      await device.connect(
        autoConnect: false,
        mtu: null,
        timeout: const Duration(seconds: 15),
      );

      _checkConnection(device, session);

      _connectionSubscription = device.connectionState.listen(
            (state) {
          if (!_isCurrentSession(device, session)) return;

          _log(
            'State: $state; reason: ${device.disconnectReason}',
          );

          if (state == BluetoothConnectionState.disconnected) {
            _statusPollTimer?.cancel();
            _statusPollTimer = null;
            _notifySubscription?.cancel();
            _notifySubscription = null;
            _writeCharacteristic = null;
            _receiveBuffer = '';

            setState(() {
              _device = null;
              _ready = false;
              _status =
              'Verbindung getrennt: ${device.disconnectReason}';
            });
          }
        },
      );

      await Future.delayed(
        const Duration(milliseconds: 1000),
      );

      _checkConnection(device, session);
      _setStatus('Kommunikationsdienste werden gesucht …');

      final services = await device
          .discoverServices()
          .timeout(const Duration(seconds: 8));

      _checkConnection(device, session);

      BluetoothCharacteristic? write;
      BluetoothCharacteristic? notify;

      for (final service in services) {
        if (service.uuid != uartService) continue;

        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == uartWrite) {
            write = characteristic;
          }

          if (characteristic.uuid == uartNotify) {
            notify = characteristic;
          }
        }
      }

      if (write == null ||
          !(write.properties.write ||
              write.properties.writeWithoutResponse)) {
        throw StateError('UART-Schreibkanal nicht gefunden.');
      }

      if (notify == null ||
          !(notify.properties.notify ||
              notify.properties.indicate)) {
        throw StateError('UART-Antwortkanal nicht gefunden.');
      }

      _writeCharacteristic = write;

      _notifySubscription = notify.onValueReceived.listen(
            (bytes) => _handleReceivedBytes(bytes, device, session),
        onError: (Object error) {
          if (!_isCurrentSession(device, session)) return;

          _log('Empfangsfehler: $error');
          _setStatus('Fehler beim Empfang: $error');
        },
      );

      _setStatus('Antwortkanal wird aktiviert …');

      await notify
          .setNotifyValue(true)
          .timeout(const Duration(seconds: 5));

      await Future.delayed(
        const Duration(milliseconds: 500),
      );

      _checkConnection(device, session);

      for (final register in [12002, 104, 105]) {
        await _sendRead(register, device, session);

        await Future.delayed(
          const Duration(milliseconds: 160),
        );
      }

      _checkConnection(device, session);

      setState(() {
        _ready = true;
        _status = 'Verbunden. Statusabfragen laufen.';
      });

      _log('Bluetooth-Transport bereit');
      _startStatusPolling(device, session);
    } catch (error) {
      _log('Setup fehlgeschlagen: $error');
      await _clearListeners();

      try {
        await device.disconnect();
      } catch (_) {}

      if (mounted && !_disposed && session == _session) {
        setState(() {
          _device = null;
          _ready = false;
          _status = 'Verbindung fehlgeschlagen: $error';
        });
      }
    } finally {
      if (!mounted || _disposed) {
        try {
          await device.disconnect();
        } catch (_) {}
      } else if (session == _session) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _disconnect() async {
    final device = _device;

    if (device == null || _busy) return;

    ++_session;

    setState(() {
      _busy = true;
      _ready = false;
      _status = 'Verbindung wird getrennt …';
    });

    try {
      _log('Verbindung manuell trennen');
      await _clearListeners();
      await device.disconnect();

      if (mounted && !_disposed) {
        setState(() {
          _device = null;
          _status = 'Verbindung getrennt.';
        });
      }
    } catch (error) {
      _log('Trennen fehlgeschlagen: $error');

      if (mounted && !_disposed) {
        setState(() {
          if (!device.isConnected) _device = null;
          _status = 'Trennen fehlgeschlagen: $error';
        });
      }
    } finally {
      if (mounted && !_disposed) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _waitForWrite(
      BluetoothDevice device,
      int session,
      ) async {
    final deadline =
    DateTime.now().add(const Duration(seconds: 3));

    while (_writeBusy) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'Vorherige Bluetooth-Abfrage nicht abgeschlossen.',
        );
      }

      await Future.delayed(
        const Duration(milliseconds: 50),
      );

      _checkConnection(device, session);
    }

    _checkConnection(device, session);
  }

  Future<void> _readDeviceDataAgain() async {
    final device = _device;

    if (device == null || _busy || !_ready) return;

    final session = _session;

    setState(() => _busy = true);
    _statusPollTimer?.cancel();

    try {
      await _waitForWrite(device, session);

      setState(() {
        _serialLow = null;
        _serialMid = null;
      });

      for (final register in [104, 105]) {
        await _sendRead(register, device, session);

        await Future.delayed(
          const Duration(milliseconds: 160),
        );
      }
    } catch (error) {
      _log('Seriennummer-Abfrage fehlgeschlagen: $error');
      _setStatus('Seriennummer-Abfrage fehlgeschlagen: $error');
    } finally {
      if (_isCurrentSession(device, session) &&
          device.isConnected &&
          _ready) {
        _startStatusPolling(device, session);
      }

      if (mounted && !_disposed && session == _session) {
        setState(() => _busy = false);
      }
    }
  }

  Future<int> _readRegisterAndWait(
      int register,
      BluetoothDevice device,
      int session,
      ) async {
    _checkConnection(device, session);

    if (_pendingReads.containsKey(register)) {
      throw StateError(
        'Register $register wird bereits abgefragt.',
      );
    }

    final completer = Completer<int>();
    _pendingReads[register] = completer;

    final response = completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        throw TimeoutException(
          'Keine Antwort für Register $register.',
        );
      },
    );

    try {
      final results = await Future.wait<Object?>(
        [
          _sendRead(register, device, session)
              .then<Object?>((_) => null),
          response.then<Object?>((value) => value),
        ],
        eagerError: true,
      );

      _checkConnection(device, session);

      return results[1] as int;
    } finally {
      if (identical(_pendingReads[register], completer)) {
        _pendingReads.remove(register);
      }
    }
  }

  Future<Map<int, int>> _readParameterValues() async {
    final device = _device;

    if (device == null || !_ready || _busy) {
      throw StateError(
        'Steuerung nicht bereit. Bitte erneut verbinden.',
      );
    }

    final session = _session;

    setState(() => _busy = true);
    _statusPollTimer?.cancel();

    try {
      await _history!.ensureSaved();
      await _waitForWrite(device, session);

      await Future.delayed(
        const Duration(milliseconds: 200),
      );

      _checkConnection(device, session);

      final values = <int, int>{};

      for (final register in [
        30001,
        20000,
        20010,
        20012,
        102,
        104,
        105,
        106,   // Production year/month: raw value
        114,
        12002,
        12010,
      ]) {
        values[register] = await _readRegisterAndWait(
          register,
          device,
          session,
        );

        await Future.delayed(
          const Duration(milliseconds: 100),
        );
      }

      final serial =
      (values[105]! * 65536 + values[104]!).toString();

      if (serial != _testSession.controllerSerial) {
        throw StateError(
          'Steuerungsseriennummer stimmt nicht '
              'mit der Zuordnung überein.',
        );
      }

      final history = _history;

      if (history == null) {
        throw StateError('Keine Prüfhistorie vorhanden.');
      }

      await history.record(
        stage: 'Identifikation',
        event: 'Produktionsdatum gelesen',
        register: 106,
        actual: values[106],
        result: 'INFO',
        details: 'Produktionsjahr/-monat als unveränderter Registerwert.',
      );

      await history.record(
        stage: 'Identifikation',
        event: 'Geraetespannung gelesen',
        register: 114,
        actual: values[114],
        result: 'INFO',
        details: 'Gerätespannung als unveränderter Registerwert.',
      );

      return values;
    } finally {
      if (_isCurrentSession(device, session) &&
          device.isConnected &&
          _ready) {
        _startStatusPolling(device, session);
      }

      if (mounted && !_disposed && session == _session) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openParameterCheck() async {
    final history = _history;

    if (!_stationReady ||
        history == null ||
        _device == null ||
        !_ready ||
        _busy ||
        _serialNumber == null) {
      return;
    }

    setState(() => _busy = true);

    try {
      final paired = _testSession.pairWith(
        _serialNumber!.toString(),
      );

      await history.setPairing(paired);

      if (!mounted || _disposed) return;

      final device = _device;

      if (device == null || !device.isConnected || !_ready) {
        throw StateError(
          'Verbindung vor dem Seitenwechsel getrennt.',
        );
      }

      setState(() {
        _testSession = paired;
        _busy = false;
      });

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ParameterCheckPage(
            casingNumber: widget.casingNumber,
            testSession: paired,
            readValues: _readParameterValues,
            history: history,
            runFunctionalTest: _openFunctionalTest,
          ),
          ),

      );
    } catch (error) {
      _setStatus(
        'Zuordnung oder Speicherung fehlgeschlagen: $error',
      );
    } finally {
      if (mounted && !_disposed) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openHistory() async {
    try {
      await _history?.ensureSaved();

      if (!mounted || _disposed) return;

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const TestHistoryPage(),
        ),
      );
    } catch (error) {
      _setStatus('CSV-Speicherung fehlgeschlagen: $error');
    }
  }

  Future<void> _functionalWrite(
      String command,
      bool Function() allowed,
      BluetoothDevice device,
      int session,
      ) {
    final operation = _functionalWriteTail.then((_) async {
      _checkConnection(device, session);

      await _waitForWrite(device, session);

      // Recheck after waiting, so an expired movement command
      // cannot restart the drive after a stop was requested.
      if (!allowed()) return;

      final characteristic = _writeCharacteristic;

      if (characteristic == null) {
        throw StateError('Bluetooth-Schreibkanal fehlt.');
      }

      _writeBusy = true;

      try {
        _log('TX: ${command.trim()}');

        await characteristic
            .write(
          command.codeUnits,
          withoutResponse:
          characteristic.properties.writeWithoutResponse,
        )
            .timeout(const Duration(milliseconds: 700));

        _checkConnection(device, session);
      } finally {
        _writeBusy = false;
      }
    });

    _functionalWriteTail = operation.then<void>(
          (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );

    return operation;
  }

  Future<int> _functionalRead(
      int register,
      BluetoothDevice device,
      int session,
      ) async {
    _checkConnection(device, session);

    if (_pendingReads.containsKey(register)) {
      throw StateError(
        'Register $register wird bereits gelesen.',
      );
    }

    final completer = Completer<int>();
    _pendingReads[register] = completer;

    final totalTime = Stopwatch()..start();

    try {
      // Register the response receiver before sending.
      // An immediate response is therefore retained.
      await _functionalWrite(
        '#GR=$register\n',
            () => true,
        device,
        session,
      );

      _checkConnection(device, session);

      final responseTime = Stopwatch()..start();

      // Start the response timeout AFTER the write completes.
      final value = await completer.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          throw TimeoutException(
            'Keine Antwort für Register $register '
                'innerhalb von 3 Sekunden nach dem Schreiben.',
          );
        },
      );

      _checkConnection(device, session);

      _log(
        'READ OK: Register $register=$value; '
            'Antwortzeit=${responseTime.elapsedMilliseconds} ms; '
            'Gesamtzeit=${totalTime.elapsedMilliseconds} ms',
      );

      return value;
    } catch (error) {
      _log(
        'READ FAILED: Register $register; '
            'Gesamtzeit=${totalTime.elapsedMilliseconds} ms; '
            'Fehler=$error',
      );

      rethrow;
    } finally {
      if (identical(_pendingReads[register], completer)) {
        _pendingReads.remove(register);
      }
    }
  }

  Future<void> _openFunctionalTest(
      Map<int, int> approvedValues,
      ) async {
    final device = _device;
    final history = _history;

    if (device == null ||
        history == null ||
        !_ready ||
        _busy ||
        !device.isConnected) {
      throw StateError(
        'Steuerung nicht bereit. Bitte Verbindung prüfen.',
      );
    }

    final session = _session;

    setState(() => _busy = true);
    _statusPollTimer?.cancel();

    try {
      await _waitForWrite(device, session);

      // Allow a previous polling response to finish.
      await Future<void>.delayed(
        const Duration(milliseconds: 250),
      );

      _checkConnection(device, session);
      await history.ensureSaved();

      if (!mounted || _disposed) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FunctionalTestPage(
            session: _testSession,
            history: history,
            approvedValues: Map<int, int>.from(approvedValues),
            io: FunctionalTestIo(
              read: (register) {
                return _functionalRead(
                  register,
                  device,
                  session,
                );
              },
              write: (command, allowed) {
                return _functionalWrite(
                  command,
                  allowed,
                  device,
                  session,
                );
              },
              isConnected: () {
                return _isCurrentSession(device, session) &&
                    device.isConnected &&
                    _ready;
              },
            ),
          ),
        ),
      );
    } finally {
      if (_isCurrentSession(device, session) &&
          device.isConnected &&
          _ready) {
        _startStatusPolling(device, session);
      }

      if (mounted && !_disposed && session == _session) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _history?.recordBackground(
      stage: 'Sitzung',
      event: 'Bluetooth-Seite verlassen',
      details: 'Kein automatisches Gesamtergebnis vergeben.',
    );

    _disposed = true;
    ++_session;

    _statusPollTimer?.cancel();
    _scanSubscription?.cancel();
    _scanStateSubscription?.cancel();
    _connectionSubscription?.cancel();
    _notifySubscription?.cancel();

    unawaited(
      FlutterBluePlus.stopScan().catchError((Object _) {}),
    );

    final device = _device;

    if (device != null) {
      unawaited(
        device.disconnect().catchError((Object _) {}),
      );
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _device != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('LMC-Steuerung verbinden'),
        actions: [
          IconButton(
            tooltip: 'Prüfhistorie',
            icon: const Icon(Icons.history),
            onPressed: _busy ? null : _openHistory,
          ),
        ],
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
                    'Gehäuse: ${widget.casingNumber}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SelectableText(
                    'Prüfungsnummer: ${_testSession.displayNumber}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_stationReady) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Prüfstation: '
                          '${_testSession.stationNumber!.toString().padLeft(2, '0')}',
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    _testSession.controllerSerial == null
                        ? 'Zuordnung erfolgt mit '
                        '„Zuordnen und weiter“.'
                        : 'Zugeordnet: '
                        '${_testSession.casingNumber}'
                        ' ↔ ${_testSession.controllerSerial}',
                  ),
                ],
              ),
            ),
          ),

          if (!_stationReady) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed:
              _stationInitializing ? null : _initializeStation,
              icon: const Icon(Icons.settings),
              label: Text(
                _stationInitializing
                    ? 'Bitte warten …'
                    : 'Prüfstation einrichten / erneut versuchen',
              ),
            ),
          ],

          const SizedBox(height: 16),

          Card(
            child: ListTile(
              leading: Icon(
                _ready
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth,
                color: orange,
              ),
              title: Text(_status),
              subtitle: connected
                  ? Text(
                '$_deviceName\n'
                    'Bluetooth-ID: ${_device!.remoteId}',
              )
                  : null,
            ),
          ),

          const SizedBox(height: 16),

          if (!connected)
            FilledButton.icon(
              onPressed: !_stationReady || _busy || _scanning
                  ? null
                  : _scan,
              icon: const Icon(Icons.search),
              label: Text(
                _scanning
                    ? 'Scan läuft …'
                    : 'LMC-Geräte suchen',
              ),
            )
          else
            OutlinedButton.icon(
              onPressed: _busy ? null : _disconnect,
              icon: const Icon(Icons.bluetooth_disabled),
              label: const Text('Verbindung trennen'),
            ),

          if (_busy || _scanning || _stationInitializing) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],

          const SizedBox(height: 16),

          if (!connected)
            ..._results.map(
                  (result) => Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.bluetooth,
                    color: orange,
                  ),
                  title: Text(_name(result)),
                  subtitle: Text(
                    '${result.device.remoteId}'
                        ' • ${result.rssi} dBm',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: !_stationReady || _busy
                      ? null
                      : () => _connect(result),
                ),
              ),
            ),

          if (_stationReady &&
              !_scanning &&
              !_busy &&
              !connected &&
              _results.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Nur Geräte mit „LMC“ im Bluetooth-Namen '
                    'werden angezeigt.',
              ),
            ),

          if (connected) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Steuerungsseriennummer'),
                    const SizedBox(height: 8),
                    Text(
                      _serialNumber?.toString() ??
                          'Noch nicht gelesen',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed:
              _ready && !_busy ? _readDeviceDataAgain : null,
              icon: const Icon(Icons.refresh),
              label: const Text('Seriennummer erneut lesen'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _stationReady &&
                  _ready &&
                  !_busy &&
                  _serialNumber != null
                  ? _openParameterCheck
                  : null,
              icon: const Icon(Icons.link),
              label: const Text('Zuordnen und weiter'),
            ),
          ],

          const SizedBox(height: 20),

          const Text(
            'Die Prüfhistorie wird lokal als CSV gespeichert. '
                'Cloud-Synchronisierung ist noch nicht eingerichtet. '
                'Beim Verlassen dieser Seite wird die '
                'Bluetooth-Verbindung getrennt.',
            style: TextStyle(
              color: Color(0xFF6B7581),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}