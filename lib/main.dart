import 'screens/student_password_recovery_screen.dart';
// import 'package:comptech_portal_app/screens/login_screen.dart';
// import 'package:comptech_portal_app/screens/registration_screen.dart';
// import 'package:comptech_portal_app/screens/student_home_screen.dart';
// import 'package:comptech_portal_app/screens/student_profile_screen.dart';
// import 'screens/student_dashboard_screen.dart';
import 'package:comptech_portal_app/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppTheme.load();

  await Supabase.initialize(
    url: 'https://imdigrgakhikhzjukygp.supabase.co',
    publishableKey: 'sb_publishable_z0nb7ok1iTSn9v2aSpiuIA_wVhktaip',
  );

  Supabase.instance.client.auth.onAuthStateChange.listen(
        (data) {
      if (data.event == AuthChangeEvent.passwordRecovery &&
          data.session != null) {
        recoveryPending = true;
        openRecoveryScreen();
      }
    },
    onError: (Object error) {
      recoveryErrorPending = true;
      showRecoveryError();
    },
  );
  runApp(const MyApp());
  WidgetsBinding.instance.addPostFrameCallback((_) {
    openRecoveryScreen();
    showRecoveryError();
  });
}

final appNavigator = GlobalKey<NavigatorState>();
final appMessenger = GlobalKey<ScaffoldMessengerState>();
bool recoveryPending = false;
bool recoveryErrorPending = false;
void showRecoveryError() {
  if (!recoveryErrorPending || appMessenger.currentState == null) return;
  recoveryErrorPending = false;
  appMessenger.currentState!.showSnackBar(
    const SnackBar(
      content: Text('Recovery link failed. Request a new reset email.'),
    ),
  );
}

void openRecoveryScreen() {
  final navigator = appNavigator.currentState;
  if (!recoveryPending || navigator == null) return;
  recoveryPending = false;
  navigator.pushAndRemoveUntil(
    MaterialPageRoute<void>(
      builder: (_) => StudentPasswordRecoveryScreen(
        initialEmail: Supabase.instance.client.auth.currentUser?.email ?? '',
        recoveryVerified: true,
      ),
    ),
        (_) => false,
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    AppTheme.mode.addListener(_onModeChanged);
  }

  @override
  void dispose() {
    AppTheme.mode.removeListener(_onModeChanged);
    super.dispose();
  }

  // Screens read AppColors directly, so redraw every open screen (keeping
  // their state and navigation) when the mode changes.
  void _onModeChanged() {
    setState(() {});
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigator,
      scaffoldMessengerKey: appMessenger,
      debugShowCheckedModeBanner: false,
      title: 'CiTracker',
      themeMode: AppTheme.mode.value,
      theme: AppTheme.data(AppPalette.light, Brightness.light),
      darkTheme: AppTheme.data(AppPalette.dark, Brightness.dark),
      // Status bar icons for screens without an AppBar.
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.overlayStyle,
        child: child!,
      ),

      // Temporary dashboard preview: bypasses Login.
      home: const LoginScreen(),
    );
  }
}
