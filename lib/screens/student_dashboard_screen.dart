import 'package:flutter/material.dart';
import '../widgets/student_bottom_navigation.dart';
import 'student_home_screen.dart';
import 'attendance_classes_screen.dart';
import 'student_scores_screen.dart';
import 'student_profile_screen.dart';
import '../services/offline_attendance_service.dart';
import '../services/student_tab_navigation.dart';
import '../theme/app_theme.dart';

class StudentDashboardScreen extends StatefulWidget {
  const StudentDashboardScreen({super.key});

  @override
  State<StudentDashboardScreen> createState() =>
      _StudentDashboardScreenState();
}

class _StudentDashboardScreenState
    extends State<StudentDashboardScreen> {
  int _selectedIndex = 0;

  final List<Widget> _screens = const [
    StudentHomeScreen(),
    AttendanceClassesScreen(),
    StudentScoresScreen(),
    StudentProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    StudentTabNavigation.requested.addListener(_onTabRequested);
    // Sends attendance saved while offline once the phone reconnects.
    OfflineAttendanceService.instance.start();
  }

  @override
  void dispose() {
    StudentTabNavigation.requested.removeListener(_onTabRequested);
    super.dispose();
  }

  void _onTabRequested() {
    final index = StudentTabNavigation.requested.value;
    if (index != null && index >= 0 && index < _screens.length) {
      _selectTab(index);
    }
  }

  void _selectTab(int index) {
    if (index == _selectedIndex) return;

    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          for (var index = 0; index < _screens.length; index++)
            TickerMode(
              enabled: index == _selectedIndex,
              child: _screens[index],
            ),
        ],
      ),
      bottomNavigationBar: StudentBottomNavigation(
        currentIndex: _selectedIndex,
        onTap: _selectTab,
      ),
    );
  }
}