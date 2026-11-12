import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The upload pipeline's files: none of their log lines (print, debugPrint)
/// or stored run statuses may carry a file name, path or caption. Ids,
/// counts and sizes only.
const _files = [
  'lib/core/upload/upload_service.dart',
  'lib/core/upload/upload_worker.dart',
  'lib/features/transfer/providers/transfer_queue_provider.dart',
  'lib/core/backup/headless_sync.dart',
  'lib/core/backup/transfer_notifications.dart',
];

/// Calls whose arguments end up in logcat or in the stored headless status.
final _call = RegExp(r'\b(print|debugPrint|done|recordHeadlessRun)\(');

/// Identifiers that hold names, paths or captions.
const _private = r'(title|name|path|caption|fileName|filename|basename|body)';

/// `$name` / `$path` ... and `${asset.title}` / `${file.path}` / `${msg['path']}`.
final _forbidden = [
  RegExp(r'\$' + _private + r'\b'),
  RegExp(r'\$\{[^}]*(\.|\[.)' + _private + r'\b[^}]*\}'),
  RegExp(r'\$\{\s*' + _private + r'\b[^}]*\}'),
  RegExp(r'\$e\b(?!\w)'), // raw exceptions can embed paths: use logSafeError(e)
  RegExp(r'\$\{e\}'),
];

/// Every [_call] in [source] with its full argument text (balanced parens).
List<String> _calls(String source) {
  final out = <String>[];
  for (final m in _call.allMatches(source)) {
    var depth = 0;
    var i = m.end - 1;
    for (; i < source.length; i++) {
      final c = source[i];
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    out.add(source.substring(m.start, i + 1));
  }
  return out;
}

List<String> _violations(String source) => [
      for (final call in _calls(source))
        if (_forbidden.any((r) => r.hasMatch(call))) call,
    ];

void main() {
  test('the checker itself flags private interpolations', () {
    expect(_violations("debugPrint('TVQUEUE: upload failed \${asset.title}: \$e');"), hasLength(1));
    expect(_violations("print('TVDIAG: request path=\${msg['path']}');"), hasLength(1));
    expect(_violations("debugPrint('x \$name');"), hasLength(1));
    expect(_violations("print('TVDIAG: file \${file.path}');"), hasLength(1));
    expect(_violations("debugPrint('TVQUEUE: asset=\${asset.id} \${logSafeError(e)}');"), isEmpty);
  });

  for (final path in _files) {
    test('no names, paths or raw errors logged in $path', () {
      final source = File(path).readAsStringSync();
      expect(_calls(source), isNotEmpty, reason: 'scanner found no log calls');
      expect(_violations(source), isEmpty);
    });
  }
}
