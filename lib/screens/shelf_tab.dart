import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../core/theme.dart';
import '../models/transfer_item.dart';
import '../providers/items_provider.dart';
import '../providers/connection_provider.dart';

class ShelfTab extends ConsumerStatefulWidget {
  const ShelfTab({super.key});

  @override
  ConsumerState<ShelfTab> createState() => _ShelfTabState();
}

class _ShelfTabState extends ConsumerState<ShelfTab> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _hasInitiallyScrolled = false;

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final maxScroll = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          maxScroll,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(maxScroll);
      }
    });
  }

  void _send() {
    final text = _textController.text.trim();
    debugPrint('[ShelfTab] _send() invoked with text: "$text"');
    if (text.isEmpty) {
      debugPrint('[ShelfTab] _send() ignored because text is empty');
      return;
    }

    debugPrint('[ShelfTab] Calling itemsProvider.notifier.sendText("$text")');
    ref.read(itemsProvider.notifier).sendText(text);
    _textController.clear();
    setState(() {});
    _scrollToBottom(animate: true);
  }

  @override
  Widget build(BuildContext context) {
    // Listen for new incoming or outgoing items to auto-scroll to the end
    ref.listen<List<TransferItem>>(itemsProvider, (previous, next) {
      final prevCount = previous?.length ?? 0;
      if (next.length > prevCount) {
        debugPrint(
          '[ShelfTab] New items detected ($prevCount -> ${next.length}). Auto-scrolling to bottom.',
        );
        _scrollToBottom(animate: _hasInitiallyScrolled);
        _hasInitiallyScrolled = true;
      }
    });

    final items = ref.watch(itemsProvider);
    final isConnected = ref.watch(connectionProvider).isConnected;

    // Initial scroll to bottom when items are first loaded into the view
    if (items.isNotEmpty && !_hasInitiallyScrolled) {
      _hasInitiallyScrolled = true;
      _scrollToBottom(animate: false);
    }

    debugPrint(
      '[ShelfTab] build() called: isConnected=$isConnected, itemCount=${items.length}',
    );
    if (items.isEmpty) {
      debugPrint(
        '[ShelfTab] items list is empty: showing ${isConnected ? "Send something to your laptop" : "Connect to your laptop first"}',
      );
    } else {
      for (int i = 0; i < items.length; i++) {
        final it = items[i];
        debugPrint(
          '[ShelfTab]   [#$i] id=${it.id}, from=${it.from}, type=${it.type}, text="${it.text}", name="${it.name}", size="${it.size}", time="${it.time}", status=${it.status}',
        );
      }
    }

    return Column(
      children: [
        // Offline Banner
        if (!isConnected)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppColors.mute.withValues(alpha: 0.1),
            child: Row(
              children: [
                Icon(LucideIcons.wifiOff, size: 16, color: AppColors.mute),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Offline, showing saved history. New items send automatically when the laptop is reachable.',
                    style: TextStyle(fontSize: 12, color: AppColors.mute),
                  ),
                ),
              ],
            ),
          ),

        // ===== Messages List =====
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text(
                    isConnected
                        ? "Send something to your laptop"
                        : "Connect to your laptop first",
                    style: TextStyle(color: AppColors.mute),
                  ),
                )
              : RefreshIndicator.adaptive(
                  onRefresh: () async {
                    debugPrint('[ShelfTab] Pull-to-refresh triggered');
                  },
                  child: ListView.builder(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _ItemCard(item: items[index]),
                      );
                    },
                  ),
                ),
        ),

        // ===== Input Bar =====
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          color: AppColors.bg,
          child: Row(
            children: [
              // Attach button
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  onPressed: () async {
                    debugPrint(
                      '[ShelfTab] Attach button pressed: opening file picker...',
                    );
                    final result = await FilePickerPlatform.instance
                        .pickFiles();

                    if (result == null || result.isEmpty) {
                      debugPrint(
                        '[ShelfTab] File picker canceled or no file selected',
                      );
                      return;
                    }

                    final files = result;
                    debugPrint('[ShelfTab] ${files.length} file(s) selected');
                    final notifier = ref.read(itemsProvider.notifier);
                    for (var index = 0; index < files.length; index++) {
                      final file = files[index];
                      final path = file.path;
                      if (path == null || path.isEmpty) {
                        debugPrint(
                          '[ShelfTab] Skipping file without a local path: ${file.name}',
                        );
                        continue;
                      }

                      int sizeBytes = await file.length() ?? 0;

                      debugPrint(
                        '[ShelfTab] Sending file ${index + 1}/${files.length}: name=${file.name}, sizeBytes=${sizeBytes}, path=$path',
                      );

                      await notifier.sendFile(path, file.name, sizeBytes);
                      _scrollToBottom(animate: true);

                      // Pace queued files and wait for each send to finish before starting the next.
                      if (index < files.length - 1) {
                        await Future<void>.delayed(
                          const Duration(milliseconds: 200),
                        );
                      }
                    }
                  },
                  icon: const Icon(LucideIcons.paperclip, size: 20),
                ),
              ),
              const SizedBox(width: 8),

              // Text field
              Expanded(
                child: TextField(
                  controller: _textController,
                  style: const TextStyle(fontSize: 15),
                  onChanged: (_) => setState(() {}),
                  onTap: () {
                    Future.delayed(
                      const Duration(milliseconds: 300),
                      () => _scrollToBottom(animate: true),
                    );
                  },
                  decoration: InputDecoration(
                    hintText: "Send text or a link to laptop",
                    hintStyle: TextStyle(color: AppColors.mute),
                    filled: true,
                    fillColor: AppColors.surface,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),

              // Send button
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _textController.text.trim().isEmpty
                      ? AppColors.line
                      : AppColors.phone,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  onPressed: _send,
                  icon: const Icon(
                    LucideIcons.send,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ===== Item Card Widget =====
class _ItemCard extends StatelessWidget {
  final TransferItem item;

  const _ItemCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final isMine = item.from == "phone";
    final accent = isMine ? AppColors.phone : AppColors.laptop;
    final soft = isMine ? AppColors.phoneSoft : AppColors.laptopSoft;
    final statusText = _getStatusText(item.status);

    debugPrint(
      '[ShelfTab._ItemCard] Rendering card: id=${item.id}, from=${item.from}, isMine=$isMine, type=${item.type}, text="${item.text}", name="${item.name}", size="${item.size}", time="${item.time}", status=${item.status} (statusIcon="$statusText")',
    );

    return Column(
      crossAxisAlignment: isMine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        // Origin + time + status
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isMine) ...[
              _OriginBadge(from: item.from),
              const SizedBox(width: 6),
            ],
            Text(
              "${isMine ? 'Phone' : 'Laptop'} · ${item.time}"
              "${_getStatusText(item.status)}",
              style: TextStyle(fontSize: 11, color: AppColors.mute),
            ),
            if (isMine) ...[
              const SizedBox(width: 6),
              _OriginBadge(from: item.from),
            ],
          ],
        ),
        const SizedBox(height: 4),

        // Bubble
        Container(
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(isMine ? 18 : 4),
              topRight: Radius.circular(isMine ? 4 : 18),
              bottomLeft: const Radius.circular(18),
              bottomRight: const Radius.circular(18),
            ),
            border: Border(top: BorderSide(color: accent, width: 3)),
          ),
          child: item.type == ItemType.text || item.type == ItemType.link
              ? SelectableText(
                  item.text ?? "",
                  style: TextStyle(
                    fontSize: 15,
                    color: item.type == ItemType.link ? accent : AppColors.ink,
                    decoration: item.type == ItemType.link
                        ? TextDecoration.underline
                        : null,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: soft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        LucideIcons.fileText,
                        size: 20,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name ?? "File",
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            item.size ?? "",
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.mute,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  String _getStatusText(String? status) {
    if (status == null || status == 'synced') return '';
    if (status == 'queued') return ' · ⏱️';
    if (status == 'sending') return ' · ⏳';
    if (status == 'failed') return ' · ⚠️';
    return '';
  }
}

class _OriginBadge extends StatelessWidget {
  final String from;

  const _OriginBadge({required this.from});

  @override
  Widget build(BuildContext context) {
    final isLaptop = from == "laptop";
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: isLaptop ? AppColors.laptopSoft : AppColors.phoneSoft,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        isLaptop ? LucideIcons.laptop : LucideIcons.smartphone,
        size: 13,
        color: isLaptop ? AppColors.laptop : AppColors.phone,
      ),
    );
  }
}
