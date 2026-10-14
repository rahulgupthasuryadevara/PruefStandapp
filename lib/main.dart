import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  runApp(const PruefstandApp());
}

class AppColors {
  static const orange = Color(0xFFF37216);
  static const gray = Color(0xFF6B7581);
  static const text = Color(0xFF333B44);
  static const background = Color(0xFFF5F6F7);
  static const border = Color(0xFFD5D9DE);
}

class PruefstandApp extends StatelessWidget {
  const PruefstandApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ketterer Prüfstand',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.orange,
          primary: AppColors.orange,
          onPrimary: Colors.white,
          secondary: AppColors.gray,
          surface: Colors.white,
          onSurface: AppColors.text,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.gray,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.orange,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.background,
          labelStyle: const TextStyle(color: AppColors.gray),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(
              color: AppColors.orange,
              width: 2,
            ),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.red),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(
              color: Colors.red,
              width: 2,
            ),
          ),
        ),
      ),
      home: const NewTestPage(),
    );
  }
}

class KettererHeader extends StatelessWidget {
  final String title;

  const KettererHeader({
    super.key,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.asset(
            'assets/images/ketterer_icon.jpg',
            width: 34,
            height: 34,
            fit: BoxFit.contain,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class NewTestPage extends StatefulWidget {
  const NewTestPage({super.key});

  @override
  State<NewTestPage> createState() => _NewTestPageState();
}

class _NewTestPageState extends State<NewTestPage> {
  final _formKey = GlobalKey<FormState>();
  final _casingController = TextEditingController();

  bool _openingScanner = false;

  Future<void> _scanCode() async {
    if (_openingScanner) return;

    FocusScope.of(context).unfocus();
    setState(() => _openingScanner = true);

    try {
      final scannedText = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => const QrScannerPage(),
        ),
      );

      if (!mounted || scannedText == null) return;

      setState(() {
        _casingController.text = scannedText;
        _casingController.selection = TextSelection.collapsed(
          offset: scannedText.length,
        );
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Code erfasst. Bitte Gehäusenummer prüfen.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _openingScanner = false);
      }
    }
  }

  void _createTest() {
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TestSessionPage(
          casingNumber: _casingController.text.trim(),
          startedAt: DateTime.now(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _casingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const KettererHeader(title: 'Ketterer Prüfstand'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Image.asset(
                      'assets/images/ketterer_logo.png',
                      height: 110,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 36),
                    const Text(
                      'Neue Prüfung',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Code des Gehäuses scannen oder '
                          'die Gehäusenummer manuell eingeben.',
                      style: TextStyle(
                        fontSize: 15,
                        color: AppColors.gray,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    OutlinedButton.icon(
                      onPressed: _openingScanner ? null : _scanCode,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Code scannen'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.orange,
                        side: const BorderSide(
                          color: AppColors.orange,
                        ),
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _casingController,
                      decoration: const InputDecoration(
                        labelText: 'Gehäusenummer',
                        hintText: 'Zum Beispiel: SES-001010',
                        prefixIcon: Icon(
                          Icons.qr_code,
                          color: AppColors.gray,
                        ),
                      ),
                      textInputAction: TextInputAction.done,
                      autocorrect: false,
                      enableSuggestions: false,
                      onFieldSubmitted: (_) => _createTest(),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Bitte eine Gehäusenummer eingeben.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _createTest,
                      icon: const Icon(Icons.add),
                      label: const Text(
                        'Neue Prüfung anlegen',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Unterstützt QR-Code und Data Matrix.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.gray,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TestSessionPage extends StatelessWidget {
  final String casingNumber;
  final DateTime startedAt;

  const TestSessionPage({
    super.key,
    required this.casingNumber,
    required this.startedAt,
  });

  @override
  Widget build(BuildContext context) {
    final localTime = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(startedAt),
      alwaysUse24HourFormat: true,
    );

    return Scaffold(
      appBar: AppBar(
        title: const KettererHeader(title: 'Prüfung'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Gehäusenummer',
                        style: TextStyle(
                          color: AppColors.gray,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        casingNumber,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: AppColors.text,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Angelegt um: $localTime',
                        style: const TextStyle(color: AppColors.gray),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: const Text(
                          'Status: Noch nicht geprüft',
                          style: TextStyle(
                            color: AppColors.gray,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: const ListTile(
                    contentPadding: EdgeInsets.all(16),
                    leading: Icon(
                      Icons.bluetooth,
                      color: AppColors.orange,
                      size: 30,
                    ),
                    title: Text(
                      'Steuerung verbinden',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      'Die Bluetooth-Verbindung wird '
                          'im nächsten Schritt ergänzt.',
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Entwicklungsversion: Diese Sitzung ist nur '
                      'im Arbeitsspeicher vorhanden. '
                      'Die dauerhafte Speicherung wird später ergänzt.',
                  style: TextStyle(
                    color: AppColors.gray,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final MobileScannerController _scannerController =
  MobileScannerController(
    formats: const [
      BarcodeFormat.qrCode,
      BarcodeFormat.dataMatrix,
    ],
    invertImage: true,
  );

  bool _returningResult = false;

  void _onDetect(BarcodeCapture capture) {
    if (_returningResult || !mounted) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;

      if (value == null || value.trim().isEmpty) continue;

      _returningResult = true;

      // Return the decoded text once, without assuming its format.
      Navigator.of(context).pop(value.trim());
      return;
    }
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const KettererHeader(title: 'Code scannen'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    controller: _scannerController,
                    onDetect: _onDetect,
                    errorBuilder: (context, error) {
                      return Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.no_photography,
                                size: 48,
                                color: AppColors.gray,
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Kamera nicht verfügbar. '
                                    'Bitte die Kameraberechtigung '
                                    'in den Android-App-Einstellungen '
                                    'prüfen.',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              FilledButton(
                                onPressed: () {
                                  Navigator.of(context).pop();
                                },
                                child: const Text('Zurück'),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  // This guide helps positioning.
                  // It does not crop or modify the camera image.
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        width: 180,
                        height: 180,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: AppColors.orange,
                            width: 3,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.add,
                            color: AppColors.orange,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              child: const Column(
                children: [
                  Text(
                    'Den kleinen Code auf das orange Kreuz richten.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Nur den Code zentrieren, nicht das gesamte '
                        'Typenschild. Kamera ruhig halten und '
                        'Reflexionen vermeiden.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.gray,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}