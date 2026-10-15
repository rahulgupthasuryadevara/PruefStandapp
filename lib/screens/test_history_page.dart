import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/test_history.dart';

class TestHistoryPage extends StatefulWidget {
  const TestHistoryPage({super.key});

  @override
  State<TestHistoryPage> createState() =>
      _TestHistoryPageState();
}

class _TestHistoryPageState extends State<TestHistoryPage> {
  File? _summaryFile;

  bool _loading = true;
  bool _exporting = false;

  String? _error;
  DateTime? _modifiedAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final directory = await TestHistory.historyDirectory();

      final file = File(
        '${directory.path}/${TestHistory.summaryFilename}',
      );

      final exists = await file.exists();

      DateTime? modifiedAt;

      if (exists) {
        modifiedAt = await file.lastModified();
      }

      if (!mounted) return;

      setState(() {
        _summaryFile = exists ? file : null;
        _modifiedAt = modifiedAt;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _error = 'Prüfhistorie konnte nicht geladen werden:\n'
            '$error';
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();

    String two(int value) {
      return value.toString().padLeft(2, '0');
    }

    return '${two(local.day)}.'
        '${two(local.month)}.'
        '${local.year} '
        '${two(local.hour)}:'
        '${two(local.minute)}:'
        '${two(local.second)}';
  }

  Future<void> _export(
      BuildContext buttonContext,
      ) async {
    final file = _summaryFile;

    if (file == null || _exporting) return;

    final box =
    buttonContext.findRenderObject() as RenderBox?;

    final shareOrigin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _exporting = true);

    try {
      if (!await file.exists()) {
        throw StateError(
          'Die CSV-Datei wurde nicht gefunden.',
        );
      }

      // Share a snapshot so later tests cannot change
      // the file while another app is receiving it.
      final bytes = await file.readAsBytes();

      await Share.shareXFiles(
        [
          XFile.fromData(
            bytes,
            mimeType: 'text/csv',
          ),
        ],
        fileNameOverrides: [
          TestHistory.summaryFilename,
        ],
        subject: 'Ketterer Prüfstand – Prüfergebnisse',
        sharePositionOrigin: shareOrigin,
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'CSV-Export fehlgeschlagen: $error',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prüfergebnisse'),
        actions: [
          IconButton(
            tooltip: 'Aktualisieren',
            onPressed: _loading || _exporting
                ? null
                : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(
        child: CircularProgressIndicator(),
      )
          : ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(
            Icons.table_chart_outlined,
            size: 64,
            color: Color(0xFFF37216),
          ),
          const SizedBox(height: 20),
          const Text(
            'Gesammelte Prüfergebnisse',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Alle Prüfungen werden in einer CSV-Datei '
                'gespeichert. Jede Prüfung erhält eine Zeile '
                'mit Identifikation, Soll-/Istwerten und '
                'den einzelnen Prüfergebnissen.',
          ),
          const SizedBox(height: 24),

          if (_error != null) ...[
            Text(
              _error!,
              style: const TextStyle(
                color: Colors.red,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Erneut versuchen'),
            ),
          ] else if (_summaryFile == null) ...[
            const Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'Noch keine Ergebnisdatei vorhanden. '
                      'Eine neue Prüfung anlegen, damit '
                      'Pruefungen.csv erstellt wird.',
                ),
              ),
            ),
          ] else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment:
                  CrossAxisAlignment.start,
                  children: [
                    const Text(
                      TestHistory.summaryFilename,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_modifiedAt != null)
                      Text(
                        'Zuletzt aktualisiert:\n'
                            '${_formatDate(_modifiedAt!)}',
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'Enthält:\n'
                          '• Prüfungsnummer und Prüfstation\n'
                          '• Gehäuse- und Steuerungsnummer\n'
                          '• Prüfer und Zeitstempel\n'
                          '• Parameter: Soll, Ist, Ergebnis\n'
                          '• UP- und DOWN-Bewegung\n'
                          '• PWM- und Sichtprüfungen\n'
                          '• Ergebnis des Prüfumfangs\n'
                          '• Status der Installationsvorbereitung',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Builder(
              builder: (buttonContext) {
                return FilledButton.icon(
                  onPressed: _exporting
                      ? null
                      : () => _export(buttonContext),
                  icon: const Icon(Icons.ios_share),
                  label: Text(
                    _exporting
                        ? 'Export wird vorbereitet …'
                        : 'Pruefungen.csv exportieren',
                  ),
                );
              },
            ),
            if (_exporting) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
          ],

          const SizedBox(height: 24),
          const Text(
            'PASS bezieht sich auf den angegebenen '
                'Prüfumfang. Eine ausstehende '
                'Installationsvorbereitung wird separat '
                'ausgewiesen.',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF6B7581),
            ),
          ),
        ],
      ),
    );
  }
}