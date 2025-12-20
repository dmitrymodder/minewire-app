import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  final ThemeMode themeMode;
  final bool useDynamicColor;
  final Function(ThemeMode) onThemeModeChanged;
  final Function(bool) onDynamicColorChanged;

  const SettingsPage({
    super.key,
    required this.themeMode,
    required this.useDynamicColor,
    required this.onThemeModeChanged,
    required this.onDynamicColorChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _portController;
  String _proxyType = "socks5";

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(text: ":1080");
    // On Windows, default to HTTP since SOCKS5 is not available
    _proxyType = Platform.isWindows ? "http" : "socks5";
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    var proxyType = prefs.getString('global_proxy_type') ?? "socks5";
    
    // On Windows, SOCKS5 is not available, force HTTP
    if (Platform.isWindows && proxyType == "socks5") {
      proxyType = "http";
      await prefs.setString('global_proxy_type', proxyType);
    }
    
    setState(() {
      _portController.text = prefs.getString('global_local_port') ?? ":1080";
      _proxyType = proxyType;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('global_local_port', _portController.text);
    await prefs.setString('global_proxy_type', _proxyType);
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки'),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          _buildThemeSection(context),
          const Divider(),
          _buildDynamicColorSection(context),
          const Divider(),
          _buildProxySection(context),
        ],
      ),
    );
  }

  Widget _buildThemeSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            'Тема оформления',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ),
        RadioListTile<ThemeMode>(
          title: const Text('Системная'),
          value: ThemeMode.system,
          groupValue: widget.themeMode,
          onChanged: (val) => widget.onThemeModeChanged(val!),
        ),
        RadioListTile<ThemeMode>(
          title: const Text('Светлая'),
          value: ThemeMode.light,
          groupValue: widget.themeMode,
          onChanged: (val) => widget.onThemeModeChanged(val!),
        ),
        RadioListTile<ThemeMode>(
          title: const Text('Темная'),
          value: ThemeMode.dark,
          groupValue: widget.themeMode,
          onChanged: (val) => widget.onThemeModeChanged(val!),
        ),
      ],
    );
  }

  Widget _buildDynamicColorSection(BuildContext context) {
    if (Platform.isWindows) return const SizedBox.shrink(); // Hide on Windows
    return SwitchListTile(
      title: const Text('Динамические цвета'),
      subtitle: const Text('Использовать цвета из обоев (Material You)'),
      value: widget.useDynamicColor,
      onChanged: widget.onDynamicColorChanged,
      secondary: Icon(
        Icons.palette_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  Widget _buildProxySection(BuildContext context) {
    return Column(
       crossAxisAlignment: CrossAxisAlignment.start,
       children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Настройки локального прокси',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: "Локальный порт (напр. :1080)",
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _saveSettings(),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<String>(
               value: _proxyType,
               decoration: const InputDecoration(
                 labelText: "Тип прокси",
                 border: OutlineInputBorder(),
               ),
               items: [
                 if (!Platform.isWindows) const DropdownMenuItem(value: "socks5", child: Text("SOCKS5")),
                 const DropdownMenuItem(value: "http", child: Text("HTTP")),
               ],
               onChanged: (val) {
                 if (val != null) {
                   setState(() => _proxyType = val);
                   _saveSettings();
                 }
               },
            ),
          ),
          const SizedBox(height: 16),
       ],
    );
  }
}
