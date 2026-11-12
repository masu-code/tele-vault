import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/api_credentials_service.dart';
import '../providers/auth_provider.dart';

/// Shown once, before anything else, on an install that hasn't registered
/// its own Telegram API credentials yet — see [ApiCredentialsService] for
/// why every install needs its own instead of one shared by the app.
class ApiCredentialsScreen extends ConsumerStatefulWidget {
  const ApiCredentialsScreen({super.key});

  @override
  ConsumerState<ApiCredentialsScreen> createState() => _ApiCredentialsScreenState();
}

class _ApiCredentialsScreenState extends ConsumerState<ApiCredentialsScreen> {
  final _apiIdController = TextEditingController();
  final _apiHashController = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _apiIdController.dispose();
    _apiHashController.dispose();
    super.dispose();
  }

  Future<void> _openMyTelegramOrg() async {
    final uri = Uri.parse('https://my.telegram.org/apps');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort — the URL is also shown as selectable text below for
      // manual copy/paste if no browser handler is available.
    }
  }

  Future<void> _save() async {
    final rawId = _apiIdController.text.trim();
    final hash = _apiHashController.text.trim();
    final id = int.tryParse(rawId);

    if (id == null) {
      setState(() => _error = 'App api_id must be a number.');
      return;
    }
    // my.telegram.org's api_hash is always a 32-character hex string — this
    // isn't cryptographically validated, just enough to catch a pasted
    // api_id-into-the-wrong-field or an empty/truncated paste before it
    // reaches the server as a confusing MTProto error instead.
    if (hash.length != 32 || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hash)) {
      setState(() => _error = 'App api_hash should be a 32-character code from my.telegram.org.');
      return;
    }

    setState(() {
      _error = null;
      _saving = true;
    });
    await ApiCredentialsService.instance.save(id, hash);
    if (!mounted) return;
    ref.read(authProvider.notifier).credentialsSaved();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.vpn_key_outlined, size: 56, color: Color(0xFF2AABEE)),
              const SizedBox(height: 24),
              const Text(
                'Connect your own Telegram app',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'TeleVault talks to Telegram directly, and Telegram requires every '
                'app to register its own free api_id/api_hash — one login session '
                "isn't enough, this app needs its own credentials, separate from "
                'your Telegram account itself. This is a one-time step done once '
                'per install, not per login.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Get them free at my.telegram.org/apps (log in with your phone '
                      'number, takes about a minute).',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                  IconButton(
                    onPressed: _openMyTelegramOrg,
                    icon: const Icon(Icons.open_in_new, color: Color(0xFF2AABEE)),
                    tooltip: 'Open my.telegram.org/apps',
                  ),
                ],
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _apiIdController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'App api_id',
                  hintText: '12345678',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _apiHashController,
                decoration: const InputDecoration(
                  labelText: 'App api_hash',
                  hintText: '0123456789abcdef0123456789abcdef',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
