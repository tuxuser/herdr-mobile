import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/features/agent_session/output_language.dart';

// Which tool output reads as source code, and in which language. Samples are
// real shapes: a C++ header through `sed` (CRLF, as pi's log holds it), JSON,
// an `ls` listing, test progress and prose. The call names no file (a piped
// command), so only the text itself decides.

const _header =
    '//!! Source Address (16 byte aligned - save us 4 bits)\r\n'
    'uint64_t data_addr:36;\r\n'
    '//!! Hash Input Address (16 bytes aligned)\r\n'
    'uint64_t hash_addr:36;\r\n'
    'size:25; //!! Size in multiple of 16 bytes\r\n'
    'struct {\r\n'
    '  uint64_t source_addr:36;\r\n'
    '};\r\n';

const _json = '{\n  "name": "herdr-mobile",\n  "version": "0.1.69",\n  "private": true\n}\n';

const _ls = 'total 12\ndrwxr-xr-x. 3 e99 e99 4096 20. Nov 12:39 .\ndrwxr-xr-x. 189 e99 e99 4096 20. Nov 12:38 ..\n';

const _progress = 'collecting tests...\n+12 -0: All tests passed!\nWall time: 3.2s\n';

const _prose = 'The agent finished the task.\nIt wrote two files and ran the tests.\n';

void main() {
  test('a C++ header reads as C++, whatever its line endings', () {
    expect(outputLanguage(_header), 'cpp');
    expect(outputLanguage(_header.replaceAll('\r\n', '\n')), 'cpp');
  });

  test('JSON reads as JSON', () {
    expect(outputLanguage(_json), 'json');
    expect(outputLanguage('{"a": [1, {"b": null}]}'), 'json');
  });

  test('balanced brackets that are not JSON read as nothing', () {
    expect(outputLanguage('{foo}'), isNull);
    expect(outputLanguage('{not json}'), isNull);
    expect(outputLanguage('{"a": }'), isNull);
  });

  test('a listing, progress lines and prose read as nothing', () {
    expect(outputLanguage(_ls), isNull);
    expect(outputLanguage(_progress), isNull);
    expect(outputLanguage(_prose), isNull);
    expect(outputLanguage(''), isNull);
    expect(outputLanguage('\n\n'), isNull);
  });
}
