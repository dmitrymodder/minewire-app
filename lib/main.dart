import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'dart:io';
import 'about_page.dart';
import 'settings_page.dart';
import 'config_page.dart';
import 'models/profile.dart';
import 'services/minewire_core.dart'; // Import Core

import 'package:dynamic_color/dynamic_color.dart';
import 'package:window_manager/window_manager.dart';
import 'package:system_tray/system_tray.dart';

// Helper to get Core
MinewireCore get core {
  if (Platform.isWindows) return MinewireCoreWindows();
  return MinewireCoreAndroid();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  if (Platform.isWindows) {
      try {
        await windowManager.ensureInitialized();
        WindowOptions windowOptions = const WindowOptions(
          size: Size(800, 600),
          center: true,
          skipTaskbar: false,
          titleBarStyle: TitleBarStyle.normal,
        );
        
        
        await windowManager.show();
        await windowManager.focus();
        
        // Init Tray
        await _initSystemTray();
      } catch (e) {
          print("Windows Initialization Failed: $e");
          // Fallback: try to show window anyway if manager is partially init
          try { await windowManager.show(); } catch (_) {}
      }
  } else {
      // Request Notification Permission on Start (Android)
      await Permission.notification.request();
  }

  // Load settings before app starts
  final prefs = await SharedPreferences.getInstance();
  final themeModeIndex = prefs.getInt('theme_mode') ?? ThemeMode.system.index;
  final useDynamicColor = prefs.getBool('use_dynamic_color') ?? true;

  runApp(MinewireApp(
    initialThemeMode: ThemeMode.values[themeModeIndex],
    initialUseDynamicColor: useDynamicColor,
  ));
}

Future<void> _initSystemTray() async {
  final SystemTray systemTray = SystemTray();
  final AppWindow appWindow = AppWindow();
  
  // Icon is located in data/flutter_assets/assets/ relative to exe
  String iconPath = '';
  if (Platform.isWindows) {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final iconFile = File('${exeDir.path}/data/flutter_assets/assets/app_icon.ico');
    
    print('Minewire: Checking icon at: ${iconFile.path}');
    
    if (await iconFile.exists()) {
      // Use forward slashes - system_tray seems to prefer them
      iconPath = iconFile.path.replaceAll('\\', '/');
      print('Minewire: Icon found, using path: $iconPath');
    } else {
      // Fallback to project root path (for development)
      iconPath = 'assets/app_icon.ico';
      print('Minewire: Icon not found, using fallback: $iconPath');
    }
  }
  
  print('Minewire: Final icon path: $iconPath');
  
  await systemTray.initSystemTray(
    title: "Minewire",
    iconPath: iconPath,
    toolTip: "Minewire VPN",
  );
  
  final Menu menu = Menu();
  await menu.buildFrom([
    MenuItemLabel(label: 'Show', onClicked: (menuItem) => appWindow.show()),
    MenuItemLabel(label: 'Quit', onClicked: (menuItem) async {
        await core.stop();
        await systemTray.destroy();
        exit(0); // Completely terminate the process
    }),
  ]);
  
  await systemTray.setContextMenu(menu);
  
  systemTray.registerSystemTrayEventHandler((eventName) {
    if (eventName == kSystemTrayEventClick) {
      Platform.isWindows ? appWindow.show() : systemTray.popUpContextMenu();
    } else if (eventName == kSystemTrayEventRightClick) {
      Platform.isWindows ? systemTray.popUpContextMenu() : appWindow.show();
    }
  });
}

class MinewireApp extends StatefulWidget {
  final ThemeMode initialThemeMode;
  final bool initialUseDynamicColor;

  const MinewireApp({
    super.key,
    required this.initialThemeMode,
    required this.initialUseDynamicColor,
  });

  @override
  State<MinewireApp> createState() => _MinewireAppState();
}

class _MinewireAppState extends State<MinewireApp> {
  late ThemeMode _themeMode;
  late bool _useDynamicColor;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.initialThemeMode;
    _useDynamicColor = widget.initialUseDynamicColor;
  }

  Future<void> _updateThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('theme_mode', mode.index);
  }

  Future<void> _updateDynamicColor(bool use) async {
    setState(() => _useDynamicColor = use);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_dynamic_color', use);
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        ColorScheme lightScheme;
        ColorScheme darkScheme;
        
        bool canUseDynamic = _useDynamicColor && !Platform.isWindows; // Disable dynamic color on Windows

        if (lightDynamic != null && canUseDynamic) {
            lightScheme = lightDynamic.copyWith(brightness: Brightness.light);
        } else {
            lightScheme = ColorScheme.fromSeed(
                seedColor: Colors.deepPurple,
                brightness: Brightness.light,
            );
        }

        if (darkDynamic != null && canUseDynamic) {
            darkScheme = darkDynamic.copyWith(brightness: Brightness.dark);
        } else {
            darkScheme = ColorScheme.fromSeed(
                seedColor: Colors.deepPurple,
                brightness: Brightness.dark,
            );
        }

        return MaterialApp(
          title: 'Minewire',
          themeMode: _themeMode,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: lightScheme,
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: darkScheme,
          ),
          home: MainScreen(
             themeMode: _themeMode,
             useDynamicColor: _useDynamicColor,
             onThemeModeChanged: _updateThemeMode,
             onDynamicColorChanged: _updateDynamicColor,
          ),
        );
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final bool useDynamicColor;
  final Function(ThemeMode) onThemeModeChanged;
  final Function(bool) onDynamicColorChanged;

  const MainScreen({
      super.key, 
      required this.themeMode, 
      required this.useDynamicColor,
      required this.onThemeModeChanged,
      required this.onDynamicColorChanged,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver, WindowListener {
  int _selectedIndex = 0;
  bool _isConnected = false;
  bool _isConnecting = false;
  String? _activeProfileId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
        windowManager.addListener(this);
        // Override close to minimize
        windowManager.setPreventClose(true); 
    }
    _loadActiveProfile();
    _checkServiceStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) {
        windowManager.removeListener(this);
    }
    super.dispose();
  }
  
  @override
  void onWindowClose() async {
    // Minimize to tray instead of closing
    bool _isPreventClose = await windowManager.isPreventClose();
    if (_isPreventClose) {
      windowManager.hide();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh VPN status when app comes back to foreground
    if (state == AppLifecycleState.resumed) {
      _checkServiceStatus();
    }
  }

  Future<void> _loadActiveProfile() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _activeProfileId = prefs.getString('active_profile_id');
    });
  }

  Future<void> _setActiveProfile(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_profile_id', id);
    setState(() {
      _activeProfileId = id;
    });
  }

  Future<void> _checkServiceStatus() async {
    try {
      final bool isActive = await core.isActive();
      if (mounted) {
        setState(() {
          _isConnected = isActive;
        });
      }
    } catch (_) {
      // Ignore
    }
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  Future<void> _toggleConnection() async {
    setState(() {
      _isConnecting = true;
    });

    try {
      if (_isConnected) {
        await core.stop();
        setState(() {
          _isConnected = false;
        });
      } else {
        final prefs = await SharedPreferences.getInstance();
        
        // --- Profile Selection Logic ---
        String configToUse = "";
        String serverAddr = "";
        String password = "";
        
        // 1. Try to find active profile
        if (_activeProfileId != null) {
            final profilesJson = prefs.getString('profiles');
            if (profilesJson != null) {
                final List<dynamic> decoded = jsonDecode(profilesJson);
                final profiles = decoded.map((e) => ServerProfile.fromJson(e)).toList();
                final activeProfile = profiles.firstWhere(
                    (p) => p.id == _activeProfileId, 
                    orElse: () => ServerProfile.createDefault() 
                );
                configToUse = activeProfile.configText ?? "";
                serverAddr = activeProfile.serverAddress;
                password = activeProfile.password;
            }
        }
        
        // 2. Fallback to old 'config' key if no profiles (legacy support)
        if (configToUse.isNotEmpty && serverAddr.isEmpty) {
             serverAddr = _extractYamlValue(configToUse, "server_address") ?? "";
             password = _extractYamlValue(configToUse, "password") ?? "";
        }
        
        // 3. Check if server address is empty
        if (serverAddr.isEmpty) {
           ScaffoldMessenger.of(context).showSnackBar(
             SnackBar(content: Text("Ошибка: Выберите профиль или настройте подключение"), backgroundColor: Colors.red),
           );
           setState(() => _isConnecting = false);
           return;
        }

        final localPort = prefs.getString('global_local_port') ?? ":1080";
        final proxyType = prefs.getString('global_proxy_type') ?? "socks5";

        final err = await core.start(localPort, serverAddr, password, proxyType);
        if (err != null) {
            throw err;
        }

        setState(() {
          _isConnected = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("Ошибка: $e"),
            backgroundColor: Theme.of(context).colorScheme.error),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  String? _extractYamlValue(String yaml, String key) {
    final regExp = RegExp('$key:\\s*"?([^"\\n]+)"?');
    final match = regExp.firstMatch(yaml);
    return match?.group(1);
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = <Widget>[
      HomePage(
        isConnected: _isConnected,
        isConnecting: _isConnecting,
        onToggle: _toggleConnection,
      ),
      ConfigPage(
        activeProfileId: _activeProfileId,
        onProfileSelected: _setActiveProfile,
      ),
      SettingsPage(
        themeMode: widget.themeMode,
        useDynamicColor: widget.useDynamicColor,
        onThemeModeChanged: widget.onThemeModeChanged,
        onDynamicColorChanged: widget.onDynamicColorChanged,
      ),
      const AboutPage(),
    ];

    return Scaffold(
      body: pages[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onItemTapped,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Главная',
          ),
          NavigationDestination(
            icon: Icon(Icons.data_object),
            selectedIcon: Icon(Icons.data_object),
            label: 'Конфиг',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Настройки',
          ),
          NavigationDestination(
            icon: Icon(Icons.info_outline),
            selectedIcon: Icon(Icons.info),
            label: 'Инфо',
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final bool isConnected;
  final bool isConnecting;
  final VoidCallback onToggle;

  const HomePage({
    super.key,
    required this.isConnected,
    required this.isConnecting,
    required this.onToggle,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int? _pingMs;
  bool _isPinging = false;

  @override
  void initState() {
    super.initState();
    _refreshPing();
  }

  Future<void> _refreshPing() async {
    if (_isPinging) return;

    setState(() {
      _isPinging = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      String serverAddr = "";

      // Get server address from active profile
      final activeProfileId = prefs.getString('active_profile_id');
      if (activeProfileId != null) {
        final profilesJson = prefs.getString('profiles');
        if (profilesJson != null) {
          final List<dynamic> decoded = jsonDecode(profilesJson);
          final profiles = decoded.map((e) => ServerProfile.fromJson(e)).toList();
          final activeProfile = profiles.firstWhere(
            (p) => p.id == activeProfileId,
            orElse: () => ServerProfile.createDefault(),
          );
           // Use new field
           serverAddr = activeProfile.serverAddress; 
           // If empty, try legacy extraction
           if (serverAddr.isEmpty && (activeProfile.configText?.isNotEmpty ?? false)) {
               final regExp = RegExp(r'server_address:\s*"?([^"\n]+)"?');
               final match = regExp.firstMatch(activeProfile.configText!);
               serverAddr = match?.group(1) ?? "";
           }
        }
      }

      // Fallback to old config
      if (serverAddr.isEmpty) {
        final oldConfig = prefs.getString('config') ?? "";
        final regExp = RegExp(r'server_address:\s*"?([^"\n]+)"?');
        final match = regExp.firstMatch(oldConfig);
        serverAddr = match?.group(1) ?? "";
      }

      if (serverAddr.isEmpty) {
        setState(() {
          _pingMs = null;
          _isPinging = false;
        });
        return;
      }

      // Call Core Ping
      final int result = await core.ping(serverAddr);
      if (mounted) {
        setState(() {
          _pingMs = result;
          _isPinging = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _pingMs = null;
          _isPinging = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minewire VPN'),
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.isConnected ? Icons.vpn_lock : Icons.vpn_lock_outlined,
              size: 120,
              color: widget.isConnected ? colorScheme.primary : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 32),
            Text(
              widget.isConnected ? 'VPN Активен' : 'VPN Отключен',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 48),
            SizedBox(
              width: 200,
              height: 56,
              child: FilledButton.icon(
                onPressed: widget.isConnecting ? null : widget.onToggle,
                icon: widget.isConnecting
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.onPrimary,
                        ),
                      )
                    : Icon(widget.isConnected ? Icons.stop : Icons.play_arrow),
                label: Text(
                  widget.isConnecting
                      ? '...'
                      : widget.isConnected
                          ? 'Отключить'
                          : 'Подключить',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: widget.isConnected ? colorScheme.error : colorScheme.primary,
                  foregroundColor: widget.isConnected ? colorScheme.onError : colorScheme.onPrimary,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Ping indicator
            InkWell(
              onTap: _refreshPing,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.network_ping,
                      size: 18,
                      color: _pingMs == null || _pingMs! < 0
                          ? colorScheme.error
                          : _pingMs! < 100
                              ? Colors.green
                              : _pingMs! < 300
                                  ? Colors.orange
                                  : colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    _isPinging
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          )
                        : Text(
                            _pingMs == null || _pingMs! < 0
                                ? 'N/A'
                                : '${_pingMs} ms',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

