import 'dart:convert';

import '../services/remote_files.dart';

/// The context window sizes pi's model catalog reports, by
/// `provider/modelId`, so usage grows a window size. Null when the catalog
/// cannot be read or names no model: usage stays unsized. Reading the
/// catalog is best-effort enrichment; failing the whole log follow because
/// it failed would lose the chat for a number nobody reads.
Future<Map<String, int>?> loadPiContextSizes(RemoteFiles files) async {
  try {
    final home = await files.home();
    final bytes = await files.read('$home/.pi/agent/models-store.json', length: _maxBytes);
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map<String, dynamic>) return null;
    final sizes = <String, int>{};
    for (final provider in decoded.entries) {
      final models = provider.value is Map<String, dynamic> ? (provider.value as Map<String, dynamic>)['models'] : null;
      if (models is! List) continue;
      for (final model in models) {
        if (model is! Map<String, dynamic>) continue;
        final id = model['id'];
        final size = model['contextWindow'];
        if (id is String && id.isNotEmpty && size is int && size > 0) {
          sizes['${provider.key}/$id'] = size;
        }
      }
    }
    return sizes.isEmpty ? null : sizes;
  } on Object {
    return null;
  }
}

/// The catalog is hundreds of kilobytes; more than this is not the catalog.
const _maxBytes = 2 * 1024 * 1024;
