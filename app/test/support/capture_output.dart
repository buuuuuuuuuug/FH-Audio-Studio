import 'dart:io';

File captureOutputFile(String relativePath) {
  final file = File('build/test-captures/$relativePath');
  file.parent.createSync(recursive: true);
  return file;
}
