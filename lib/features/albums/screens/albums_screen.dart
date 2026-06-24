import 'package:flutter/material.dart';

/// Placeholder for the Albums tab — implemented in the next pass (manual
/// collections of media, independent of folders).
class AlbumsScreen extends StatelessWidget {
  const AlbumsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Albums')),
      body: const Center(
        child: Text(
          'Albums coming next.',
          style: TextStyle(color: Colors.white54),
        ),
      ),
    );
  }
}
