import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../helper/db_helper.dart';
import '../product/product_image.dart';
import 'animated_scanner_overlay.dart';

class PriceScannerScreen extends StatefulWidget {
  const PriceScannerScreen({super.key});

  @override
  State<PriceScannerScreen> createState() => _PriceScannerScreenState();
}

class _PriceScannerScreenState extends State<PriceScannerScreen>
    with WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    torchEnabled: false,
  );

  bool _isScanning = true;
  bool _isTorchOn = false;
  bool _isCameraReady = false;
  String _lastScanned = '';
  Map<String, dynamic>? _scannedProduct;
  bool _isNotFound = false;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _nameController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.isInitialized) return;

    switch (state) {
      case AppLifecycleState.resumed:
        if (_isScanning) {
          _startCamera();
        }
        break;
      case AppLifecycleState.paused:
        _controller.stop();
        break;
      default:
        break;
    }
  }

  Future<void> _startCamera() async {
    try {
      await _controller.start();
      if (mounted) {
        setState(() => _isCameraReady = true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isCameraReady = false);
      }
    }
  }

  void _resetToScan() {
    _nameController.clear();
    _priceController.clear();
    if (!mounted) return;
    setState(() {
      _scannedProduct = null;
      _isNotFound = false;
      _isScanning = true;
    });
    _startCamera();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!_isScanning) return;

    final barcodes = capture.barcodes;
    if (barcodes.isEmpty || barcodes.first.rawValue == null) return;

    final barcode = barcodes.first.rawValue!;
    await HapticFeedback.lightImpact();

    if (!mounted) return;
    setState(() {
      _lastScanned = barcode;
      _isScanning = false;
    });

    await _controller.stop();

    final product = await DBHelper.getProduct(barcode);
    if (!mounted) return;

    setState(() {
      if (product != null) {
        _scannedProduct = product;
        _isNotFound = false;
      } else {
        _scannedProduct = null;
        _isNotFound = true;
      }
    });
  }

  Future<void> _saveNewProduct() async {
    final name = _nameController.text.trim();
    final price = double.tryParse(_priceController.text.trim());

    if (name.isEmpty || price == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('กรุณากรอกชื่อและราคาให้ถูกต้อง'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    await DBHelper.insertOrUpdateProduct(_lastScanned, name, price);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('บันทึกข้อมูลเรียบร้อย'),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );

    _resetToScan();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('สแกนเช็คราคา'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(
              _isTorchOn ? Icons.flash_on : Icons.flash_off,
              color: _isTorchOn ? Colors.yellow : Colors.white,
            ),
            tooltip: 'ไฟฉาย',
            onPressed: () async {
              await _controller.toggleTorch();
              if (mounted) setState(() => _isTorchOn = !_isTorchOn);
            },
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios),
            tooltip: 'สลับกล้อง',
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          if (_isScanning) ...[
            CustomPaint(
              size: MediaQuery.of(context).size,
              painter: _ScannerMaskPainter(frameWidth: 280, frameHeight: 180),
            ),
            Center(
              child: AnimatedScannerOverlay(
                width: 280,
                height: 180,
                borderColor: Colors.white.withValues(alpha: 0.9),
                laserColor: Colors.redAccent,
              ),
            ),
          ],
          if (!_isCameraReady && _isScanning)
            Container(
              color: Colors.black87,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
          // การ์ดแสดงผล/กรอกข้อมูลอยู่ตรงกลางจอ พิมพ์ง่าย ไม่บังคีย์บอร์ด
          if (!_isScanning)
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  elevation: 8,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_scannedProduct != null) ...[
                          Icon(
                            Icons.check_circle,
                            size: 48,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _scannedProduct!['name']?.toString() ?? 'ไม่มีชื่อ',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          if (_scannedProduct!['image_file'] != null &&
                              _scannedProduct!['image_file']
                                  .toString()
                                  .isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: ProductImage(
                                imageFile: _scannedProduct!['image_file']
                                    .toString(),
                                width: 120,
                                height: 120,
                              ),
                            ),
                          const SizedBox(height: 12),
                          const Text(
                            "ราคาขาย",
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "฿${_scannedProduct!['price'] ?? 0}",
                            style: const TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: _resetToScan,
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text("สแกนต่อ"),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(double.infinity, 48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ] else if (_isNotFound) ...[
                          const Icon(
                            Icons.help_outline,
                            size: 48,
                            color: Colors.orange,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            "ไม่พบสินค้า",
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              "บาร์โค้ด: $_lastScanned",
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(
                              labelText: "ชื่อสินค้า",
                              prefixIcon: Icon(Icons.label_outline),
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            textCapitalization: TextCapitalization.sentences,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _priceController,
                            decoration: const InputDecoration(
                              labelText: "ราคาขาย (บาท)",
                              prefixIcon: Icon(Icons.attach_money),
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _resetToScan,
                                  icon: const Icon(Icons.close),
                                  label: const Text("ยกเลิก"),
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size(0, 48),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _saveNewProduct,
                                  icon: const Icon(Icons.save),
                                  label: const Text("บันทึก"),
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size(0, 48),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScannerMaskPainter extends CustomPainter {
  final double frameWidth;
  final double frameHeight;

  _ScannerMaskPainter({required this.frameWidth, required this.frameHeight});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;

    final frameRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: frameWidth,
      height: frameHeight,
    );

    final backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final framePath = Path()
      ..addRRect(RRect.fromRectAndRadius(frameRect, const Radius.circular(12)));

    final maskPath = Path.combine(
      PathOperation.difference,
      backgroundPath,
      framePath,
    );

    canvas.drawPath(maskPath, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
