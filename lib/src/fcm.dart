String? bzIdFromData(Map<String, dynamic>? data) {
  if (data == null) return null;
  final v = data['bz_id'];
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}
