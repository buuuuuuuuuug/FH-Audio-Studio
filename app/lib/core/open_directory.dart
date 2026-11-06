import 'dart:ffi';
import 'dart:io';

/// Open once in Explorer and foreground the requested folder. No focus timer
/// survives this operation, so later user interaction is never intercepted.
Future<void> openDirectory(String path) async {
  final folder = Directory(path).absolute;
  if (!await folder.exists()) {
    throw FileSystemException('目录不存在', folder.path);
  }
  if (!Platform.isWindows) {
    await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [folder.path]);
    return;
  }
  try {
    DynamicLibrary.open(
      'user32.dll',
    ).lookupFunction<Int32 Function(Uint32), int Function(int)>(
      'AllowSetForegroundWindow',
    )(0xffffffff);
  } on Object {
    // Explorer can still open on systems that restrict foreground activation.
  }
  // Invoke the Windows shell directly from the foreground application. A
  // detached PowerShell/COM helper can silently fail in an MTA host.
  final kernel = DynamicLibrary.open('kernel32.dll');
  final heap = kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();
  final allocate = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  final free = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  final name = allocate(heap, 8, (folder.path.length + 1) * 2).cast<Uint16>();
  if (name == nullptr) throw const FileSystemException('无法打开目录：内存不足');
  try {
    name.asTypedList(folder.path.length).setAll(0, folder.path.codeUnits);
    final result = DynamicLibrary.open('shell32.dll')
        .lookupFunction<
          IntPtr Function(
            Pointer<Void>,
            Pointer<Uint16>,
            Pointer<Uint16>,
            Pointer<Uint16>,
            Pointer<Uint16>,
            Int32,
          ),
          int Function(
            Pointer<Void>,
            Pointer<Uint16>,
            Pointer<Uint16>,
            Pointer<Uint16>,
            Pointer<Uint16>,
            int,
          )
        >('ShellExecuteW')(nullptr, nullptr, name, nullptr, nullptr, 1);
    if (result <= 32) {
      throw FileSystemException('Windows 无法打开目录（错误 $result）', folder.path);
    }
  } finally {
    free(heap, 0, name.cast<Void>());
  }
}
