import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:minewire_app/main.dart'; // Access core getter
import 'package:minewire_app/services/split_tunnel_service.dart';

class SettingsPage extends StatefulWidget {
  final ThemeMode themeMode;
  final bool useDynamicColor;
  final bool usePaleColor;
  final Function(ThemeMode) onThemeModeChanged;
  final Function(bool) onDynamicColorChanged;
  final Function(bool) onPaleColorChanged;

  const SettingsPage({
    super.key,
    required this.themeMode,
    required this.useDynamicColor,
    required this.usePaleColor,
    required this.onThemeModeChanged,
    required this.onDynamicColorChanged,
    required this.onPaleColorChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _portController;
  String _proxyType = "socks5";
  
  // Split Tunneling State
  bool _splitTunnelingEnabled = false;
  Map<String, bool> _splitCountries = {
    "ru": false,
    "ir": false,
    "cn": false,
  };

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
      
      _splitTunnelingEnabled = prefs.getBool('split_tunnel_enabled') ?? false;
      _splitCountries["ru"] = prefs.getBool('split_ru') ?? false;
      _splitCountries["ir"] = prefs.getBool('split_ir') ?? false;
      _splitCountries["cn"] = prefs.getBool('split_cn') ?? false;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('global_local_port', _portController.text);
    await prefs.setString('global_proxy_type', _proxyType);
    
    await prefs.setBool('split_tunnel_enabled', _splitTunnelingEnabled);
    await prefs.setBool('split_ru', _splitCountries["ru"]!);
    await prefs.setBool('split_ir', _splitCountries["ir"]!);
    await prefs.setBool('split_cn', _splitCountries["cn"]!);

    await prefs.setBool('split_cn', _splitCountries["cn"]!);

    await SplitTunnelService.applyConfig(core);
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
          _buildSplitTunnelSection(context),
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
    String title = "Динамические цвета";
    String subtitle = "Использовать цвета из обоев (Material You)";
    
    if (Platform.isWindows) {
        title = "Акцентный цвет Windows";
        subtitle = "Использовать системный цвет";
    }

    return Column(
        children: [
            SwitchListTile(
              title: Text(title),
              subtitle: Text(subtitle),
              value: widget.useDynamicColor,
              onChanged: widget.onDynamicColorChanged,
              secondary: Icon(
                Icons.palette_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            if (widget.useDynamicColor)
                SwitchListTile(
                  title: const Text('Бледные тона'),
                  subtitle: const Text('Использовать менее насыщенные цвета'),
                  value: widget.usePaleColor,
                  onChanged: widget.onPaleColorChanged,
                  secondary: Icon(
                    Icons.contrast,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
        ],
    );
  }
  
  Widget _buildSplitTunnelSection(BuildContext context) {
      return Column(
          children: [
             SwitchListTile(
               title: const Text('Раздельное туннелирование'),
               subtitle: const Text('Прямое подключение для выбранных регионов'),
               value: _splitTunnelingEnabled,
               onChanged: (val) {
                   setState(() => _splitTunnelingEnabled = val);
                   _saveSettings();
               },
               secondary: Icon(
                 Icons.alt_route,
                 color: Theme.of(context).colorScheme.primary,
               ),
             ),
             if (_splitTunnelingEnabled) ...[
                 CheckboxListTile(
                     title: const Text('Россия (RU)'),
                     value: _splitCountries["ru"],
                     onChanged: (val) {
                         setState(() => _splitCountries["ru"] = val!);
                         _saveSettings();
                     },
                     controlAffinity: ListTileControlAffinity.leading,
                     contentPadding: const EdgeInsets.only(left: 32, right: 16),
                 ),
                 CheckboxListTile(
                     title: const Text('Иран (IR)'),
                     value: _splitCountries["ir"],
                     onChanged: (val) {
                         setState(() => _splitCountries["ir"] = val!);
                         _saveSettings();
                     },
                     controlAffinity: ListTileControlAffinity.leading,
                     contentPadding: const EdgeInsets.only(left: 32, right: 16),
                 ),
                 CheckboxListTile(
                     title: const Text('Китай (CN)'),
                     value: _splitCountries["cn"],
                     onChanged: (val) {
                         setState(() => _splitCountries["cn"] = val!);
                         _saveSettings();
                     },
                     controlAffinity: ListTileControlAffinity.leading,
                     contentPadding: const EdgeInsets.only(left: 32, right: 16),
                 ),
             ]
          ]
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
