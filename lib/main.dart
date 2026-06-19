import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_page.dart';
import 'theme.dart';
import 'viewer_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BabyMonitorApp());
}

class BabyMonitorApp extends StatelessWidget {
  const BabyMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Baby Monitor',
      debugShowCheckedModeBanner: false,
      theme: babyTheme,
      home: const RolePicker(),
    );
  }
}

class RolePicker extends StatefulWidget {
  const RolePicker({super.key});

  @override
  State<RolePicker> createState() => _RolePickerState();
}

class _RolePickerState extends State<RolePicker> {
  String? _lastRole;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance()
        .then((p) => setState(() => _lastRole = p.getString('role')));
  }

  Future<void> _open(String role) async {
    (await SharedPreferences.getInstance()).setString('role', role);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          role == 'camera' ? const CameraPage() : const ViewerPage(),
    ));
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => _lastRole = p.getString('role'));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: warmBackdrop),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: warmSeed.withValues(alpha: 0.25),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Icon(Icons.child_care, size: 56, color: scheme.primary),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Baby Monitor',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      color: warmBrown,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Keep a gentle eye on your little one',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: warmBrown.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 36),
                  _RoleButton(
                    icon: Icons.videocam_rounded,
                    title: 'Use as Camera',
                    subtitle:
                        'This phone watches the baby (use an Android phone, plugged in)',
                    highlight: _lastRole == 'camera',
                    onTap: () => _open('camera'),
                  ),
                  const SizedBox(height: 14),
                  _RoleButton(
                    icon: Icons.phone_iphone_rounded,
                    title: 'Use as Viewer',
                    subtitle: 'Watch the stream from here',
                    highlight: _lastRole == 'viewer',
                    onTap: () => _open('viewer'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleButton extends StatelessWidget {
  const _RoleButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.highlight,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: highlight ? scheme.primaryContainer : Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, size: 28, color: scheme.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: warmBrown,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        color: warmBrown.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                highlight ? Icons.history_rounded : Icons.chevron_right_rounded,
                color: scheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
