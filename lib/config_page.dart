import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'models/profile.dart'; // Profile model
import 'services/minewire_core.dart';
import 'widgets/server_info_card.dart';

class ConfigPage extends StatefulWidget {
  final String? activeProfileId;
  final Function(String) onProfileSelected;

  const ConfigPage({
    super.key,
    required this.activeProfileId,
    required this.onProfileSelected,
  });

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  List<ServerProfile> _profiles = [];
  List<String> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _loadProfiles();
    _loadSubscriptions();
  }

  Future<void> _loadSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _subscriptions = prefs.getStringList('subscriptions') ?? [];
    });
  }

  Future<void> _saveSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('subscriptions', _subscriptions);
  }

  Future<void> _loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final String? profilesJson = prefs.getString('profiles');

    if (profilesJson != null) {
      final List<dynamic> decoded = jsonDecode(profilesJson);
      setState(() {
        _profiles = decoded.map((e) => ServerProfile.fromJson(e)).toList();
      });
    } else {
      // Create default profile if none exist (migration)
      final oldConfig = prefs.getString('config');
      final defaultProfile = ServerProfile.createDefault();
      defaultProfile.name = "Default";
      if (oldConfig != null) {
        defaultProfile.configText = oldConfig;
      }
      setState(() {
        _profiles = [defaultProfile];
      });
      _saveProfiles();
      
      // Select the default one if none selected
      if (widget.activeProfileId == null) {
         widget.onProfileSelected(defaultProfile.id);
      }
    }
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_profiles.map((e) => e.toJson()).toList());
    await prefs.setString('profiles', encoded);
  }

  void _showAddOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Добавить вручную'),
              onTap: () {
                Navigator.pop(ctx);
                _addNewProfile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Импортировать из URI'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromLink();
              },
            ),
            ListTile(
              leading: const Icon(Icons.rss_feed),
              title: const Text('Добавить подписку'),
              onTap: () {
                Navigator.pop(ctx);
                _addSubscription();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _addSubscription() {
      // Dialog to enter URL
      final controller = TextEditingController();
      showDialog(
        context: context, 
        builder: (ctx) => AlertDialog(
            title: const Text("Добавить подписку"),
            content: TextField(
                controller: controller,
                decoration: const InputDecoration(labelText: "URL подписки"),
            ),
            actions: [
                TextButton(child: const Text("Отмена"), onPressed: () => Navigator.pop(ctx)),
                TextButton(child: const Text("Добавить"), onPressed: () async {
                    Navigator.pop(ctx);
                    if (controller.text.isNotEmpty) {
                        setState(() {
                            _subscriptions.add(controller.text);
                        });
                        await _saveSubscriptions();
                        _updateAllSubscriptions();
                    }
                }),
            ],
        )
      );
  }

  Future<void> _updateAllSubscriptions() async {
    if (_subscriptions.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Нет активных подписок")));
        return;
    }

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    int addedCount = 0;
    int updatedCount = 0;
    
    // Core for parsing links
    final core = Platform.isWindows ? MinewireCoreWindows() : MinewireCoreAndroid();
    
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Обновление подписок...")));

    for (String url in _subscriptions) {
        try {
            final request = await client.getUrl(Uri.parse(url));
            final response = await request.close();
            if (response.statusCode == 200) {
                 final body = await response.transform(utf8.decoder).join();
                 final lines = const LineSplitter().convert(body);
                 
                 for (String line in lines) {
                     line = line.trim();
                     if (line.isEmpty) continue;
                     
                     // Support both direct mw:// links and maybe wrapped text? assuming mw:// for now
                     // If the line doesn't start with mw://, skip or check if it's a valid link?
                     // User said: "Nick2.txt where will be one line with mw://"
                     if (!line.startsWith("mw://")) continue;

                     final parsed = await core.parseLink(line);
                     if (parsed.containsKey('error')) continue;
                      
                     final address = parsed['server']?.toString() ?? "";
                     final pwd = parsed['password']?.toString() ?? "";
                     final name = parsed['name']?.toString() ?? "Imported";
                      
                     // Find existing profile linked to this subscription
                     // We match by URL and Name (since address/pass might change)
                     // Or match by URL and Address?
                     // Let's match by SubscriptionURL AND Name as the primary key from that sub
                     final index = _profiles.indexWhere((p) => 
                        p.subscriptionUrl == url && p.name == name
                     );
                      
                     if (index >= 0) {
                        // Update
                        _profiles[index].serverAddress = address;
                        _profiles[index].password = pwd;
                        updatedCount++;
                     } else {
                        // Create New
                        final newP = ServerProfile.createDefault();
                        newP.serverAddress = address;
                        newP.password = pwd;
                        newP.name = name;
                        newP.subscriptionUrl = url;
                        _profiles.add(newP);
                        addedCount++;
                     }
                 }
            }
        } catch (e) {
            print("Error updating subscription $url: $e");
        }
    }
    
    setState((){});
    _saveProfiles();
    
    if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Готово. Добавлено: $addedCount, Обновлено: $updatedCount")));
    }
  }

  Future<void> _importFromLink() async {
     final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
     if (data?.text == null) return;
     final String link = data!.text!;
     
     if (!link.startsWith("mw://")) {
         if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ссылка должна начинаться с mw://")));
         return;
     }

     try {
       // Use local instance logic to avoid circular dependency
       final core = Platform.isWindows ? MinewireCoreWindows() : MinewireCoreAndroid();
       final Map<String, dynamic> parsed = await core.parseLink(link);
       
       if (parsed.containsKey('error')) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Ошибка парсинга: ${parsed['error']}")));
          return;
       }
       
       final newProfile = ServerProfile.createDefault();
       
       newProfile.serverAddress = parsed['server'] ?? "";
       newProfile.password = parsed['password'] ?? "";
       if (parsed['name'] != null && parsed['name'].toString().isNotEmpty) {
           newProfile.name = parsed['name'];
       } else {
           newProfile.name = "Profile ${_profiles.length + 1}";
       }

       setState(() {
         _profiles.add(newProfile);
       });
       _saveProfiles();
       
       if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Профиль импортирован!")));
       
     } catch (e) {
       if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Ошибка: $e")));
     }
  }

  void _addNewProfile() {
    final newProfile = ServerProfile.createDefault();
    newProfile.name = "Profile ${_profiles.length + 1}";
    setState(() {
      _profiles.add(newProfile);
    });
    _saveProfiles();
    _editProfile(newProfile);
  }

  void _deleteProfile(ServerProfile profile) {
    bool isSubscription = profile.subscriptionUrl != null;
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Удалить профиль?"),
        content: Text(isSubscription 
            ? "Этот профиль добавлен через подписку.\nУдалить его и отписаться?" 
            : "Вы уверены, что хотите удалить ${profile.name}?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Отмена")),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _profiles.removeWhere((p) => p.id == profile.id);
                if (isSubscription) {
                    _subscriptions.remove(profile.subscriptionUrl);
                }
              });
              _saveProfiles();
              if (isSubscription) _saveSubscriptions();
            },
            child: const Text("Удалить", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _editProfile(ServerProfile profile) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProfileEditorPage(
          profile: profile,
          onSave: (name, address, password) {
            setState(() {
              profile.name = name;
              profile.serverAddress = address;
              profile.password = password;
            });
            _saveProfiles();
          },
        ),
      ),
    );
  }

// ... (existing imports)

// ... (inside _ConfigPageState)

  @override
  Widget build(BuildContext context) {
    // Find active profile address
    String activeAddress = "";
    if (widget.activeProfileId != null) {
        final active = _profiles.where((p) => p.id == widget.activeProfileId).firstOrNull;
        if (active != null) {
            activeAddress = active.serverAddress;
        }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Профили'),
        centerTitle: true,
        actions: [
             IconButton(
                 icon: const Icon(Icons.sync), 
                 onPressed: _updateAllSubscriptions, 
                 tooltip: "Обновить подписки"
             ),
        ],
      ),
      body: Column(
        children: [
            Expanded(
              child: _profiles.isEmpty
                  ? const Center(child: Text("Нет профилей"))
                  : ListView.builder(
                      itemCount: _profiles.length,
                      itemBuilder: (context, index) {
                        final profile = _profiles[index];
                        final isActive = profile.id == widget.activeProfileId;
                        
                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          elevation: isActive ? 4 : 1,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: isActive 
                                ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
                                : BorderSide.none,
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            title: Text(
                              profile.name,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isActive ? Theme.of(context).colorScheme.primary : null,
                              ),
                            ),
                            subtitle: Text(
                               "${profile.serverAddress}", 
                               maxLines: 1, 
                               overflow: TextOverflow.ellipsis
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _editProfile(profile),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _deleteProfile(profile),
                                ),
                              ],
                            ),
                            onTap: () {
                              widget.onProfileSelected(profile.id);
                            },
                            leading: isActive 
                                ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
                                : const Icon(Icons.circle_outlined),
                          ),
                        );
                      },
                    ),
            ),
            // Server Info Card at the bottom
            if (activeAddress.isNotEmpty)
                ServerInfoCard(serverAddress: activeAddress),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddOptions,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class ProfileEditorPage extends StatefulWidget {
  final ServerProfile profile;
  final Function(String name, String address, String password) onSave;

  const ProfileEditorPage({super.key, required this.profile, required this.onSave});

  @override
  State<ProfileEditorPage> createState() => _ProfileEditorPageState();
}

class _ProfileEditorPageState extends State<ProfileEditorPage> {
  late TextEditingController _nameController;
  late TextEditingController _addressController;
  late TextEditingController _passwordController;
  static const platform = MethodChannel('com.minewire.tunnel/control');

  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.name);
    _addressController = TextEditingController(text: widget.profile.serverAddress);
    _passwordController = TextEditingController(text: widget.profile.password);
  }

  void _exportProfile() {
      // Logic to create mw:// link manually since we don't have a Go encoder exposed yet, or simple string format
      // Format: mw://password@server#name
      // Note: Name should be url encoded
      final pwd = Uri.encodeComponent(_passwordController.text);
      final server = _addressController.text; // Assuming raw is fine, or encode if unusual chars
      final name = Uri.encodeComponent(_nameController.text);
      
      final link = "mw://$pwd@$server#$name";
      Clipboard.setData(ClipboardData(text: link));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ссылка скопирована в буфер обмена")));
  }

  void _save() {
    widget.onSave(_nameController.text, _addressController.text, _passwordController.text);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Редактирование"),
        actions: [
          IconButton(icon: const Icon(Icons.share), onPressed: _exportProfile, tooltip: "Экспорт"),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.check), onPressed: _save, tooltip: "Сохранить"),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: "Имя профиля",
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                const SizedBox(height: 16),
                TextField(
                  controller: _addressController,
                  decoration: const InputDecoration(
                    labelText: "Адрес сервера (ip:port)",
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.dns),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: "Пароль",
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.key),
                    suffixIcon: IconButton(
                        icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  obscureText: _obscurePassword,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
