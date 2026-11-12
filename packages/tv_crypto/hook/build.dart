import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds `tv_crypto` (portable AES/SHA-256 plus runtime-selected AES-NI or
/// ARMv8 Crypto Extensions) as a bundled dynamic library for the asset
/// `package:tv_crypto/src/bindings.dart`.
///
/// The accelerated files select themselves with preprocessor guards and
/// per-function target attributes, so no ISA flags are needed here:
/// arm64 gets ARMv8 AES/SHA2, x64 desktop gets AES-NI, armeabi-v7a and
/// Android x86_64 build the portable path only.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    if (input.config.code.targetOS == OS.windows) {
      await _buildWithMsvc(input, output);
      return;
    }

    final library = CBuilder.library(
      name: 'tv_crypto',
      packageName: 'tv_crypto',
      assetName: assetName,
      sources: sources,
      includes: const ['src'],
      flags: const ['-fvisibility=hidden'],
    );

    await library.run(input: input, output: output);
  });
}

const assetName = 'src/bindings.dart';

const sources = [
  'src/tvc_dispatch.c',
  'src/aes_portable.c',
  'src/aes_armv8.c',
  'src/aes_x86.c',
  'src/sha256_portable.c',
  'src/sha256_armv8.c',
];

/// Windows (MSVC) build without `CBuilder`.
///
/// native_toolchain_c 0.19.1 starts cl.exe with `runInShell: true` whenever
/// it sets a working directory (lib/src/utils/run_process.dart:44). The
/// command then goes through `cmd /c` with a quoted cl.exe path
/// ("C:\Program Files\...") plus quoted arguments; cmd strips the outer
/// quotes and fails with "'C:\Program' is not recognized" as soon as any
/// argument (package or output path) contains a space, as in this project.
/// Here the MSVC environment is resolved the same way native_toolchain_c
/// does (developer prompt from the hook input, else vswhere + vcvars) and
/// cl.exe is started directly, without a shell.
Future<void> _buildWithMsvc(
  BuildInput input,
  BuildOutputBuilder output,
) async {
  final code = input.config.code;
  final (machine, vcvarsName) = switch (code.targetArchitecture) {
    Architecture.x64 => ('X64', 'vcvars64.bat'),
    Architecture.ia32 => ('X86', 'vcvars32.bat'),
    Architecture.arm64 => ('ARM64', 'vcvarsamd64_arm64.bat'),
    final other => throw UnsupportedError('tv_crypto: Windows/$other'),
  };

  final Map<String, String> env;
  final prompt = code.cCompiler?.windows.developerCommandPrompt;
  if (prompt != null) {
    env = await environmentFromBatchFile(
      prompt.script,
      arguments: prompt.arguments,
    );
  } else {
    final vsRoot = await _visualStudioRoot();
    env = await environmentFromBatchFile(
      Uri.directory(vsRoot).resolve('VC/Auxiliary/Build/$vcvarsName'),
    );
  }

  final cl =
      code.cCompiler?.compiler.toFilePath() ?? _findOnPath('cl.exe', env);

  final outDir = input.outputDirectory;
  await Directory.fromUri(outDir).create(recursive: true);
  final linkMode = DynamicLoadingBundled();
  final dll =
      outDir.resolve(code.targetOS.libraryFileName('tv_crypto', linkMode));
  final sourceUris = [
    for (final s in sources) input.packageRoot.resolve(s),
  ];

  final result = await Process.run(
    cl,
    [
      '/nologo',
      '/O2',
      '/DNDEBUG',
      '/I${input.packageRoot.resolve('src/').toFilePath()}',
      '/LD',
      '/Fe:${dll.toFilePath()}',
      for (final s in sourceUris) s.toFilePath(),
      '/link',
      '/MACHINE:$machine',
    ],
    workingDirectory: outDir.toFilePath(),
    environment: env,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      cl,
      const [],
      'tv_crypto: cl.exe failed (${result.exitCode})\n'
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: assetName,
      linkMode: linkMode,
      file: dll,
    ),
  );
  output.dependencies.addAll([
    ...sourceUris,
    input.packageRoot.resolve('src/tv_crypto.h'),
  ]);
}

Future<String> _visualStudioRoot() async {
  const candidates = [
    r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe',
    r'C:\Program Files\Microsoft Visual Studio\Installer\vswhere.exe',
  ];
  for (final vswhere in candidates) {
    if (!File(vswhere).existsSync()) continue;
    final r = await Process.run(vswhere, [
      '-latest',
      '-products',
      '*',
      '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      '-property',
      'installationPath',
    ]);
    final path = (r.stdout as String).trim().split(RegExp(r'\r?\n')).first;
    if (r.exitCode == 0 && path.isNotEmpty) return path;
  }
  throw StateError('tv_crypto: Visual Studio with C++ tools not found');
}

String _findOnPath(String exe, Map<String, String> env) {
  final pathVar = env.entries
      .firstWhere(
        (e) => e.key.toUpperCase() == 'PATH',
        orElse: () => MapEntry('PATH', Platform.environment['PATH'] ?? ''),
      )
      .value;
  for (final dir in pathVar.split(';')) {
    if (dir.isEmpty) continue;
    final f = File('$dir\\$exe');
    if (f.existsSync()) return f.path;
  }
  throw StateError('tv_crypto: $exe not found in the MSVC environment');
}
