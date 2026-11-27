typedef AlertMap = Map<String, dynamic>;

class AlertItem {
  final int id;
  final String timestamp;
  final String ip;
  final String type;
  final String desc;
  final String status;
  final String updatedAt;
  final String? assetId;
  final double? latitude;
  final double? longitude;
  final String? reportedBy;

  const AlertItem({
    required this.id,
    required this.timestamp,
    required this.ip,
    required this.type,
    required this.desc,
    required this.status,
    required this.updatedAt,
    this.assetId,
    this.latitude,
    this.longitude,
    this.reportedBy,
  });

  factory AlertItem.fromMap(AlertMap map) {
    final ts = (map['timestamp'] ?? '').toString();
    return AlertItem(
      id: (map['id'] as num).toInt(),
      timestamp: ts,
      ip: (map['ip'] ?? map['source_ip'] ?? 'unknown').toString(),
      type: (map['type'] ?? map['alert_type'] ?? 'UNKNOWN').toString(),
      desc: (map['desc'] ?? map['description'] ?? '').toString(),
      status: (map['status'] ?? 'NEW').toString(),
      updatedAt: (map['updated_at'] ?? ts).toString(),
      assetId: map['asset_id']?.toString(),
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      reportedBy: map['reported_by']?.toString(),
    );
  }

  AlertMap toMap() => {
        'id': id,
        'timestamp': timestamp,
        'ip': ip,
        'type': type,
        'desc': desc,
        'status': status,
        'updated_at': updatedAt,
        'asset_id': assetId,
        'latitude': latitude,
        'longitude': longitude,
        'reported_by': reportedBy,
      };

  AlertItem copyWith({String? status, String? updatedAt}) => AlertItem(
        id: id,
        timestamp: timestamp,
        ip: ip,
        type: type,
        desc: desc,
        status: status ?? this.status,
        updatedAt: updatedAt ?? this.updatedAt,
        assetId: assetId,
        latitude: latitude,
        longitude: longitude,
        reportedBy: reportedBy,
      );
}
