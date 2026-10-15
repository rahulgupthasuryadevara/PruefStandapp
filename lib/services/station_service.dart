import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class StationAllocation {
  final int stationNumber;
  final String testNumber;

  const StationAllocation({
    required this.stationNumber,
    required this.testNumber,
  });
}

class StationService {
  static const _storageKey = 'pruefstand_station_numbering_v1';

  static final _preferences = SharedPreferencesAsync();

  static Future<void> _tail = Future<void>.value();

  static Future<T> _locked<T>(Future<T> Function() action) {
    final result = Completer<T>();

    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });

    return result.future;
  }

  static Future<Map<String, dynamic>?> _readState() async {
    final saved = await _preferences.getString(_storageKey);

    if (saved == null) return null;

    final decoded = jsonDecode(saved);

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Ungültige Prüfstationseinstellungen.',
      );
    }

    final station = decoded['station_number'];
    final counters = decoded['year_counters'];

    if (station is! int || station < 1 || station > 99) {
      throw const FormatException(
        'Ungültige Prüfstationsnummer.',
      );
    }

    if (counters is! Map<String, dynamic>) {
      throw const FormatException(
        'Ungültiger Prüfungszähler.',
      );
    }

    for (final entry in counters.entries) {
      final value = entry.value;

      if (!RegExp(r'^\d{4}$').hasMatch(entry.key) ||
          value is! int ||
          value < 0 ||
          value > 999999) {
        throw const FormatException(
          'Gespeicherter Prüfungszähler ist ungültig.',
        );
      }
    }

    return decoded;
  }

  static Future<int?> getStationNumber() async {
    final state = await _readState();
    return state?['station_number'] as int?;
  }

  static Future<void> configure(int stationNumber) {
    return _locked<void>(() async {
      if (stationNumber < 1 || stationNumber > 99) {
        throw ArgumentError(
          'Prüfstationsnummer muss zwischen 1 und 99 liegen.',
        );
      }

      final existing = await _readState();

      if (existing != null) {
        if (existing['station_number'] != stationNumber) {
          throw StateError(
            'Diese App ist bereits einer anderen '
                'Prüfstation zugeordnet.',
          );
        }

        return;
      }

      await _preferences.setString(
        _storageKey,
        jsonEncode({
          'station_number': stationNumber,
          'year_counters': <String, int>{},
        }),
      );
    });
  }

  static Future<StationAllocation> allocateNumber() {
    return _locked<StationAllocation>(() async {
      final state = await _readState();

      if (state == null) {
        throw StateError(
          'Bitte zuerst die Prüfstation einrichten.',
        );
      }

      final station = state['station_number'] as int;

      final counters = Map<String, dynamic>.from(
        state['year_counters'] as Map,
      );

      final year = DateTime.now().year;
      final yearKey = year.toString();

      final previous = (counters[yearKey] as int?) ?? 0;
      final next = previous + 1;

      if (next > 999999) {
        throw StateError(
          'Maximale Anzahl Prüfungen für dieses Jahr erreicht.',
        );
      }

      counters[yearKey] = next;

      await _preferences.setString(
        _storageKey,
        jsonEncode({
          'station_number': station,
          'year_counters': counters,
        }),
      );

      final yearText = year.toString().substring(2);
      final stationText = station.toString().padLeft(2, '0');
      final counterText = next.toString().padLeft(6, '0');

      return StationAllocation(
        stationNumber: station,
        testNumber: 'PR-$yearText-$stationText-$counterText',
      );
    });
  }
}