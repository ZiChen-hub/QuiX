//! 文件元数据模型：与开发案协议中的元数据 JSON 结构一致

class FileMetadata {
  final String fileId;
  final String fileName;
  final int fileSize;
  final int chunkSize;
  final int totalChunks;
  final String hash;
  /// 6 位连接码（阶段五：用于连接鉴权）
  final String code;

  FileMetadata({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.chunkSize,
    required this.totalChunks,
    required this.hash,
    required this.code,
  });

  /// 序列化为 JSON（协议消息体）
  Map<String, dynamic> toJson() => {
        'file_id': fileId,
        'file_name': fileName,
        'file_size': fileSize,
        'chunk_size': chunkSize,
        'total_chunks': totalChunks,
        'hash': hash,
        'code': code,
      };

  /// 从 JSON 反序列化
  factory FileMetadata.fromJson(Map<String, dynamic> json) {
    return FileMetadata(
      fileId: json['file_id'] as String,
      fileName: json['file_name'] as String,
      fileSize: json['file_size'] as int,
      chunkSize: json['chunk_size'] as int,
      totalChunks: json['total_chunks'] as int,
      hash: json['hash'] as String,
      code: json['code'] as String? ?? '',
    );
  }
}
