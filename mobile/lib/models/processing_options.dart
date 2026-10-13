import 'api_models.dart';

class ProcessingOptions {
  const ProcessingOptions({
    this.detailLevel = 'normal',
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
  final List<String> focusAreas;
  final String additionalInstructions;
  ProcessingOptions copyWith({
    String? detailLevel,
    List<String>? focusAreas,
    String? additionalInstructions,
  }) => ProcessingOptions(
    detailLevel: detailLevel ?? this.detailLevel,
    focusAreas: List.unmodifiable(focusAreas ?? this.focusAreas),
    additionalInstructions:
        additionalInstructions ?? this.additionalInstructions,
  );
  Json toJson() => {
    'detail_level': detailLevel,
    'focus_areas': [...focusAreas]..sort(),
    'additional_instructions': additionalInstructions
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim(),
  };
  factory ProcessingOptions.fromJson(Json json) => ProcessingOptions(
    detailLevel: json['detail_level'] as String? ?? 'normal',
    focusAreas: ((json['focus_areas'] as List?) ?? []).cast<String>(),
    additionalInstructions: json['additional_instructions'] as String? ?? '',
  );
}
