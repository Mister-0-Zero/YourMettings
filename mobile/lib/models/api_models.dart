typedef Json = Map<String, dynamic>;

class Folder {
  Folder({
    required this.id,
    required this.name,
    this.parentId,
    this.children = const [],
  });
  final String id;
  final String name;
  final String? parentId;
  final List<Folder> children;
  factory Folder.fromJson(Json json) => Folder(
    id: json['id'] as String,
    name: json['name'] as String,
    parentId: json['parent_id'] as String?,
    children: ((json['children'] as List?) ?? [])
        .map((e) => Folder.fromJson(e as Json))
        .toList(),
  );
}

class FolderEntry {
  const FolderEntry(this.folder, this.depth, this.path);
  final Folder folder;
  final int depth;
  final String path;
}

List<FolderEntry> flattenFolders(
  List<Folder> folders, {
  int depth = 0,
  String parent = '',
}) => [
  for (final folder in folders) ...[
    FolderEntry(
      folder,
      depth,
      parent.isEmpty ? folder.name : '$parent / ${folder.name}',
    ),
    ...flattenFolders(
      folder.children,
      depth: depth + 1,
      parent: parent.isEmpty ? folder.name : '$parent / ${folder.name}',
    ),
  ],
];

class Transcript {
  const Transcript({
    required this.id,
    required this.text,
    required this.isLocked,
  });
  final String id;
  final String text;
  final bool isLocked;
  factory Transcript.fromJson(Json json) => Transcript(
    id: json['id'] as String,
    text: json['text'] as String,
    isLocked: json['is_locked'] as bool,
  );
}

class MeetingSummary {
  const MeetingSummary({
    required this.id,
    required this.transcriptId,
    required this.title,
    required this.content,
    required this.folderIds,
    required this.createdAt,
    required this.updatedAt,
    this.navigation = const [],
    this.templateSnapshot,
    this.version,
    this.generationOptions,
  });
  final String id;
  final String transcriptId;
  final String title;
  final String content;
  final List<String> folderIds;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<SummaryHeading> navigation;
  final Json? templateSnapshot;
  final String? version;
  final Json? generationOptions;
  factory MeetingSummary.fromJson(Json json) => MeetingSummary(
    id: json['id'] as String,
    transcriptId: json['transcript_id'] as String,
    title: json['title'] as String,
    content: json['content'] as String,
    folderIds: (json['folder_ids'] as List).cast<String>(),
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    templateSnapshot: json['template_snapshot'] as Json?,
    version: json['version'] as String?,
    generationOptions: json['generation_options'] as Json?,
    navigation: [
      for (final h in json['navigation'] as List? ?? [])
        SummaryHeading.fromJson(h as Json),
    ],
  );
}

class SummaryPage {
  const SummaryPage(this.items, this.total, this.limit, this.offset);
  final List<MeetingSummary> items;
  final int total;
  final int limit;
  final int offset;
  bool get hasMore => offset + items.length < total;
  factory SummaryPage.fromJson(Json json) => SummaryPage(
    (json['items'] as List)
        .map((e) => MeetingSummary.fromJson(e as Json))
        .toList(),
    json['total'] as int,
    json['limit'] as int,
    json['offset'] as int,
  );
}

enum ProcessingPhase { notStarted, summarizing, ready, error }

class ProcessingStatus {
  const ProcessingStatus({
    required this.transcriptId,
    required this.phase,
    this.summaryId,
    this.errorCode,
    this.errorMessage,
  });
  final String transcriptId;
  final ProcessingPhase phase;
  final String? summaryId;
  final String? errorCode;
  final String? errorMessage;
  factory ProcessingStatus.fromJson(Json json) {
    final phase = switch (json['status']) {
      'not_started' => ProcessingPhase.notStarted,
      'summarizing' => ProcessingPhase.summarizing,
      'ready' => ProcessingPhase.ready,
      'error' => ProcessingPhase.error,
      _ => throw const FormatException('Неизвестный статус обработки.'),
    };
    final error = json['error'] as Json?;
    final summaryId = json['summary_id'] as String?;
    if (phase == ProcessingPhase.ready && summaryId == null) {
      throw const FormatException('Сервер не вернул идентификатор результата.');
    }
    return ProcessingStatus(
      transcriptId: json['transcript_id'] as String,
      phase: phase,
      summaryId: summaryId,
      errorCode: error?['code'] as String?,
      errorMessage: error?['message'] as String?,
    );
  }
}

class SummaryHeading {
  const SummaryHeading({
    required this.id,
    required this.title,
    required this.level,
    required this.headingIndex,
    required this.lineIndex,
  });
  final String id;
  final String title;
  final int level;
  final int headingIndex;
  final int lineIndex;
  factory SummaryHeading.fromJson(Json j) => SummaryHeading(
    id: j['id'] as String,
    title: j['title'] as String,
    level: j['level'] as int,
    headingIndex: j['heading_index'] as int,
    lineIndex: j['line_index'] as int,
  );
}
