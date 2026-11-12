// Host-side driver for the perf integration tests. Writes the report data the
// test put in `binding.reportData` (numbers only) to build/perf/<testName>.json.
//
//   flutter drive --driver=test_driver/perf_driver.dart \
//     --target=integration_test/synthetic_gallery_test.dart --profile -d <device>
//
// (tool/measure_device.ps1 does this for you.)
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() {
  return integrationDriver(
    responseDataCallback: (data) async {
      if (data == null) return;
      final raw = (data['testName'] as String?) ?? 'result';
      final name = raw.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
      Directory('build/perf').createSync(recursive: true);
      final file = File('build/perf/$name.json');
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
      // ignore: avoid_print
      print('TVDIAG: wrote ${file.path}');
    },
    writeResponseOnFailure: true,
  );
}
