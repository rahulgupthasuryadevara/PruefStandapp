import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'test_history.dart';

class NextcloudService {
  static const username = 'Suryadevara_R';

  static const folderUrl =
      'https://share.ketterer.de/remote.php/dav/files/'
      'Suryadevara_R/Station-01/';

  static const _passwordKey = 'nextcloud_app_password_v1';

  // ETag remembers the cloud version last uploaded by this app.
  static const _etagKey = 'nextcloud_station01_etag_v1';

  static const _storage = FlutterSecureStorage();

  static final ValueNotifier<String> status =
  ValueNotifier<String>('Cloud noch nicht synchronisiert.');

  static bool _uploading = false;

  static Uri get _folderUri => Uri.parse(folderUrl);

  static Uri get _fileUri =>
      _folderUri.resolve(TestHistory.summaryFilename);

  static Future<bool> isConfigured() async {
    final password = await _storage.read(key: _passwordKey);
    return password != null && password.isNotEmpty;
  }

  static Future<void> savePassword(String password) async {
    if (password.trim().isEmpty) {
      throw StateError('Bitte das App-Passwort eingeben.');
    }

    await _storage.write(
      key: _passwordKey,
      value: password.trim(),
    );

    status.value = 'Zugang gespeichert. Verbindung bitte testen.';
  }

  static Future<Map<String, String>> _headers() async {
    final password = await _storage.read(key: _passwordKey);

    if (password == null || password.isEmpty) {
      throw StateError(
        'Bitte zuerst das Nextcloud-App-Passwort speichern.',
      );
    }

    final credentials = base64Encode(
      utf8.encode('$username:$password'),
    );

    return {
      'Authorization': 'Basic $credentials',
    };
  }

  static String _httpError(int code) {
    switch (code) {
      case 401:
        return 'Anmeldung fehlgeschlagen. '
            'Benutzername und App-Passwort prüfen.';
      case 403:
        return 'Keine Berechtigung für diesen Nextcloud-Ordner.';
      case 404:
        return 'Nextcloud-Ordner oder Datei nicht gefunden.';
      case 409:
        return 'Zielordner fehlt oder der Pfad ist ungültig.';
      case 412:
        return 'Die Cloud-Datei wurde zwischenzeitlich geändert. '
            'Upload gestoppt, damit keine Daten überschrieben werden.';
      case 423:
        return 'Die Cloud-Datei ist momentan gesperrt. Später versuchen.';
      case 507:
        return 'Nextcloud-Speicherplatz ist voll.';
      default:
        return 'Nextcloud-Anfrage fehlgeschlagen: HTTP $code.';
    }
  }

  static Future<http.Response> _send(
      http.Client client,
      String method,
      Uri uri, {
        Map<String, String>? extraHeaders,
        List<int>? bytes,
        String? text,
      }) async {
    final request = http.Request(method, uri)
      ..followRedirects = false;

    request.headers.addAll(await _headers());

    if (extraHeaders != null) {
      request.headers.addAll(extraHeaders);
    }

    if (bytes != null) {
      request.bodyBytes = bytes;
    } else if (text != null) {
      request.body = text;
    }

    // Timeout covers both sending and receiving the response body.
    return (() async {
      final streamed = await client.send(request);
      return http.Response.fromStream(streamed);
    })().timeout(const Duration(seconds: 30));
  }

  static Future<void> testConnection() async {
    final client = http.Client();

    status.value = 'Nextcloud-Verbindung wird geprüft …';

    try {
      final response = await _send(
        client,
        'PROPFIND',
        _folderUri,
        extraHeaders: {
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8',
        },
        text: '''
<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
  </d:prop>
</d:propfind>
''',
      );

      if (response.statusCode != 207) {
        throw StateError(_httpError(response.statusCode));
      }

      status.value =
      'Verbindung erfolgreich. Ordner Station-01 erreichbar.';
    } catch (error) {
      status.value = 'Verbindung fehlgeschlagen: $error';
      rethrow;
    } finally {
      client.close();
    }
  }

  static bool _sameBytes(List<int> first, List<int> second) {
    if (first.length != second.length) return false;

    for (var i = 0; i < first.length; i++) {
      if (first[i] != second[i]) return false;
    }

    return true;
  }

  static Future<void> uploadSummary() async {
    if (_uploading) {
      throw StateError('Ein Cloud-Upload läuft bereits.');
    }

    _uploading = true;
    final client = http.Client();

    try {
      if (!await isConfigured()) {
        throw StateError('Nextcloud-Zugang noch nicht eingerichtet.');
      }

      final directory = await TestHistory.historyDirectory();

      final localFile = File(
        '${directory.path}/${TestHistory.summaryFilename}',
      );

      if (!await localFile.exists()) {
        throw StateError(
          'Noch keine lokale Pruefungen.csv vorhanden.',
        );
      }

      // Upload a stable snapshot, not a file that is changing.
      final snapshot = await localFile.readAsBytes();

      status.value = 'Cloud-Datei wird geprüft …';

      final remote = await _send(
        client,
        'HEAD',
        _fileUri,
      );

      String? previousEtag;

      if (remote.statusCode == 200) {
        final remoteEtag = remote.headers['etag'];
        final rememberedEtag = await _storage.read(key: _etagKey);

        if (remoteEtag != null &&
            !remoteEtag.startsWith('W/') &&
            rememberedEtag == remoteEtag) {
          previousEtag = remoteEtag;
        } else {
          // First connection or external modification:
          // adopt only if cloud and local data are identical.
          final existing = await _send(
            client,
            'GET',
            _fileUri,
          );

          if (existing.statusCode != 200) {
            throw StateError(_httpError(existing.statusCode));
          }

          if (!_sameBytes(snapshot, existing.bodyBytes)) {
            throw StateError(
              'Im Cloud-Ordner liegt bereits eine andere '
                  'Pruefungen.csv. Sie wird nicht überschrieben. '
                  'Datei zuerst mit dem Verantwortlichen vergleichen.',
            );
          }

          final matchingEtag = existing.headers['etag'];

          if (matchingEtag == null ||
              matchingEtag.startsWith('W/')) {
            throw StateError(
              'Keine verwendbare Cloud-Versionskennung erhalten.',
            );
          }

          await _storage.write(
            key: _etagKey,
            value: matchingEtag,
          );

          await _reportSnapshotStatus(localFile, snapshot);
          return;
        }
      } else if (remote.statusCode != 404) {
        throw StateError(_httpError(remote.statusCode));
      }

      status.value = 'Pruefungen.csv wird hochgeladen …';

      final response = await _send(
        client,
        'PUT',
        _fileUri,
        extraHeaders: {
          'Content-Type': 'text/csv; charset=utf-8',

          // Create only if absent, or replace the known version only.
          if (previousEtag == null)
            'If-None-Match': '*'
          else
            'If-Match': previousEtag,
        },
        bytes: snapshot,
      );

      if (response.statusCode != 200 &&
          response.statusCode != 201 &&
          response.statusCode != 204) {
        throw StateError(_httpError(response.statusCode));
      }

      // Store the version identifier returned by this PUT.
      // Avoid fetching a later HEAD that could belong to another writer.
      final newEtag = response.headers['etag'];

      if (newEtag != null && !newEtag.startsWith('W/')) {
        await _storage.write(
          key: _etagKey,
          value: newEtag,
        );
      } else {
        await _storage.delete(key: _etagKey);
      }

      await _reportSnapshotStatus(localFile, snapshot);
    } catch (error) {
      status.value =
      'Cloud nicht synchronisiert. Lokal gespeichert. $error';

      rethrow;
    } finally {
      client.close();
      _uploading = false;
    }
  }

  static Future<void> _reportSnapshotStatus(
      File localFile,
      List<int> snapshot,
      ) async {
    final current = await localFile.readAsBytes();

    if (_sameBytes(snapshot, current)) {
      final now = DateTime.now();
      final hours = now.hour.toString().padLeft(2, '0');
      final minutes = now.minute.toString().padLeft(2, '0');

      status.value = 'Cloud synchronisiert um $hours:$minutes.';
    } else {
      status.value =
      'Snapshot hochgeladen. Neuere lokale Daten vorhanden: '
          'bitte erneut synchronisieren.';
    }
  }

  // Call after a completed test. A cloud error must not
  // turn a successful drive test into FAIL.
  static Future<void> syncAfterTest() async {
    try {
      if (!await isConfigured()) {
        status.value =
        'Lokal gespeichert. Nextcloud noch nicht eingerichtet.';
        return;
      }

      await uploadSummary();
    } catch (error) {
      status.value =
      'Upload ausstehend. Lokal gespeichert. $error';
    }
  }
}