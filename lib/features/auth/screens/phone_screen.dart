import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import 'otp_screen.dart';

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _phoneController = TextEditingController();

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    // Only on the *transition* into waitingCode. Without the previous-step
    // check this fired on every later emission that kept step == waitingCode
    // — e.g. a failed signIn setting an error — and pushed a second OtpScreen
    // on top of the one the user was already typing into.
    ref.listen(authProvider, (previous, next) {
      if (previous?.step != AuthStep.waitingCode &&
          next.step == AuthStep.waitingCode) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const OtpScreen()),
        );
      }
    });

    return Scaffold(
      // Scrollable and min-sized: in landscape (and with the keyboard up on a
      // short screen) the fixed Column overflowed the viewport — the login
      // screen rendered with the yellow-and-black overflow stripes across the
      // Send Code button.
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.cloud_outlined, size: 56, color: Color(0xFF2AABEE)),
              const SizedBox(height: 24),
              const Text('TeleVault', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Enter your phone number to continue', style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 40),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone number',
                  hintText: '+1 234 567 8900',
                  prefixIcon: Icon(Icons.phone_outlined),
                  border: OutlineInputBorder(),
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
                      : () => ref.read(authProvider.notifier).sendCode(_phoneController.text.trim()),
                  child: auth.isLoading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Send Code'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
