import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../logic/barcode.dart';
import 'common.dart';

/// Live barcode scanner: point the camera at a product barcode; returns its
/// number (13 digits for EAN/UPC), or null.
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});
  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  final _c = MobileScannerController(
    formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA, BarcodeFormat.upcE],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _found(BarcodeCapture cap) {
    if (_done) return;
    for (final b in cap.barcodes) {
      final v = b.rawValue;
      if (v != null && RegExp(r'^\d{8,14}$').hasMatch(v)) {
        _done = true;
        Navigator.pop(context, normalizeBarcode(v));
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan a barcode'),
        actions: [
          IconButton(icon: const Icon(Icons.flashlight_on_outlined), tooltip: 'Light', onPressed: () => _c.toggleTorch()),
        ],
      ),
      body: Stack(children: [
        MobileScanner(
          controller: _c,
          onDetect: _found,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'The camera cannot start (${error.errorCode.name}). Allow the camera for Monitor Glucose in the phone settings, '
                'or go back and take a photo or type the numbers.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: kText),
              ),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 290,
            height: 160,
            decoration: BoxDecoration(border: Border.all(color: kAccent, width: 3), borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 40,
          child: Text('Put the barcode in the frame', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 17)),
        ),
      ]),
    );
  }
}
