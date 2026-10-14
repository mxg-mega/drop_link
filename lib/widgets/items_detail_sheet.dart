import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_filex/open_filex.dart';
import '../core/theme.dart';
import '../models/transfer_item.dart';
import '../providers/connection_provider.dart';
import '../providers/items_provider.dart';

class ItemDetailSheet extends ConsumerStatefulWidget {
  final TransferItem item;

  const ItemDetailSheet({super.key, required this.item});

  @override
  ConsumerState<ItemDetailSheet> createState() => _ItemDetailSheetState();
}

class _ItemDetailSheetState extends ConsumerState<ItemDetailSheet> {
  bool _isDownloading = false;
  bool _isDeleting = false;
  double _progress = 0;

  Future<void> _download() async {
    if (widget.item.name == null) return;

    setState(() {
      _isDownloading = true;
      _progress = 0;
    });

    try {
      final api = ref.read(apiServiceProvider);
      final path = await api.downloadFile(
        widget.item.name!,
        onProgress: (p) => setState(() => _progress = p),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Downloaded: ${widget.item.name}")),
        );
        await OpenFilex.open(path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Download failed")),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete item?"),
        content: Text("Are you sure you want to delete \"${widget.item.name ?? widget.item.text}\"?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isDeleting = true);

    try {
      await ref.read(itemsProvider.notifier).deleteItem(widget.item.id);

      if (mounted) {
        Navigator.pop(context); // close the sheet
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Item deleted")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Failed to delete")),
        );
      }
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isLaptop = item.from == "laptop";
    final accent = isLaptop ? AppColors.laptop : AppColors.phone;
    final soft = isLaptop ? AppColors.laptopSoft : AppColors.phoneSoft;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // Icon
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: soft,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              item.type == ItemType.link
                  ? LucideIcons.link
                  : LucideIcons.fileText,
              size: 34,
              color: accent,
            ),
          ),
          const SizedBox(height: 16),

          // Name
          Text(
            item.name ?? item.text ?? "Item",
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (item.size != null) item.size,
              isLaptop ? "from laptop" : "from phone",
              item.time,
            ].where((e) => e != null && e.toString().isNotEmpty).join(" · "),
            style: TextStyle(fontSize: 13, color: AppColors.mute),
          ),

          const SizedBox(height: 28),

          // Buttons
          Row(
            children: [
              // Download button
              if (item.type == ItemType.file || item.type == ItemType.image)
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isDownloading || _isDeleting ? null : _download,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.ink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: _isDownloading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(LucideIcons.download, size: 18),
                    label: Text(
                      _isDownloading
                          ? "${(_progress * 100).toStringAsFixed(0)}%"
                          : "Save",
                    ),
                  ),
                ),

              if (item.type == ItemType.file || item.type == ItemType.image)
                const SizedBox(width: 12),

              // Delete button
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isDownloading || _isDeleting ? null : _delete,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: _isDeleting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(LucideIcons.trash2, size: 18),
                  label: Text(_isDeleting ? "Deleting..." : "Delete"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}