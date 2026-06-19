import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_page.dart';
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
      theme: ThemeData.dark(useMaterial3: true),
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
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.crib, size: 64),
              const SizedBox(height: 8),
              Text('Baby Monitor',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 32),
              _RoleButton(
                icon: Icons.videocam,
                title: 'Camera',
                subtitle:
                    'This phone watches the baby (use an Android phone, plugged in)',
                highlight: _lastRole == 'camera',
                onTap: () => _open('camera'),
              ),
              const SizedBox(height: 12),
              _RoleButton(
                icon: Icons.phone_iphone,
                title: 'Viewer',
                subtitle: 'Watch the stream from here',
                highlight: _lastRole == 'viewer',
                onTap: () => _open('viewer'),
              ),
            ],
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
    return Card(
      color: highlight ? Theme.of(context).colorScheme.primaryContainer : null,
      child: ListTile(
        leading: Icon(icon, size: 32),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: highlight
            ? const Icon(Icons.history)
            : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
