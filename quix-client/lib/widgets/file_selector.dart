//! 文件选择器：虚线边框卡片

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class FileSelector extends StatelessWidget {
  final String? fileName;
  final int count;
  final VoidCallback onBrowse;
  final VoidCallback onBrowseFolder;

  const FileSelector({
    super.key,
    this.fileName,
    this.count = 0,
    required this.onBrowse,
    required this.onBrowseFolder,
  });

  @override
  Widget build(BuildContext context) {
    final hasFiles = fileName != null;
    final displayName = count > 1 ? '已选择 $count 个文件' : (fileName ?? '点击选择文件');
    return GestureDetector(
      onTap: onBrowse,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withOpacity(0.15),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.folder_outlined, color: Colors.white54, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                displayName,
                style: TextStyle(
                  fontSize: 14,
                  color: hasFiles ? Colors.white : Colors.white.withOpacity(0.4),
                ),
              ),
            ),
            TextButton(
              onPressed: onBrowseFolder,
              child: const Text(
                '文件夹',
                style: TextStyle(color: QxColors.primary),
              ),
            ),
            TextButton(
              onPressed: onBrowse,
              child: const Text(
                '浏览',
                style: TextStyle(color: QxColors.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
