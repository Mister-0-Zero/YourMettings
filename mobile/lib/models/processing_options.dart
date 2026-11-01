import 'api_models.dart';

class ProcessingOptions {
  const ProcessingOptions({
    this.detailLevel = 'normal',
    this.templateId,
    this.expectedTemplateVersion,
    this.focusAreas = const [],
    this.additionalInstructions = '',
  });
  static const detailLevels = {
    'brief': 'Кратко',
    'normal': 'Стандартно',
    'detailed': 'Подробно',
  };
  static const focusLabels = {
    'tasks': 'Задачи и поручения',
    'owners': 'Ответственные',
    'deadlines': 'Сроки',
    'decisions': 'Принятые решения',
    'risks': 'Риски и проблемы',
    'disagreements': 'Разногласия и открытые вопросы',
  };
  final String detailLevel;
  final String? templateId;
  final String? expectedTemplateVersion;
  final List<String> focusAreas;
  final String additionalInstructions;
  ProcessingOptions copyWith({
    String? detailLevel,
    String? templateId,
    String? expectedTemplateVersion,
    bool useDefaultTemplate = false,
    List<String>? focusAreas,
    String? additionalInstructions,
  }) => ProcessingOptions(
    detailLevel: detailLevel ?? this.detailLevel,
    templateId: useDefaultTemplate ? null : templateId ?? this.templateId,
    expectedTemplateVersion:
        useDefaultTemplate ||
            templateId != null && templateId != this.templateId
        ? expectedTemplateVersion
        : expectedTemplateVersion ?? this.expectedTemplateVersion,
    focusAreas: List.unmodifiable(focusAreas ?? this.focusAreas),
    additionalInstructions:
        additionalInstructions ?? this.additionalInstructions,
  );
  Json toJson() => {
    if (templateId != null) 'template_id': templateId,
    if (expectedTemplateVersion != null)
      'expected_template_version': expectedTemplateVersion,
    'detail_level': detailLevel,
    'focus_areas': [...focusAreas]..sort(),
    'additional_instructions': additionalInstructions
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim(),
  };
  factory ProcessingOptions.fromJson(Json json) => ProcessingOptions(
    templateId: json['template_id'] as String?,
    expectedTemplateVersion: json['expected_template_version'] as String?,
    detailLevel: json['detail_level'] as String? ?? 'normal',
    focusAreas: ((json['focus_areas'] as List?) ?? []).cast<String>(),
    additionalInstructions: json['additional_instructions'] as String? ?? '',
  );
}
