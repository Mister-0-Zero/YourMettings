import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Bundled synthetic transcripts. They never enter the user's meeting history
/// unless the user explicitly submits one through a meeting workflow.
class MeetingExample {
  const MeetingExample({
    required this.id,
    required this.title,
    required this.asset,
    required this.wordCount,
    required this.characterCount,
    required this.sha256Hex,
  });

  final String id, title, asset, sha256Hex;
  final int wordCount, characterCount;

  factory MeetingExample.fromJson(Map<String, dynamic> json) => MeetingExample(
    id: json['id'] as String,
    title: json['title'] as String,
    asset: json['asset'] as String,
    wordCount: json['word_count'] as int,
    characterCount: json['character_count'] as int,
    sha256Hex: json['sha256'] as String,
  );

  static Future<List<MeetingExample>> catalog({AssetBundle? bundle}) async {
    final json = jsonDecode(
      await (bundle ?? rootBundle).loadString(
        'assets/meeting_examples/catalog.json',
      ),
    ) as List<dynamic>;
    return List.unmodifiable([
      for (final item in json)
        MeetingExample.fromJson(item as Map<String, dynamic>),
    ]);
  }

  /// Refuse damaged or mismatched bundled text rather than test a partial input.
  Future<String> loadText({AssetBundle? bundle}) async {
    final text = await (bundle ?? rootBundle).loadString(asset);
    if (text.runes.length != characterCount ||
        sha256.convert(utf8.encode(text)).toString() != sha256Hex) {
      throw const FormatException('Не удалось прочитать полный текст примера.');
    }
    return text;
  }
}
