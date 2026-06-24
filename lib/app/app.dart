import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/auth/providers/auth_provider.dart';
import '../features/auth/screens/phone_screen.dart';
import '../features/shell/main_shell.dart';

class TeleVaultApp extends ConsumerWidget {
  const TeleVaultApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);

    return MaterialApp(
      title: 'TeleVault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF2AABEE),
          surface: Color(0xFF1C1C1E),
        ),
      ),
      home: auth.isAuthenticated ? const MainShell() : const PhoneScreen(),
    );
  }
}
