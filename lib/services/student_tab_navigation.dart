import 'package:flutter/foundation.dart';

/// Lets widgets outside the dashboard, like the notification bell, switch
/// the bottom navigation tab. Indexes match StudentDashboardScreen's screens.
class StudentTabNavigation {
  StudentTabNavigation._();

  static const home = 0;
  static const attendance = 1;
  static const scores = 2;
  static const profile = 3;

  static final ValueNotifier<int?> requested = ValueNotifier<int?>(null);

  static void open(int tab) {
    // Reset first so asking for the same tab twice still notifies.
    requested.value = null;
    requested.value = tab;
  }
}
