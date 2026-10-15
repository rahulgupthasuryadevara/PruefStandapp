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
  List<File> _files = [];
  bool _loading = true;
  String? _error;

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

      final files = await directory
          .list()
          .where(
            (entry) =>
        entry is File &&
            entry.path.toLowerCase().endsWith('.csv'),
      )
          .cast<File>()
          .toList();

      files.sort((a, b) => b.path.compareTo(a.path));

      if (!mounted) return;

      setState(() => _files = files);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _filename(File file) => file.uri.pathSegments.last;

  Future<void> _share(
      BuildContext buttonContext,
      File file,
      ) async {
    try {
      final box =
      buttonContext.findRenderObject() as RenderBox?;

      await Share.shareXFiles(
        [
          XFile(file.path, mimeType: 'text/csv'),
        ],
        subject: _filename(file),
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export fehlgeschlagen: $error'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prüfhistorie'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Aktualisieren',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Historie konnte nicht geladen werden:\n'
                '$_error',
          ),
        ),
      )
          : _files.isEmpty
          ? const Center(
        child: Text(
          'Noch keine Prüfberichte vorhanden.',
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _files.length,
        itemBuilder: (context, index) {
          final file = _files[index];

          return Card(
            child: ListTile(
              leading: const Icon(
                Icons.description_outlined,
              ),
              title: Text(_filename(file)),
              subtitle: const Text(
                'CSV-Prüfhistorie',
              ),
              trailing: Builder(
                builder: (buttonContext) {
                  return IconButton(
                    tooltip: 'CSV exportieren',
                    icon: const Icon(
                      Icons.ios_share,
                    ),
                    onPressed: () {
                      _share(buttonContext, file);
                    },
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}