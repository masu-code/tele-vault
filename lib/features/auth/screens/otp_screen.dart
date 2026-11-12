import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import 'twofa_screen.dart';

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key});

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    ref.listen(authProvider, (previous, next) {
      // Transition-only, same reason as PhoneScreen: a failed checkPassword
      // keeps step == waitingPassword and would otherwise stack another
      // TwoFaScreen every time.
      if (previous?.step != AuthStep.waitingPassword &&
          next.step == AuthStep.waitingPassword) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TwoFaScreen()),
        );
      } else if (next.step == AuthStep.authenticated) {
        // No 2FA needed — signIn() alone reached authenticated. Changing
        // MaterialApp.home doesn't affect routes already pushed on top of it,
        // so this screen would sit there forever over an app that's actually
        // logged in. Popping back to the root reveals the new home, which is
        // MainShell by now — pushing another MainShell here instead would
        // build a second one and run its whole startup sequence twice.
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Verification')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              const Text('Enter the code', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                'Telegram sent a code to ${auth.phoneNumber}',
                style: const TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 40),
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                maxLength: 5,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Verification code',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              if (auth.error != null) ...[
                const SizedBox(height: 12),
                Text(auth.error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: auth.isLoading
                      ? null
                      : () => ref.read(authProvider.notifier).signIn(_codeController.text.trim()),
                  child: auth.isLoading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Verify'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
