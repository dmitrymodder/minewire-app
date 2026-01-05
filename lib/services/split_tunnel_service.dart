import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'minewire_core.dart';

class SplitTunnelService {
  static Future<void> applyConfig(MinewireCore core) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('split_tunnel_enabled') ?? false;
    
    if (!enabled) {
      await core.updateConfig("");
      print("Split Tunneling Disabled. Config cleared.");
      return;
    }

    final ru = prefs.getBool('split_ru') ?? false;
    final ir = prefs.getBool('split_ir') ?? false;
    final cn = prefs.getBool('split_cn') ?? false;

    Directory appDir;
    if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent;
        appDir = Directory('${exeDir.path}/data');
    } else {
        appDir = await getApplicationSupportDirectory();
    }

    final geoDir = Directory('${appDir.path}/geoip');
    if (!geoDir.existsSync()) {
      geoDir.createSync(recursive: true);
    }

    List<String> rulePaths = [];
    
    Future<String> copyAsset(String country) async {
       final filename = "$country.zone";
       final file = File('${geoDir.path}/$filename');
       try {
           final data = await rootBundle.load("assets/geoip/$filename");
           final bytes = data.buffer.asUint8List();
           await file.writeAsBytes(bytes);
           return file.path;
       } catch (e) {
           print("Error copying asset $filename: $e");
           return "";
       }
    }

    if (ru) {
        final path = await copyAsset("ru");
        if (path.isNotEmpty) rulePaths.add(path);
    }
    if (ir) {
        final path = await copyAsset("ir");
        if (path.isNotEmpty) rulePaths.add(path);
    }
    if (cn) {
        final path = await copyAsset("cn");
        if (path.isNotEmpty) rulePaths.add(path);
    }

    await core.updateConfig(rulePaths.join(","));
    print("Split Tunneling Config Updated: ${rulePaths.length} rules loaded.");
  }
}
