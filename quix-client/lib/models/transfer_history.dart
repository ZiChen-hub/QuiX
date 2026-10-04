//! 传输历史记录模型

class TransferRecord {
  final String fileName;
  final int fileSize;
  final String direction; // '发送' | '接收'
  final DateTime timestamp;
  final String status; // '完成' | '失败' | '中断'
  final String peer; // 对端设备标识（设备名或 IP，空表示未知）
  final String path; // 文件本地路径（用于「打开文件/所在目录」）

  TransferRecord({
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.timestamp,
    required this.status,
    this.peer = '',
    this.path = '',
  });

  Map<String, dynamic> toJson() => {
        'file_name': fileName,
        'file_size': fileSize,
        'direction': direction,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'status': status,
        'peer': peer,
        'path': path,
      };

  factory TransferRecord.fromJson(Map<String, dynamic> json) => TransferRecord(
        fileName: json['file_name'] as String,
        fileSize: json['file_size'] as int,
        direction: json['direction'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
        status: json['status'] as String,
        peer: (json['peer'] as String?) ?? '',
        path: (json['path'] as String?) ?? '',
      );
}
