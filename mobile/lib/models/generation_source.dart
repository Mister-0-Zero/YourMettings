import 'dart:convert';

/// All three limits apply simultaneously, as defined by API_CONTRACT.md.
String? validateGenerationSource(String text) {
  if (text.trim().isEmpty) return 'Добавьте транскрипт встречи.';
  final words = RegExp(r'\S+', unicode: true).allMatches(text).length;
  if (words > 15000 ||
      text.runes.length > 200000 ||
      utf8.encode(text).length > 400000) {
    return 'Текст превышает лимит: 15 000 слов, 200 000 символов или 400 000 байт. Текст сохранён целиком.';
  }
  return null;
}
