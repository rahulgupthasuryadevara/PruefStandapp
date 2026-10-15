import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

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

  Timer? _statusPollTimer;

  bool _scanning = false;
  bool _busy = false;
  bool _ready = false;
  bool _writeBusy = false;
  bool _readErrorNext = true;
  bool _disposed = false;

  int _session = 0;

  String _status = 'Steuerung einschalten und Scan starten.';
  String _receiveBuffer = '';
  String _deviceName = '';

  int? _serialLow;
  int? _serialMid;
  int? _firmware;
  int? _errorCode;
  int? _referenceState;

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
      },
    );

    _scanStateSubscription = FlutterBluePlus.isScanning.listen(
          (scanning) {
        if (!mounted || _disposed) return;

        setState(() => _scanning = scanning);
      },
    );
  }

  // Logs remain in Android Studio, but are not displayed in the app.
  void _log(String message) {
    debugPrint('BLE: $message');
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
    if (_busy || _scanning || _device != null) return;

    setState(() {
      _busy = true;
      _results = [];
      _status = 'Berechtigungen werden geprüft …';
    });

    try {
      if (!await _requestPermissions()) {
        _setStatus(
          'Berechtigung fehlt. Bitte in den App-Einstellungen erlauben.',
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
      _setStatus('Scan fehlgeschlagen: $error');
      _log('Scanfehler: $error');
    } finally {
      if (mounted && !_disposed) {
        setState(() => _busy = false);
      }
    }
  }

  String _name(ScanResult result) {
    final advertisedName = result.advertisementData.advName;

    if (advertisedName.isNotEmpty) {
      return advertisedName;
    }

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

      final match = RegExp(
        r'^#R(\d+)=(-?\d+)$',
      ).firstMatch(line);

      if (match == null) continue;

      final register = int.parse(match.group(1)!);
      final value = int.parse(match.group(2)!);

      if (!mounted || _disposed) return;

      setState(() {
        _lastResponseAt = DateTime.now();

        switch (register) {
          case 102:
            _firmware = value;
            break;

          case 104:
            _serialLow = value;
            break;

          case 105:
            _serialMid = value;
            break;

          case 12002:
            _errorCode = value;
            break;

          case 12010:
            _referenceState = value;
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

      await characteristic.write(
        command.codeUnits,
        withoutResponse:
        characteristic.properties.writeWithoutResponse,
      ).timeout(const Duration(seconds: 2));

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

          final lastResponse = _lastResponseAt;

          if (lastResponse == null ||
              DateTime.now().difference(lastResponse) >
                  const Duration(seconds: 10)) {
            _setStatus(
              'Bluetooth verbunden, aber keine aktuellen '
                  'Registerantworten.',
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

    _log('Statusabfrage gestartet: alle 1 Sekunde');
  }

  Future<void> _clearListeners() async {
    _statusPollTimer?.cancel();
    _statusPollTimer = null;

    final connectionSubscription = _connectionSubscription;
    final notifySubscription = _notifySubscription;

    _connectionSubscription = null;
    _notifySubscription = null;

    await connectionSubscription?.cancel();
    await notifySubscription?.cancel();

    _writeCharacteristic = null;
    _receiveBuffer = '';
  }

  Future<void> _connect(ScanResult result) async {
    if (_busy || _device != null) return;

    final device = result.device;
    final session = ++_session;

    setState(() {
      _busy = true;
      _ready = false;
      _serialLow = null;
      _serialMid = null;
      _firmware = null;
      _errorCode = null;
      _referenceState = null;
      _lastResponseAt = null;
      _deviceName = _name(result);
      _status = 'Verbindung zu $_deviceName …';
    });

    try {
      await _clearListeners();

      _log('Scan wird gestoppt');
      await FlutterBluePlus.stopScan();

      await Future.delayed(
        const Duration(milliseconds: 500),
      );

      if (!mounted || _disposed || session != _session) {
        return;
      }

      _device = device;

      _log('Verbindung ohne explizite MTU-Anfrage');

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
      _log('Discovering services');

      final services = await device
          .discoverServices()
          .timeout(const Duration(seconds: 8));

      _checkConnection(device, session);

      BluetoothCharacteristic? writeCharacteristic;
      BluetoothCharacteristic? notifyCharacteristic;

      for (final service in services) {
        if (service.uuid != uartService) continue;

        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == uartWrite) {
            writeCharacteristic = characteristic;
          }

          if (characteristic.uuid == uartNotify) {
            notifyCharacteristic = characteristic;
          }
        }
      }

      if (writeCharacteristic == null ||
          !(writeCharacteristic.properties.write ||
              writeCharacteristic.properties.writeWithoutResponse)) {
        throw StateError('UART-Schreibkanal nicht gefunden.');
      }

      if (notifyCharacteristic == null ||
          !(notifyCharacteristic.properties.notify ||
              notifyCharacteristic.properties.indicate)) {
        throw StateError('UART-Antwortkanal nicht gefunden.');
      }

      _writeCharacteristic = writeCharacteristic;

      _notifySubscription =
          notifyCharacteristic.onValueReceived.listen(
                (bytes) {
              _handleReceivedBytes(bytes, device, session);
            },
            onError: (Object error) {
              if (!_isCurrentSession(device, session)) return;

              _log('Empfangsfehler: $error');
              _setStatus('Fehler beim Empfang: $error');
            },
          );

      _setStatus('Antwortkanal wird aktiviert …');
      _log('Enabling notifications');

      await notifyCharacteristic
          .setNotifyValue(true)
          .timeout(const Duration(seconds: 5));

      await Future.delayed(
        const Duration(milliseconds: 500),
      );

      _checkConnection(device, session);

      _log('Transport ready');

      // Error status, serial number and firmware.
      // These commands do not change the controller configuration.
      for (final register in [12002, 104, 105, 102]) {
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

      _startStatusPolling(device, session);
    } catch (error) {
      _log('Setup fehlgeschlagen: $error');

      await _clearListeners();

      try {
        await device.disconnect();
      } catch (cleanupError) {
        _log('Fehler beim Aufräumen: $cleanupError');
      }

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
      await _clearListeners();
      await device.disconnect();

      if (mounted && !_disposed) {
        setState(() {
          _device = null;
          _status = 'Verbindung getrennt.';
        });
      }
    } catch (error) {
      if (mounted && !_disposed) {
        setState(() {
          if (!device.isConnected) {
            _device = null;
          }

          _status = 'Trennen fehlgeschlagen: $error';
        });
      }
    } finally {
      if (mounted && !_disposed) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _readDeviceDataAgain() async {
    final device = _device;

    if (device == null || _busy || !_ready) return;

    final session = _session;

    setState(() => _busy = true);
    _statusPollTimer?.cancel();

    try {
      final deadline =
      DateTime.now().add(const Duration(seconds: 3));

      while (_writeBusy) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
            'Vorherige Schreiboperation nicht abgeschlossen.',
          );
        }

        await Future.delayed(
          const Duration(milliseconds: 50),
        );

        _checkConnection(device, session);
      }

      _checkConnection(device, session);

      setState(() {
        _serialLow = null;
        _serialMid = null;
        _firmware = null;
      });

      for (final register in [104, 105, 102]) {
        await _sendRead(register, device, session);

        await Future.delayed(
          const Duration(milliseconds: 160),
        );
      }
    } catch (error) {
      _setStatus('Gerätedaten-Abfrage fehlgeschlagen: $error');
      _log('Gerätedaten-Abfrage: $error');
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

  Widget _valueRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = _device != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('LMC-Steuerung verbinden'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Gehäuse: ${widget.casingNumber}',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
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
              onPressed: _busy || _scanning ? null : _scan,
              icon: const Icon(Icons.search),
              label: Text(
                _scanning ? 'Scan läuft …' : 'LMC-Geräte suchen',
              ),
            )
          else
            OutlinedButton.icon(
              onPressed: _busy ? null : _disconnect,
              icon: const Icon(Icons.bluetooth_disabled),
              label: const Text('Verbindung trennen'),
            ),
          if (_busy || _scanning) ...[
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
                  onTap: _busy ? null : () => _connect(result),
                ),
              ),
            ),
          if (!_scanning &&
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
                  children: [
                    _valueRow(
                      'Steuerungsseriennummer',
                      _serialNumber?.toString() ??
                          'Noch nicht gelesen',
                    ),
                    const Divider(),
                    _valueRow(
                      'Firmwareversion (Register 102)',
                      _firmware?.toString() ??
                          'Noch nicht gelesen',
                    ),
                    const Divider(),
                    _valueRow(
                      'Fehlerstatus (12002)',
                      _errorCode?.toString() ?? '—',
                    ),
                    _valueRow(
                      'Referenzstatus (12010, Rohwert)',
                      _referenceState?.toString() ?? '—',
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
              label: const Text('Gerätedaten erneut lesen'),
            ),
          ],
          const SizedBox(height: 20),
          const Text(
            'Entwicklungsversion: Die Werte werden noch nicht '
                'dauerhaft gespeichert. Beim Verlassen dieser Seite '
                'wird die Bluetooth-Verbindung getrennt.',
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