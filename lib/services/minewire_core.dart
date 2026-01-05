import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

abstract class MinewireCore {
  Future<String?> start(String localPort, String serverAddress, String password, String proxyType);
  Future<void> stop();
  Future<bool> isActive();
  Future<int> ping(String serverAddress);
  Future<Map<String, dynamic>> parseLink(String link);
  Future<void> updateConfig(String rulePaths);
}

class MinewireCoreAndroid implements MinewireCore {
  static const platform = MethodChannel('com.minewire.tunnel/control');

  @override
  Future<String?> start(String localPort, String serverAddress, String password, String proxyType) async {
    try {
      final result = await platform.invokeMethod('start', {
        "localPort": localPort,
        "serverAddress": serverAddress,
        "password": password,
        "proxyType": proxyType,
      });
      if (result == true) return null; // Success
      return result?.toString();
    } on PlatformException catch (e) {
      return e.message;
    }
  }

  @override
  Future<void> stop() async {
    await platform.invokeMethod('stop');
  }

  @override
  Future<bool> isActive() async {
    return await platform.invokeMethod('isActive');
  }

  @override
  Future<int> ping(String serverAddress) async {
    return await platform.invokeMethod('ping', {"serverAddress": serverAddress});
  }

  @override
  Future<Map<String, dynamic>> parseLink(String link) async {
    final String jsonStr = await platform.invokeMethod('parseLink', {"link": link});
    if (jsonStr.contains('"error":')) {
      return jsonDecode(jsonStr);
    }
    return jsonDecode(jsonStr);
  }

  @override
  Future<void> updateConfig(String rulePaths) async {
    await platform.invokeMethod('updateConfig', {"rules": rulePaths});
  }
}

class MinewireCoreWindows implements MinewireCore {
  Process? _process;
  bool _running = false;
  final Map<String, Completer> _pendingRequests = {};
  int _requestIdCounter = 0;
  
  // Singleton pattern to ensure only one process manager exists
  static final MinewireCoreWindows _instance = MinewireCoreWindows._internal();
  factory MinewireCoreWindows() => _instance;
  MinewireCoreWindows._internal();

  Future<void> _ensureProcess() async {
    if (_process != null) return;
    
    // Assume minewire.exe is next to the executable
    final String exePath = Platform.resolvedExecutable.replaceAll(RegExp(r'[^\\]+$'), 'minewire.exe');
    print("Launching Minewire at $exePath");
    
    if (!File(exePath).existsSync()) {
        throw Exception("minewire.exe not found at $exePath");
    }

    _process = await Process.start(exePath, []);
    _process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_handleResponse);
    _process!.stderr.transform(utf8.decoder).listen((log) => print("Minewire Log: $log"));
    
    _process!.exitCode.then((code) {
       _process = null;
       _running = false;
       print("Minewire exited with code $code");
       // Fail all pending requests
       for (var c in _pendingRequests.values) {
           if (!c.isCompleted) c.completeError("Process Exited");
       }
       _pendingRequests.clear();
    });
  }
  
  void _handleResponse(String line) {
      if (line.isEmpty) return;
      try {
          final Map<String, dynamic> msg = jsonDecode(line);
          final id = msg['id'] as String?;
          if (id != null && _pendingRequests.containsKey(id)) {
              final completer = _pendingRequests.remove(id)!;
              if (msg['success'] == true) {
                  completer.complete(msg['data']); // Data or null for void calls
              } else {
                  completer.completeError(msg['error'] ?? "Unknown Error");
              }
          }
      } catch (e) {
          print("Error parsing IPC line '$line': $e");
      }
  }

  Future<T> _sendRequest<T>(String method, Map<String, dynamic> args) async {
      await _ensureProcess();
      final id = "${_requestIdCounter++}";
      final completer = Completer<T>();
      _pendingRequests[id] = completer;
      
      final req = jsonEncode({
          "id": id,
          "method": method,
          "args": args
      });
      _process!.stdin.writeln(req);
      
      return completer.future;
  }
  
  @override
  Future<String?> start(String localPort, String serverAddress, String password, String proxyType) async {
     try {
         await _sendRequest("start", {
             "localPort": localPort,
             "serverAddress": serverAddress,
             "password": password,
             "proxyType": proxyType
         });
         _running = true;
         return null; // Success returns null error string
     } catch (e) {
         return e.toString();
     }
  }

  @override
  Future<void> stop() async {
      if (_process == null) return;
      try {
          await _sendRequest("stop", {});
      } catch (e) {
          // Ignore
      }
      _running = false;
      // Ideally we don't kill the process unless app closes, 
      // but we might want to "stop" the connection.
      // Our Go implementation of Stop() keeps the process running but closes tunnel.
  }
  
  @override
  Future<bool> isActive() async {
      if (_process == null) return false;
      // We can trust local state or ask process. Asking is safer if process crashes silently?
      // No, exit handler handles crashes.
      // But let's ask to be sure state matches.
      try {
        return await _sendRequest<bool>("isActive", {});
      } catch (_) {
        return false;
      }
  }
  
  @override
  Future<int> ping(String serverAddress) async {
       if (_process == null) await _ensureProcess();
       try {
           return await _sendRequest<int>("ping", {"serverAddress": serverAddress});
       } catch (e) {
           return -1;
       }
  }
  
  @override
  Future<Map<String, dynamic>> parseLink(String link) async {
       if (_process == null) await _ensureProcess();
       return await _sendRequest<Map<String, dynamic>>("parseLink", {"link": link});
  }

  @override
  Future<void> updateConfig(String rulePaths) async {
       if (_process == null) await _ensureProcess();
       await _sendRequest("updateConfig", {"rules": rulePaths});
  }
}
