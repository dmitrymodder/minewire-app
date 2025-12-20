import 'package:uuid/uuid.dart';

class ServerProfile {
  final String id;
  String name;
  String serverAddress;
  String password;
  String? configText; // Legacy support
  // Legacy holder not needed, we migrate on load

  ServerProfile({
    required this.id,
    required this.name,
    required this.serverAddress,
    required this.password,
    this.configText,
  });

  factory ServerProfile.createDefault() {
    return ServerProfile(
      id: Uuid().v4(),
      name: 'New Profile',
      serverAddress: '',
      password: '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'server_address': serverAddress,
      'password': password,
    };
  }

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    String address = json['server_address'] ?? '';
    String pwd = json['password'] ?? '';
    
    // Migration Logic: If address empty but config_text exists
    if (address.isEmpty && json.containsKey('config_text')) {
       String config = json['config_text'] ?? '';
       final addrMatch = RegExp(r'server_address:\s*"?([^"\n]+)"?').firstMatch(config);
       final pwdMatch = RegExp(r'password:\s*"?([^"\n]+)"?').firstMatch(config);
       
       if (addrMatch != null) address = addrMatch.group(1) ?? '';
       if (pwdMatch != null) pwd = pwdMatch.group(1) ?? '';
    }

    return ServerProfile(
      id: json['id'] ?? Uuid().v4(),
      name: json['name'] ?? 'Unknown',
      serverAddress: address,
      password: pwd,
      configText: json['config_text'], // Keep reference if needed
    );
  }
}
