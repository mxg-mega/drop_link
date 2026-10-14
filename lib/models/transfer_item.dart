import 'package:flutter/material.dart';

enum ItemType { text, link, file, image }

class TransferItem {
  final String id;
  final String from; // "phone" or "laptop"
  final ItemType type;
  final String? text;
  final String? name;
  final String? size;
  final String time;
  final String? status;
  final List<Color>? tone;

  TransferItem({
    required this.id,
    required this.from,
    required this.type,
    this.text,
    this.name,
    this.size,
    required this.time,
    this.status,
    this.tone,
  });
}