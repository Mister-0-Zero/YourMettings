import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/models/meeting_example.dart';

class _ChangedTextBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode('Обрезанный текст')));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'three full fictional meetings are bundled, each 5000–15000 words',
    () async {
      final examples = await MeetingExample.catalog();
      expect(examples.map((e) => e.id).toSet(), {
        'weekly_planning',
        'manager_report',
        'employee_engagement',
      });
      final word = RegExp(r'[А-Яа-яЁёA-Za-z0-9]+(?:[-’][А-Яа-яЁёA-Za-z0-9]+)*');
      for (final example in examples) {
        final text = await example.loadText();
        expect(text, startsWith(example.title));
        expect(text, contains('Вымышленный учебный транскрипт'));
        expect(word.allMatches(text).length, example.wordCount);
        expect(example.wordCount, inInclusiveRange(5000, 15000));
        expect(text.runes.length, example.characterCount);
        expect(sha256.convert(utf8.encode(text)).toString(), example.sha256Hex);
        // These fixtures deliberately exceed the old short-preview API limit.
        expect(text.runes.length, greaterThan(12000));
      }
    },
  );

  test(
    'full text includes final corrections at the end of each meeting',
    () async {
      final examples = await MeetingExample.catalog();
      final endings = <String, List<String>>{
        'weekly_planning': ['5 ноября', 'двадцать'],
        'manager_report': ['девяносто тысяч', 'не согласованы'],
        'employee_engagement': [
          '12 ноября',
          '3 декабря',
          '7 декабря',
          'сорок пять тысяч',
        ],
      };
      for (final example in examples) {
        final text = await example.loadText();
        final end = text.substring(text.length - 5000);
        for (final fact in endings[example.id]!) {
          expect(end, contains(fact), reason: example.id);
        }
      }
    },
  );

  test(
    'a damaged or truncated example is rejected before submission',
    () async {
      final example = (await MeetingExample.catalog()).first;
      await expectLater(
        example.loadText(bundle: _ChangedTextBundle()),
        throwsFormatException,
      );
    },
  );
}
