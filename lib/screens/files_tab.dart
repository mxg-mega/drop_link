import 'package:drop_link/widgets/items_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../core/theme.dart';
import '../models/transfer_item.dart';
import '../providers/items_provider.dart';

class FilesTab extends ConsumerStatefulWidget {
  const FilesTab({super.key});

  @override
  ConsumerState<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends ConsumerState<FilesTab> {
  String _filter = "All";

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(itemsProvider);

    // Filter items (we ignore pure text messages in this tab)
    final filtered = items.where((item) {
      if (item.type == ItemType.text) return false;

      if (_filter == "All") return true;
      if (_filter == "Images") return item.type == ItemType.image;
      if (_filter == "Docs") return item.type == ItemType.file;
      if (_filter == "Links") return item.type == ItemType.link;
      return true;
    }).toList();

    return Column(
      children: [
        // ===== Search (visual only for now) =====
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.search, size: 18, color: AppColors.mute),
                const SizedBox(width: 10),
                Text(
                  "Search shared items",
                  style: TextStyle(color: AppColors.mute, fontSize: 14),
                ),
              ],
            ),
          ),
        ),

        // ===== Filter Chips =====
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: ["All", "Images", "Docs", "Links"].map((filter) {
              final isSelected = _filter == filter;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _filter = filter),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? AppColors.ink : AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      filter,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: isSelected ? Colors.white : AppColors.ink,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),

        const SizedBox(height: 16),

        // ===== File List =====
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    "Nothing here yet.\nSend something from the Shelf.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.mute, fontSize: 14),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final item = filtered[index];
                    return _FileTile(item: item);
                  },
                ),
        ),
      ],
    );
  }
}

class _FileTile extends StatelessWidget {
  final TransferItem item;

  const _FileTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final isLaptop = item.from == "laptop";
    final accent = isLaptop ? AppColors.laptop : AppColors.phone;
    final soft = isLaptop ? AppColors.laptopSoft : AppColors.phoneSoft;

    return GestureDetector(
      onTap: () {
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (_) => ItemDetailSheet(item: item),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            // Icon
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: soft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                item.type == ItemType.link
                    ? LucideIcons.link
                    : item.type == ItemType.image
                        ? LucideIcons.image
                        : LucideIcons.fileText,
                size: 22,
                color: accent,
              ),
            ),
            const SizedBox(width: 12),
      
            // Name + info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name ?? item.text ?? "Item",
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (item.size != null && item.size!.isNotEmpty) item.size,
                      isLaptop ? "from laptop" : "from phone",
                      item.time,
                    ].where((e) => e != null).join(" · "),
                    style: TextStyle(fontSize: 12, color: AppColors.mute),
                  ),
                ],
              ),
            ),
      
            // Direction arrow
            Icon(
              isLaptop ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight,
              size: 18,
              color: accent,
            ),
          ],
        ),
      ),
    );
  }
}