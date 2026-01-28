import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LoginProfile {
  final String host;
  final int port;
  final String username;
  final String keyPath;
  final DateTime lastUsed;

  const LoginProfile({
    required this.host,
    required this.port,
    required this.username,
    required this.keyPath,
    required this.lastUsed,
  });

  String get label {
    final u = username.trim().isEmpty ? '?' : username.trim();
    final h = host.trim().isEmpty ? '?' : host.trim();
    return '$u@$h:$port';
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'username': username,
    'keyPath': keyPath,
    'lastUsed': lastUsed.toIso8601String(),
  };

  static LoginProfile fromJson(Map<String, dynamic> json) {
    return LoginProfile(
      host: (json['host'] ?? '').toString(),
      port: int.tryParse((json['port'] ?? 22).toString()) ?? 22,
      username: (json['username'] ?? '').toString(),
      keyPath: (json['keyPath'] ?? '').toString(),
      lastUsed:
          DateTime.tryParse((json['lastUsed'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  bool matches(LoginProfile other) {
    return host == other.host &&
        port == other.port &&
        username == other.username &&
        keyPath == other.keyPath;
  }
}

class LoginHistoryStore {
  static const String _key = 'recent_logins_v1';
  static const int _max = 12;

  Future<List<LoginProfile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty) return <LoginProfile>[];

    try {
      final decoded = json.decode(raw);
      if (decoded is! List) return <LoginProfile>[];
      final profiles = decoded
          .whereType<Map>()
          .map((m) => LoginProfile.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      profiles.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
      return profiles;
    } catch (_) {
      return <LoginProfile>[];
    }
  }

  Future<void> save(List<LoginProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = profiles.take(_max).map((p) => p.toJson()).toList();
    await prefs.setString(_key, json.encode(jsonList));
  }

  Future<List<LoginProfile>> addOrUpdate(
    List<LoginProfile> current, {
    required String host,
    required int port,
    required String username,
    required String keyPath,
  }) async {
    final next = List<LoginProfile>.from(current);

    final incoming = LoginProfile(
      host: host.trim(),
      port: port,
      username: username.trim(),
      keyPath: keyPath.trim(),
      lastUsed: DateTime.now(),
    );

    next.removeWhere((p) => p.matches(incoming));
    next.insert(0, incoming);

    await save(next);
    return next;
  }

  Future<List<LoginProfile>> remove(
    List<LoginProfile> current,
    LoginProfile profile,
  ) async {
    final next = List<LoginProfile>.from(current);
    next.removeWhere((p) => p.matches(profile));
    await save(next);
    return next;
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
