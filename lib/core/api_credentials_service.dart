import 'package:shared_preferences/shared_preferences.dart';

class ApiCredentialsService {
  ApiCredentialsService._();
  static final instance = ApiCredentialsService._();

  static const _apiIdKey = 'cred_api_id';
  static const _apiHashKey = 'cred_api_hash';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  int? get apiId => _prefs!.getInt(_apiIdKey);
  String? get apiHash => _prefs!.getString(_apiHashKey);

  bool get hasCredentials {
    final hash = apiHash;
    return apiId != null && hash != null && hash.isNotEmpty;
  }

  Future<void> save(int apiId, String apiHash) async {
    await _prefs!.setInt(_apiIdKey, apiId);
    await _prefs!.setString(_apiHashKey, apiHash);
  }

  Future<void> clear() async {
    await _prefs!.remove(_apiIdKey);
    await _prefs!.remove(_apiHashKey);
  }
}
