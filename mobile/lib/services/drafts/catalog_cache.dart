import 'dart:convert';
import 'dart:io';

import 'package:queue_owner/queue_owner.dart';

import '../../models/api_models.dart';
import '../../models/summary_template.dart';
import 'draft_record.dart';

class CachedCatalog<T> {
  CachedCatalog(this.fetchedAt, List<T> items)
    : items = List.unmodifiable(items);
  final DateTime fetchedAt;
  final List<T> items;
  bool isStale(DateTime now, {Duration ttl = const Duration(hours: 24)}) =>
      now.isBefore(fetchedAt) || now.difference(fetchedAt) > ttl;
}

/// Only folder/template metadata for an already verified scope. No summaries,
/// auth tokens, or inferred cross-origin identity in this cache.
class ScopedCatalogCache {
  ScopedCatalogCache({required this.scopeDirectory, required this.authority}) {
    if (!draftScopePattern.hasMatch(authority.scopeId) ||
        scopeDirectory.uri.pathSegments.where((s) => s.isNotEmpty).last !=
            authority.scopeId) {
      throw ArgumentError('Catalog scope differs from owner');
    }
  }
  final Directory scopeDirectory;
  final QueueWriteAuthority authority;
  File _file(String kind) => File('${scopeDirectory.path}/catalog-$kind.json');
  Future<void> _check(String kind) async {
    if (await FileSystemEntity.isLink(scopeDirectory.path) ||
        await FileSystemEntity.isLink(_file(kind).path)) {
      throw const FileSystemException('Catalog path is a link');
    }
  }

  Future<Json?> _load(String kind) async {
    await _check(kind);
    final file = _file(kind);
    if (!await file.exists()) {
      return null;
    }
    final j = jsonDecode(await file.readAsString()) as Json;
    if (j['schema'] != 1 ||
        j['scope_id'] != authority.scopeId ||
        j['kind'] != kind ||
        j['items'] is! List) {
      throw const FormatException('Catalog scope/schema');
    }
    DateTime.parse(j['fetched_at'] as String);
    return j;
  }

  Future<void> _save(String kind, List<Json> items, DateTime fetchedAt) =>
      authority.serialized(() async {
        await _check(kind);
        final snapshot = jsonEncode({
          'schema': 1,
          'scope_id': authority.scopeId,
          'kind': kind,
          'fetched_at': fetchedAt.toUtc().toIso8601String(),
          'items': items,
        });
        await authority.writeSnapshot(_file(kind), snapshot);
      });
  Future<CachedCatalog<Folder>?> loadFolders() async {
    final j = await _load('folders');
    if (j == null) {
      return null;
    }
    final items = (j['items'] as List)
        .map((item) => Folder.fromJson(item as Json))
        .toList();
    _checkFolders(items);
    return CachedCatalog(DateTime.parse(j['fetched_at'] as String), items);
  }

  void _checkFolders(List<Folder> items) {
    final ids = <String>{};
    for (final entry in flattenFolders(items)) {
      if (entry.folder.id.isEmpty ||
          entry.folder.name.isEmpty ||
          !ids.add(entry.folder.id)) {
        throw const FormatException('Invalid cached folder identity');
      }
    }
  }

  Future<void> saveFolders(List<Folder> items, {DateTime? fetchedAt}) async {
    _checkFolders(items);
    Json encode(Folder folder) => {
      'id': folder.id,
      'name': folder.name,
      'parent_id': folder.parentId,
      'children': folder.children.map(encode).toList(),
    };
    return _save(
      'folders',
      items.map(encode).toList(),
      fetchedAt ?? DateTime.now(),
    );
  }

  Future<CachedCatalog<SummaryTemplate>?> loadTemplates() async {
    final j = await _load('templates');
    if (j == null) {
      return null;
    }
    final items = (j['items'] as List)
        .map((item) => SummaryTemplate.fromJson(item as Json))
        .toList();
    _checkTemplates(items);
    return CachedCatalog(DateTime.parse(j['fetched_at'] as String), items);
  }

  void _checkTemplates(List<SummaryTemplate> items) {
    final ids = <String>{};
    for (final item in items) {
      if (item.id.isEmpty ||
          !ids.add(item.id) ||
          (item.version != null &&
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(item.version!))) {
        throw const FormatException('Invalid cached template identity/version');
      }
    }
  }

  Future<void> saveTemplates(
    List<SummaryTemplate> items, {
    DateTime? fetchedAt,
  }) async {
    _checkTemplates(items);
    return _save(
      'templates',
      items
          .map(
            (item) => <String, dynamic>{
              ...item.input.toJson(),
              'id': item.id,
              'is_system': item.isSystem,
              'is_default': item.isDefault,
              'version': ?item.version,
            },
          )
          .toList(),
      fetchedAt ?? DateTime.now(),
    );
  }
}
