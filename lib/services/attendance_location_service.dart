import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'nfc_attendance_service.dart';

class AttendanceLocation {
  const AttendanceLocation(this.latitude, this.longitude, this.accuracyM, this.isMocked, this.placeName);
  final double latitude, longitude, accuracyM;
  final bool isMocked;
  final String? placeName;

  Map<String, dynamic> toParams() => {
    'p_latitude': latitude,
    'p_longitude': longitude,
    'p_accuracy_m': accuracyM,
    'p_is_mocked': isMocked,
    'p_place_name': placeName,
  };
}

class AttendanceLocationService {
  /// The signed-in student's check-in locations for one class, read from
  /// the `check_in_*` columns of their own attendance rows.
  Future<List<Map<String, dynamic>>> history(String classId) async {
    final data = await Supabase.instance.client
        .rpc('comptech_student_attendance_locations', params: {'p_class_id': classId})
        .timeout(const Duration(seconds: 20));
    if (data is! List) return [];
    return data.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  /// NFC check-ins are saved by the professor's scanner, so the location is
  /// attached right after; the server only accepts the student's own check-in
  /// from the last 5 minutes. Retries because a phone tap is saved a few
  /// seconds after the student's phone responds. Never throws.
  Future<bool> attachToCheckIn(
      AttendanceLocation location, {
        String? sessionId,
        int attempts = 1,
      }) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 5));
      try {
        await Supabase.instance.client
            .rpc('comptech_student_record_check_in_location', params: {
          'p_session_id': sessionId,
          ...location.toParams(),
        })
            .timeout(const Duration(seconds: 20));
        NfcAttendanceService.notifyChanged();
        return true;
      } catch (_) {
        // Usually CHECK_IN_NOT_FOUND: the check-in isn't saved yet.
      }
    }
    return false;
  }

  /// The location for one history row: by session when the row has one,
  /// otherwise by check-in time; both come from the same attendance row.
  static Map<String, dynamic>? find(
      Map<String, dynamic> row,
      List<Map<String, dynamic>> locations,
      ) {
    final session = row['session_id'];
    final checkIn = DateTime.tryParse(row['check_in_time']?.toString() ?? '');
    for (final location in locations) {
      if (session != null && location['session_id'] == session) return location;
      final recorded =
      DateTime.tryParse(location['check_in_time']?.toString() ?? '');
      if (session == null &&
          checkIn != null &&
          recorded != null &&
          recorded.isAtSameMomentAs(checkIn)) {
        return location;
      }
    }
    return null;
  }

  /// Short text for the Attendance History table.
  static String describe(Map<String, dynamic>? row) {
    final method = row?['check_in_method'];
    final sentOffline = method == 'qr_offline'
        ? 'Sent offline (QR)'
        : method == 'phone_tap_offline'
        ? 'Sent offline (phone tap)'
        : null;
    final lat = row?['check_in_latitude'], lng = row?['check_in_longitude'];
    if (lat is! num || lng is! num) {
      return [
        _describeScanner(row) ?? 'Not recorded',
        ?sentOffline,
      ].join('\n');
    }
    return [_describeStudent(row!, lat, lng), ?sentOffline].join('\n');
  }

  /// Offline phone taps can carry the professor scanner's location; the
  /// phones were touching, so it shows where the student was.
  static String? _describeScanner(Map<String, dynamic>? row) {
    final lat = row?['scanner_latitude'], lng = row?['scanner_longitude'];
    if (lat is! num || lng is! num) return null;
    final distance = row?['scanner_distance_m'];
    final onCampus = row?['scanner_on_campus'];
    return [
      "Professor's scanner",
      if (onCampus == true && distance is num) 'On campus (${distance.round()} m)'
      else if (onCampus == false && distance is num)
        'Not verified on campus (${distance.round()} m)'
      else
        '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
    ].join('\n');
  }

  static String _describeStudent(Map<String, dynamic> row, num lat, num lng) {
    final place = row['check_in_location'];
    final accuracy = row['check_in_accuracy_m'];
    final distance = row['check_in_distance_m'];
    final onCampus = row['check_in_on_campus'];
    return [
      place is String && place.isNotEmpty
          ? place
          : '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
      if (accuracy is num) '±${accuracy.round()} m',
      if (onCampus == true && distance is num) 'On campus (${distance.round()} m)',
      // False also covers a nearby but too-inaccurate reading.
      if (onCampus == false && distance is num) 'Not verified on campus (${distance.round()} m)',
      if (row['check_in_mock_location'] == true) 'Flagged: mock location',
    ].join('\n');
  }

  /// "Guinhawa, Malolos, Bulacan": barangay, city or town, province.
  static String? placeName(geocoding.Placemark mark) {
    final parts = <String>[];
    // Province; Android leaves it empty for some areas, so fall back to region.
    final province = (mark.subAdministrativeArea ?? '').trim().isNotEmpty
        ? mark.subAdministrativeArea
        : mark.administrativeArea;
    for (final raw in [mark.subLocality, mark.locality, province]) {
      var part = (raw ?? '').trim();
      // Android often says "City of Malolos"; keep names like "Quezon City".
      if (part.startsWith('City of ')) part = part.substring(8).trim();
      if (part.isNotEmpty && !parts.contains(part)) parts.add(part);
    }
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// Uses the phone's built-in geocoder, which needs internet. Capped so a
  /// slow lookup can't outlast the professor's QR; the coordinates are saved
  /// either way. Offline saves look the name up when they're sent.
  Future<String?> lookupPlace(double latitude, double longitude) async {
    try {
      final marks = await geocoding.Geocoding()
          .placemarkFromCoordinates(latitude, longitude)
          .timeout(const Duration(seconds: 3));
      return marks.isEmpty ? null : placeName(marks.first);
    } catch (_) {
      return null;
    }
  }

  /// Ask when the scanner opens so the prompt never delays a scan.
  Future<void> prepare() async {
    try {
      if (await Geolocator.checkPermission() == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
    } catch (_) {/* Attendance works without location. */}
  }

  /// Never throws: a missing location must not block attendance.
  /// Offline saves wait longer, since GPS without internet is slower and
  /// nothing is waiting on the result; they skip the name lookup.
  Future<AttendanceLocation?> current({
    Duration timeLimit = const Duration(seconds: 5),
    bool lookupName = true,
  }) async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        return null;
      }
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: timeLimit,
          ),
        );
      } catch (_) {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null &&
            DateTime.now().difference(last.timestamp) < const Duration(minutes: 2)) {
          position = last;
        }
      }
      if (position == null) return null;
      final place = lookupName
          ? await lookupPlace(position.latitude, position.longitude)
          : null;
      return AttendanceLocation(position.latitude, position.longitude,
          position.accuracy, position.isMocked, place);
    } catch (_) {
      return null;
    }
  }
}
