import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/minewire_core.dart';

class ServerInfoCard extends StatefulWidget {
  final String serverAddress;

  const ServerInfoCard({super.key, required this.serverAddress});

  @override
  State<ServerInfoCard> createState() => _ServerInfoCardState();
}

class _ServerInfoCardState extends State<ServerInfoCard> {
  bool _loading = true;
  String _error = "";
  
  String _motd = "";
  String _version = "";
  int _online = 0;
  int _max = 0;
  ImageProvider? _favicon;

  @override
  void initState() {
    super.initState();
    _fetchStatus();
  }
  
  @override
  void didUpdateWidget(ServerInfoCard oldWidget) {
      super.didUpdateWidget(oldWidget);
      if (oldWidget.serverAddress != widget.serverAddress) {
          _fetchStatus();
      }
  }

  Future<void> _fetchStatus() async {
    if (widget.serverAddress.isEmpty) return;

    setState(() {
      _loading = true;
      _error = "";
    });

    try {
      final core = Platform.isWindows ? MinewireCoreWindows() : MinewireCoreAndroid();
      final data = await core.getServerStatus(widget.serverAddress);

      if (mounted) {
        setState(() {
          _loading = false;
          if (data.containsKey('error')) {
            _error = data['error'].toString();
          } else {
             // Parse successful response
             // Structure: {version: {name, protocol}, players: {max, online}, description: {text}, favicon}
             
             final desc = data['description'];
             if (desc is Map) {
                 _motd = desc['text']?.toString() ?? "";
             } else {
                 _motd = desc?.toString() ?? "";
             }
             
             final ver = data['version'];
             if (ver is Map) {
                 final name = ver['name']?.toString() ?? "";
                 final protocol = ver['protocol'];
                 _version = protocol != null ? "$name (protocol $protocol)" : name;
             }
             
             final pl = data['players'];
             if (pl is Map) {
                 _online = pl['online'] ?? 0;
                 _max = pl['max'] ?? 0;
             }
             
             final fav = data['favicon'] as String?;
             if (fav != null && fav.startsWith("data:image/png;base64,")) {
                 try {
                    final base64Str = fav.split(",")[1];
                    _favicon = MemoryImage(base64Decode(base64Str));
                 } catch (e) {
                     print("Favicon decode error: $e");
                 }
             } else {
                 _favicon = null;
             }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.serverAddress.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
             Row(
                 mainAxisAlignment: MainAxisAlignment.spaceBetween,
                 children: [
                     const Text("Информация о сервере", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                     IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _fetchStatus, tooltip: "Обновить"),
                 ],
             ),
             const Divider(),
             if (_loading) 
                 const Center(child: Padding(
                   padding: EdgeInsets.all(16.0),
                   child: CircularProgressIndicator(),
                 ))
             else if (_error.isNotEmpty)
                 Padding(
                   padding: const EdgeInsets.all(8.0),
                   child: Row(
                       children: [
                           const Icon(Icons.error_outline, color: Colors.orange),
                           const SizedBox(width: 8),
                           Expanded(child: Text("Ошибка: $_error", style: const TextStyle(color: Colors.orange))),
                       ],
                   ),
                 )
             else 
                 Row(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     children: [
                         if (_favicon != null) 
                             Container(
                                 width: 64, height: 64,
                                 decoration: BoxDecoration(
                                     border: Border.all(color: Colors.grey.shade300),
                                     borderRadius: BorderRadius.circular(4),
                                     image: DecorationImage(image: _favicon!, fit: BoxFit.cover),
                                 ),
                             )
                         else 
                             Container(
                                 width: 64, height: 64,
                                 decoration: BoxDecoration(
                                     color: Colors.grey.shade200,
                                     borderRadius: BorderRadius.circular(4),
                                 ),
                                 child: const Icon(Icons.dns, size: 32, color: Colors.grey),
                             ),
                         const SizedBox(width: 16),
                         Expanded(
                             child: Column(
                                 crossAxisAlignment: CrossAxisAlignment.start,
                                 children: [
                                     Text(_motd, style: const TextStyle(fontSize: 15, height: 1.3)),
                                     const SizedBox(height: 8),
                                     Row(
                                         children: [
                                             const Icon(Icons.people_outline, size: 16, color: Colors.grey),
                                             const SizedBox(width: 4),
                                             Text("$_online / $_max", style: const TextStyle(color: Colors.grey)),
                                             const SizedBox(width: 16),
                                             const Icon(Icons.info_outline, size: 16, color: Colors.grey),
                                             const SizedBox(width: 4),
                                             Text(_version, style: const TextStyle(color: Colors.grey)),
                                         ],
                                     ),
                                 ],
                             ),
                         ),
                     ],
                 )
          ],
        ),
      ),
    );
  }
}
