import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models.dart';

class ParseDetailScreen extends StatelessWidget {
  final ParsedText item;
  const ParseDetailScreen({super.key, required this.item});

  Future<void> _copy(BuildContext context, List<String> lines) async {
    await Clipboard.setData(ClipboardData(text: lines.join("\n")));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("تم نسخ (${lines.length}) سطرًا")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(item.title)),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            ListTile(
              title: const Text("التاريخ"),
              subtitle: Text(item.createdAt.toString()),
            ),
            const SizedBox(height: 8),
            _Section(
              title: "النص الأصلي",
              child: SelectableText(item.originalText),
              onCopy: () => _copy(context, [item.originalText]),
            ),
            const SizedBox(height: 8),
            _Section(
              title: "الأسطر المختارة (Bubble)",
              child: _Lines(list: item.selectedLines),
              onCopy: () => _copy(context, item.selectedLines),
            ),
            const SizedBox(height: 8),
            _Section(
              title: "النتيجة النهائية (Filter)",
              child: _Lines(list: item.finalLines),
              onCopy: () => _copy(context, item.finalLines),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  final VoidCallback onCopy;

  const _Section({required this.title, required this.child, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(onPressed: onCopy, icon: const Icon(Icons.copy)),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _Lines extends StatelessWidget {
  final List<String> list;
  const _Lines({required this.list});

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) return const Text("— لا يوجد —");
    return Column(
      children: List.generate(list.length, (i) {
        return ListTile(
          leading: CircleAvatar(child: Text("${i + 1}")),
          title: Text(list[i]),
        );
      }),
    );
  }
}
