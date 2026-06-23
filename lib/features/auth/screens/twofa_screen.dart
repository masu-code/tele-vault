import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';

class TwoFaScreen extends ConsumerStatefulWidget {
  const TwoFaScreen({super.key});

  @override
  ConsumerState<TwoFaScreen> createState() => _TwoFaScreenState();
}

class _TwoFaScreenState extends ConsumerState<TwoFaScreen> {
  final _passwordController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Two-Step Verification')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              const Text('Enter your password', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Your account has two-step verification enabled.', style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 40),
              TextField(
                controller: _passwordController,
                obscureText: _obscure,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Password',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
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
                      : () => ref.read(authProvider.notifier).checkPassword(_passwordController.text),
                  child: auth.isLoading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Confirm'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
