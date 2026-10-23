import 'dart:math';

import 'api_models.dart';

String newSectionId() {
  final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class TemplateSection {
  TemplateSection({
    required this.id,
    required this.title,
    required this.instruction,
    this.required = true,
    this.repeated = false,
    this.children = const [],
  });
  final String id;
  final String title;
  final String instruction;
  final bool required;
  final bool repeated;
  final List<TemplateSection> children;
  TemplateSection copyWith({
    String? title,
    String? instruction,
    bool? required,
    List<TemplateSection>? children,
  }) => TemplateSection(
    id: id,
    title: title ?? this.title,
    instruction: instruction ?? this.instruction,
    required: required ?? this.required,
    repeated: repeated,
    children: List.unmodifiable(children ?? this.children),
  );
  Json toJson(int position) => {
    'id': id,
    'title': title.trim(),
    'instruction': instruction.trim(),
    'position': position,
    'required': required,
    'type': repeated ? 'repeated' : 'section',
    'children': [
      for (var i = 0; i < children.length; i++) children[i].toJson(i),
    ],
  };
  factory TemplateSection.fromJson(Json j) => TemplateSection(
    id: j['id'] as String,
    title: j['title'] as String,
    instruction: j['instruction'] as String,
    required: j['required'] as bool? ?? true,
    repeated: j['type'] == 'repeated',
    children: [
      for (final c in j['children'] as List? ?? [])
        TemplateSection.fromJson(c as Json),
    ],
  );
}

class TemplateInput {
  const TemplateInput({
    required this.name,
    this.description = '',
    this.structureMode = 'strict',
    this.generalInstructions = '',
    required this.sections,
  });
  final String name;
  final String description;
  final String structureMode;
  final String generalInstructions;
  final List<TemplateSection> sections;
  Json toJson() => {
    'name': name.trim(),
    'description': description.trim(),
    'structure_mode': structureMode,
    'general_instructions': generalInstructions.trim(),
    'sections': [
      for (var i = 0; i < sections.length; i++) sections[i].toJson(i),
    ],
  };
  factory TemplateInput.fromJson(Json j) => TemplateInput(
    name: j['name'] as String,
    description: j['description'] as String? ?? '',
    structureMode: j['structure_mode'] as String? ?? 'strict',
    generalInstructions: j['general_instructions'] as String? ?? '',
    sections: [
      for (final s in j['sections'] as List)
        TemplateSection.fromJson(s as Json),
    ],
  );
  String? validate() {
    if (name.trim().isEmpty || name.trim().runes.length > 200) {
      return 'Укажите название: от 1 до 200 символов.';
    }
    if (description.runes.length > 2000 ||
        generalInstructions.runes.length > 8000) {
      return 'Сократите описание или общие инструкции.';
    }
    if (!['strict', 'flexible'].contains(structureMode)) {
      return 'Выберите режим структуры.';
    }
    if (sections.isEmpty || sections.length > 20) {
      return 'Добавьте от 1 до 20 разделов.';
    }
    final ids = <String>{};
    var count = 0;
    String? check(TemplateSection s, {bool nested = false}) {
      count++;
      if (!ids.add(s.id)) {
        return 'У разделов должны быть разные идентификаторы.';
      }
      if (s.title.trim().isEmpty ||
          s.title.trim().runes.length > 200 ||
          s.instruction.trim().isEmpty ||
          s.instruction.trim().runes.length > 4000) {
        return 'Заполните название и инструкцию каждого раздела.';
      }
      if (s.repeated) {
        if (nested || s.children.isEmpty || s.children.length > 12) {
          return 'В тематическом блоке нужно от 1 до 12 подразделов.';
        }
        for (final c in s.children) {
          final error = check(c, nested: true);
          if (error != null) return error;
        }
      } else if (s.children.isNotEmpty) {
        return 'Подразделы доступны только в тематическом блоке.';
      }
      return null;
    }

    for (final s in sections) {
      final error = check(s);
      if (error != null) return error;
    }
    return count > 100 ? 'Всего допустимо не более 100 разделов.' : null;
  }
}

class SummaryTemplate {
  const SummaryTemplate({
    required this.id,
    required this.input,
    required this.isSystem,
    required this.isDefault,
  });
  final String id;
  final TemplateInput input;
  final bool isSystem;
  final bool isDefault;
  factory SummaryTemplate.fromJson(Json j) => SummaryTemplate(
    id: j['id'] as String,
    input: TemplateInput.fromJson(j),
    isSystem: j['is_system'] as bool,
    isDefault: j['is_default'] as bool,
  );
}

class TemplatePreview {
  const TemplatePreview({
    required this.id,
    required this.status,
    this.content,
    this.navigation = const [],
    this.error,
  });
  final String id;
  final String status;
  final String? content;
  final List<SummaryHeading> navigation;
  final String? error;
  bool get finished => status == 'ready' || status == 'error';
  factory TemplatePreview.fromJson(Json j) => TemplatePreview(
    id: j['id'] as String,
    status: j['status'] as String,
    content: j['content'] as String?,
    navigation: [
      for (final h in j['navigation'] as List? ?? [])
        SummaryHeading.fromJson(h as Json),
    ],
    error: (j['error'] as Json?)?['message'] as String?,
  );
}
