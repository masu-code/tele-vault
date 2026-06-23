import 'package:flutter/material.dart';

// Placeholder — Phase 3
class ExplorerScreen extends StatelessWidget {
  const ExplorerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 64, color: Color(0xFF2AABEE)),
            SizedBox(height: 16),
            Text('Authenticated', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('Explorer coming in Phase 3', style: TextStyle(color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}
