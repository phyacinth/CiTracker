import '../widgets/pop_button_effects.dart';

import 'package:flutter/material.dart';

import '../services/attendance_location_service.dart';
import '../services/qr_attendance_service.dart';
import '../services/nfc_attendance_service.dart';
import '../services/offline_attendance_service.dart';

import 'package:mobile_scanner/mobile_scanner.dart';
import '../theme/app_theme.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen>
    with WidgetsBindingObserver {
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  final _service = QrAttendanceService();
  final _location = AttendanceLocationService();
  bool _scanning = false;
  bool _submitting = false;
  String? _scannedValue;
  String? _error;
  Map<String, dynamic>? _receipt;
  bool _savedOffline = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _location.prepare();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _scanning && mounted) {
      setState(() => _scanning = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _toggleScanning() {
    if (_submitting) return;
    setState(() {
      _scanning = !_scanning;

      if (_scanning) {
        _scannedValue = null;
        _error = null;
        _receipt = null;
        _savedOffline = false;
      }
    });
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!mounted || !_scanning || _submitting) return;

    String? value;

    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;

      if (barcode.format == BarcodeFormat.qrCode &&
          rawValue != null &&
          rawValue.trim().isNotEmpty) {
        value = rawValue;
        break;
      }
    }

    if (value == null) return;

    setState(() {
      _scanning = false;
      _scannedValue = value;
      _submitting = true;
      _error = null;
      _receipt = null;
      _savedOffline = false;
    });

    try {
      final qr = _service.parse(value);
      // No network at all: save it on the phone instead of trying.
      if (await OfflineAttendanceService.isOffline()) {
        await _saveOffline(qr);
        return;
      }
      // Parse first so an invalid QR never waits on GPS.
      final location = await _location.current();
      try {
        final result = await _service.submit(qr, location: location);
        if (mounted) setState(() => _receipt = result);
      } on QrAttendanceException catch (error) {
        // No answer from the server (connected but no internet): save it.
        // If it did reach the server, the upload just reports it as
        // already recorded.
        if (error.code.isNotEmpty) rethrow;
        await _saveOffline(qr, location: location);
      }
    } on QrAttendanceException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on OfflineAttendanceException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
              () => _error = 'Attendance could not be confirmed. Check your history before retrying.',
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Offline fallback: signed with the registered phone key and sent
  /// automatically once the phone is back online.
  Future<void> _saveOffline(
    Map<String, dynamic> qr, {
    AttendanceLocation? location,
  }) async {
    // GPS is slower without internet; nothing is waiting, so allow longer.
    location ??= await _location.current(
      timeLimit: const Duration(seconds: 30),
      lookupName: false,
    );
    await OfflineAttendanceService.instance.saveQr(
      classId: qr['classId'] as String,
      sessionId: qr['sessionId'] as String,
      token: qr['token'] as String,
      location: location,
    );
    if (mounted) setState(() => _savedOffline = true);
  }

  Widget _buildCameraError(BuildContext context, MobileScannerException error) {
    return ColoredBox(
      color: cardColor,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined, color: accentColor, size: 40),
              const SizedBox(height: 14),
              Text(
                'Camera unavailable',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.text,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Allow camera access in your device settings, '
                    'and make sure another app is not using the camera. '
                    'Then stop scanning and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: secondaryTextColor, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_scanning)
              MobileScanner(
                fit: BoxFit.cover,
                useAppLifecycleState: true,
                onDetect: _onDetect,
                errorBuilder: _buildCameraError,
              )
            else
              ColoredBox(
                color: backgroundColor,
                child: Center(
                  child: Icon(
                    _scannedValue == null
                        ? Icons.qr_code_scanner_rounded
                        : Icons.qr_code_rounded,
                    color: accentColor,
                    size: 64,
                  ),
                ),
              ),
            IgnorePointer(
              child: CustomPaint(
                painter: _ScannerCornersPainter(color: accentColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetectedResult() {
    if (_scannedValue == null) return const SizedBox.shrink();
    final receipt = _receipt;
    final attendance = receipt?['attendance'];
    final recorded = attendance is Map;
    final alreadyRecorded = receipt?['already_recorded'] == true;
    String title;
    if (_submitting) {
      title = 'Verifying attendance…';
    } else if (_savedOffline) {
      title = 'Saved offline';
    } else if (recorded) {
      title = alreadyRecorded
          ? 'Attendance already recorded'
          : 'Attendance recorded';
    } else {
      title = 'Attendance not confirmed';
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_submitting)
              Center(child: CircularProgressIndicator(color: accentColor))
            else
              Icon(
                _savedOffline
                    ? Icons.cloud_upload_outlined
                    : recorded
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
                color: accentColor,
                size: 32,
              ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.text,
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 10),
            if (_submitting)
              const Text(
                'Checking the QR, enrollment, and grace period…',
                textAlign: TextAlign.center,
              )
            else if (_error != null)
              Text(_error!, textAlign: TextAlign.center)
            else if (_savedOffline)
              const Text(
                'No internet. Your check-in is saved on this phone and will be '
                'sent automatically when you are back online. It counts once '
                'the server accepts it, the same day.',
                textAlign: TextAlign.center,
              )
            else if (recorded) ...[
                Text(
                  '${receipt?['subject']} • ${receipt?['section']}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  (attendance['status'] ?? '').toString().toUpperCase(),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.history),
                  label: const Text('Attendance History'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => _QrAttendanceHistoryScreen(
                        classId: receipt!['class_id'] as String,
                      ),
                    ),
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        foregroundColor: AppColors.text,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Scan Attendance QR',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight > 40
                      ? constraints.maxHeight - 40
                      : 0,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: cardColor,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: borderColor),
                          ),
                          child: Column(
                            children: [
                              _buildPreview(),
                              const SizedBox(height: 20),
                              Text(
                                _scanning
                                    ? "Point your camera at your professor's QR."
                                    : _submitting
                                    ? 'Verifying attendance…'
                                    : _receipt != null
                                    ? 'Your attendance is saved.'
                                    : _scannedValue != null
                                    ? 'Scan the latest QR to try again.'
                                    : 'Tap below to open the camera.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: secondaryTextColor,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                child: PopButtonEffects(
                                  child: ElevatedButton.icon(
                                    onPressed: _submitting
                                        ? null
                                        : _toggleScanning,
                                    style: ElevatedButton.styleFrom(
                                      elevation: 0,
                                      shadowColor: Colors.transparent,
                                      surfaceTintColor: Colors.transparent,
                                      backgroundColor: buttonColor,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 16,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    icon: Icon(
                                      _scanning
                                          ? Icons.stop_rounded
                                          : Icons.qr_code_scanner_rounded,
                                    ),
                                    label: Text(
                                      _submitting
                                          ? 'Verifying…'
                                          : _scanning
                                          ? 'Stop scanning'
                                          : _scannedValue != null
                                          ? 'Scan again'
                                          : 'Scan the QR',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        _buildDetectedResult(),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ScannerCornersPainter extends CustomPainter {
  const _ScannerCornersPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final inset = size.shortestSide * 0.12;
    final length = size.shortestSide * 0.14;

    final left = inset;
    final top = inset;
    final right = size.width - inset;
    final bottom = size.height - inset;

    final path = Path()
      ..moveTo(left, top + length)
      ..lineTo(left, top)
      ..lineTo(left + length, top)
      ..moveTo(right - length, top)
      ..lineTo(right, top)
      ..lineTo(right, top + length)
      ..moveTo(right, bottom - length)
      ..lineTo(right, bottom)
      ..lineTo(right - length, bottom)
      ..moveTo(left + length, bottom)
      ..lineTo(left, bottom)
      ..lineTo(left, bottom - length);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ScannerCornersPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _QrAttendanceHistoryScreen extends StatefulWidget {
  const _QrAttendanceHistoryScreen({required this.classId});
  final String classId;

  @override
  State<_QrAttendanceHistoryScreen> createState() =>
      _QrAttendanceHistoryScreenState();
}

class _QrAttendanceHistoryScreenState
    extends State<_QrAttendanceHistoryScreen> {
  final _service = NfcAttendanceService();
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  int _version = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final version = ++_version;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _service.history(widget.classId);
      if (!mounted || version != _version) return;
      setState(() => _rows = rows);
    } catch (_) {
      if (!mounted || version != _version) return;
      setState(
            () =>
        _error = 'Could not load attendance history. Tap Refresh to retry.',
      );
    } finally {
      if (mounted && version == _version) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    ++_version;
    super.dispose();
  }

  String _date(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return 'Time unavailable';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Attendance History'),
      actions: [
        IconButton(
          onPressed: _loading ? null : _refresh,
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Text(_error!)
          else if (_rows.isEmpty)
              const Text('No attendance has been recorded for this class yet.')
            else
              ..._rows.map(
                    (row) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.event_available),
                    title: Text(
                      (row['status'] ?? 'Unknown').toString().toUpperCase(),
                    ),
                    subtitle: Text(
                      _date(row['check_in_time'] ?? row['session_started_at']),
                    ),
                  ),
                ),
              ),
        ],
      ),
    ),
  );
}
