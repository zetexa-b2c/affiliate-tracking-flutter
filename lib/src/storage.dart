import 'package:shared_preferences/shared_preferences.dart';

/// Where the SDK keeps its state on the device: the current attribution,
/// the install id, and the queue of events not yet delivered.
abstract interface class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  static const _prefix = 'affiliate_tracking.';

  final SharedPreferencesAsync _prefs;

  @override
  Future<String?> read(String key) => _prefs.getString('$_prefix$key');

  @override
  Future<void> write(String key, String value) =>
      _prefs.setString('$_prefix$key', value);

  @override
  Future<void> delete(String key) => _prefs.remove('$_prefix$key');
}

/// Keeps everything in memory. For tests, or for apps that must not persist
/// anything (attribution is then lost when the app is killed).
class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
