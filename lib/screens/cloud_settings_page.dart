import 'package:flutter/material.dart';

import '../services/nextcloud_service.dart';

class CloudSettingsPage extends StatefulWidget {
  const CloudSettingsPage({super.key});

  @override
  State<CloudSettingsPage> createState() =>
      _CloudSettingsPageState();
}

class _CloudSettingsPageState extends State<CloudSettingsPage> {
  final _passwordController = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  bool _configured = false;
  bool _hidePassword = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final configured = await NextcloudService.isConfigured();

      if (!mounted) return;

      setState(() {
        _configured = configured;
      });
    } catch (error) {
      if (!mounted) return;
      _showMessage('Zugang konnte nicht geladen werden: $error');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _perform(
      Future<void> Function() action,
      String successMessage,
      ) async {
    if (_busy) return;

    setState(() {
      _busy = true;
    });

    try {
      await action();

      if (!mounted) return;
      _showMessage(successMessage);
    } catch (error) {
      if (!mounted) return;
      _showMessage(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _savePassword() async {
    await _perform(
          () async {
        await NextcloudService.savePassword(
          _passwordController.text,
        );

        _passwordController.clear();

        if (mounted) {
          setState(() {
            _configured = true;
          });
        }
      },
      'App-Passwort sicher gespeichert.',
    );
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Nextcloud-Einstellungen'),
        ),
        body: _loading
            ? const Center(
          child: CircularProgressIndicator(),
        )
            : ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(
              Icons.cloud_outlined,
              size: 64,
            ),
            const SizedBox(height: 20),
            const Text(
              'Prüfergebnisse in Nextcloud',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Die lokale CSV bleibt auf dem Gerät. '
                  'Synchronisieren lädt die aktuelle CSV '
                  'in den Ordner Station-01 hoch.',
            ),
            const SizedBox(height: 20),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                  CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Server',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SelectableText(
                      'https://share.ketterer.de',
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Benutzer',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(NextcloudService.username),
                    SizedBox(height: 12),
                    Text(
                      'Ziel',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text('Station-01 / Pruefungen.csv'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _configured
                  ? 'App-Passwort ist gespeichert.'
                  : 'Noch kein App-Passwort gespeichert.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              enabled: !_busy,
              obscureText: _hidePassword,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: _configured
                    ? 'Neues App-Passwort'
                    : 'Nextcloud-App-Passwort',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() {
                      _hidePassword = !_hidePassword;
                    });
                  },
                  icon: Icon(
                    _hidePassword
                        ? Icons.visibility
                        : Icons.visibility_off,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _savePassword,
              icon: const Icon(Icons.save),
              label: const Text('App-Passwort speichern'),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _busy || !_configured
                  ? null
                  : () => _perform(
                NextcloudService.testConnection,
                'Nextcloud-Ordner erreichbar.',
              ),
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Verbindung testen'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy || !_configured
                  ? null
                  : () => _perform(
                NextcloudService.uploadSummary,
                'Synchronisierung abgeschlossen.',
              ),
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Jetzt synchronisieren'),
            ),
            if (_busy) ...[
              const SizedBox(height: 20),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 20),
            ValueListenableBuilder<String>(
              valueListenable: NextcloudService.status,
              builder: (context, message, child) {
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(message),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            const Text(
              'Dieser Ordner ist für Station-01 vorgesehen. '
                  'Andere Prüfstationen benötigen eigene Ordner. '
                  'Bei fehlendem Netzwerk bleiben die Daten lokal; '
                  'die Synchronisierung kann später erneut '
                  'gestartet werden.',
            ),
          ],
        ),
      ),
    );
  }
}