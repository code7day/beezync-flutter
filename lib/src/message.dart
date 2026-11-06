class BeezyncResult {
  const BeezyncResult({required this.ok, this.statusCode, this.error, this.body});

  final bool ok;
  final int? statusCode;
  final String? error;
  final Map<String, dynamic>? body;

  @override
  String toString() => 'BeezyncResult(ok: $ok, status: $statusCode, error: $error)';
}

class BeezyncMessage {
  const BeezyncMessage({
    this.id,
    this.event,
    this.channel,
    this.title,
    this.body,
    this.data,
    this.ts,
    this.raw = const {},
  });

  final String? id;
  final String? event;
  final String? channel;
  final String? title;
  final String? body;
  final dynamic data;
  final DateTime? ts;
  final Map<String, dynamic> raw;

  bool get isNotification => event == null && (title != null || body != null);

  factory BeezyncMessage.fromJson(Map<String, dynamic> json) {
    final ts = json['ts'];
    return BeezyncMessage(
      id: json['id']?.toString(),
      event: json['event'] as String?,
      channel: json['channel'] as String?,
      title: json['title'] as String?,
      body: json['body'] as String?,
      data: json['data'],
      ts: ts is String ? DateTime.tryParse(ts) : null,
      raw: json,
    );
  }

  @override
  String toString() => 'BeezyncMessage(id: $id, event: $event, channel: $channel)';
}

enum BeezyncConnectionState { disconnected, connecting, connected }

class SubscriptionEvent {
  const SubscriptionEvent(this.channel, {this.error});

  final String channel;
  final String? error;

  bool get ok => error == null;
}
