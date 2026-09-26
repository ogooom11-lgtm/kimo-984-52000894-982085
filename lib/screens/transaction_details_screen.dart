import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../database_service.dart';
import '../models.dart';
import 'transaction_history_screen.dart';
import '../utils/web_saver.dart' as web_saver;
import '../utils/amount_format.dart';

class TransactionDetailsScreen extends StatefulWidget {
  final Account account;
  final dynamic transactionHiveKey;

  const TransactionDetailsScreen({
    super.key,
    required this.account,
    required this.transactionHiveKey,
  });

  @override
  State<TransactionDetailsScreen> createState() =>
      _TransactionDetailsScreenState();
}

class _TransactionDetailsScreenState extends State<TransactionDetailsScreen> {
  final GlobalKey _shotKey = GlobalKey();

  static const double _exportScale = 3.0;
  static const double _maxExportWidth = 900.0;

  bool _busy = false;

  /// نقطة بين كل 3 خانات، والكسور بفاصلة فقط إن وُجدت (250.000 / 1.234,5)
  String _formatAmount(double v) => AmountFormat.display(v);

  String _formatDateTime(DateTime? dt) {
    if (dt == null) return '—';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}  ${two(dt.hour)}:${two(dt.minute)}';
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return '—';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '—';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}';
  }

  String _safeFilePart(String value) {
    final cleaned = value
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    if (cleaned.isEmpty) return 'transaction';
    return cleaned.length > 35 ? cleaned.substring(0, 35) : cleaned;
  }

  String _statusLabel(TransactionStatus s) {
    switch (s) {
      case TransactionStatus.added:
        return 'مضافة';
      case TransactionStatus.received:
        return 'مستلمة';
      case TransactionStatus.cancelled:
        return 'ملغية';
    }
  }

  IconData _statusIcon(TransactionStatus s) {
    switch (s) {
      case TransactionStatus.added:
        return Icons.schedule_rounded;
      case TransactionStatus.received:
        return Icons.verified_rounded;
      case TransactionStatus.cancelled:
        return Icons.cancel_rounded;
    }
  }

  Color _statusColor(BuildContext context, TransactionStatus s) {
    switch (s) {
      case TransactionStatus.added:
        return Colors.blue;
      case TransactionStatus.received:
        return Colors.green;
      case TransactionStatus.cancelled:
        return Colors.red;
    }
  }

  String _movementLabel(TransactionModel tx) =>
      widget.account.type.isCompany && tx.companyMovementType != null
      ? tx.companyMovementType!.label
      : _statusLabel(tx.status);

  IconData _movementIcon(TransactionModel tx) {
    if (widget.account.type.isCompany && tx.companyMovementType != null) {
      if (tx.companyMovementType!.isCancelled) return Icons.cancel_rounded;
      return tx.companyMovementType!.isSent
          ? Icons.call_made_rounded
          : Icons.call_received_rounded;
    }
    return _statusIcon(tx.status);
  }

  Color _movementColor(BuildContext context, TransactionModel tx) {
    if (widget.account.type.isCompany && tx.companyMovementType != null) {
      if (tx.companyMovementType!.isCancelled) return Colors.red;
      return tx.companyMovementType!.isSent ? Colors.deepPurple : Colors.teal;
    }
    return _statusColor(context, tx.status);
  }

  Color _surfaceColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? const Color(0xFF151A22)
        : Colors.white;
  }

  Color _canvasColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? const Color(0xFF0F131B)
        : const Color(0xFFF6F7FB);
  }

  Color _softFill(BuildContext context, Color color) {
    final theme = Theme.of(context);
    return color.withOpacity(theme.brightness == Brightness.dark ? 0.18 : 0.09);
  }

  BoxDecoration _cardDecoration(BuildContext context, {Color? borderColor}) {
    final theme = Theme.of(context);
    final baseBorder = borderColor ?? theme.dividerColor.withOpacity(0.14);

    return BoxDecoration(
      color: _surfaceColor(context),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: baseBorder),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(
            theme.brightness == Brightness.dark ? 0.18 : 0.05,
          ),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    );
  }

  Future<Uint8List?> _capturePng() async {
    try {
      await Future.delayed(const Duration(milliseconds: 180));
      if (mounted) {
        WidgetsBinding.instance.handleBeginFrame(Duration.zero);
        WidgetsBinding.instance.handleDrawFrame();
      }
      await Future.delayed(const Duration(milliseconds: 120));

      final ctx = _shotKey.currentContext;
      if (ctx == null) {
        debugPrint('⚠️ Context null');
        return null;
      }

      final ro = ctx.findRenderObject();
      if (ro is! RenderRepaintBoundary) {
        debugPrint('⚠️ RenderObject ليس RepaintBoundary');
        return null;
      }

      final image = await ro.toImage(pixelRatio: _exportScale);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) {
        debugPrint('⚠️ لم يتم إنشاء أي بايت من الصورة');
        return null;
      }
      return bytes;
    } catch (e, st) {
      debugPrint('❌ capturePng error: $e\n$st');
      return null;
    }
  }

  Future<String?> _saveImageToDownloads({
    required Uint8List bytes,
    required String filenameBase,
  }) async {
    try {
      if (kIsWeb) {
        await web_saver.saveBytes(
          filename: '$filenameBase.png',
          bytes: bytes,
          mimeType: 'image/png',
        );
        return '$filenameBase.png';
      }

      if (Platform.isAndroid) {
        PermissionStatus status = await Permission.storage.request();

        if (!status.isGranted) {
          status = await Permission.manageExternalStorage.request();
        }

        if (!status.isGranted) {
          return null;
        }

        final downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          await downloadsDir.create(recursive: true);
        }

        final file = File('${downloadsDir.path}/$filenameBase.png');
        await file.writeAsBytes(bytes, flush: true);
        return file.path;
      }

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$filenameBase.png');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e, st) {
      debugPrint('❌ saveImageToDownloads error: $e\n$st');
      return null;
    }
  }

  Future<void> _saveAndMaybeShare({
    required TransactionModel tx,
    required bool alsoShare,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);

    void showSnack(String msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }

    try {
      final png = await _capturePng();
      if (png == null) {
        showSnack('تعذّر إنشاء الصورة');
        return;
      }

      final ts = DateTime.now().millisecondsSinceEpoch;
      final filenameBase = 'transaction_${_safeFilePart(tx.beneficiary)}_$ts';

      final savedPath = await _saveImageToDownloads(
        bytes: png,
        filenameBase: filenameBase,
      );

      if (savedPath == null) {
        try {
          if (kIsWeb) {
            await web_saver.saveBytes(
              filename: '$filenameBase.png',
              bytes: png,
              mimeType: 'image/png',
            );
          } else {
            await FileSaver.instance.saveFile(
              name: filenameBase,
              bytes: png,
              ext: 'png',
              mimeType: MimeType.png,
            );
          }
          showSnack('✅ تم حفظ الصورة');
        } catch (e) {
          showSnack('❌ فشل الحفظ: $e');
          return;
        }
      } else {
        showSnack('✅ تم حفظ الصورة في التنزيلات');
      }

      if (alsoShare) {
        try {
          final dir = await getTemporaryDirectory();
          final f = File('${dir.path}/$filenameBase.png');
          await f.writeAsBytes(png, flush: true);

          await Share.shareXFiles([
            XFile(f.path, mimeType: 'image/png', name: '$filenameBase.png'),
          ]);
        } catch (e, st) {
          debugPrint('❌ Share error: $e\n$st');
          showSnack('تم الحفظ لكن فشلت المشاركة: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildHeaderCard(BuildContext context, TransactionModel tx) {
    final theme = Theme.of(context);
    final statusColor = _movementColor(context, tx);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration(
        context,
        borderColor: statusColor.withOpacity(0.18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: _softFill(context, statusColor),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.person_outline_rounded,
                  color: statusColor,
                  size: 28,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tx.beneficiary,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _buildStatusChip(
                context,
                icon: _movementIcon(tx),
                label: _movementLabel(tx),
                color: statusColor,
              ),
              _buildStatusChip(
                context,
                icon: Icons.assured_workload,
                label: widget.account.name,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
  }) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _softFill(context, color),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmountCard(
    BuildContext context, {
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    required double width,
  }) {
    final theme = Theme.of(context);

    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: _cardDecoration(
          context,
          borderColor: color.withOpacity(0.16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _softFill(context, color),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.textTheme.bodySmall?.color?.withOpacity(0.72),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoBubble(
    BuildContext context, {
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _softFill(context, color),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withOpacity(0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.textTheme.bodySmall?.color?.withOpacity(0.72),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateTimePart(
    BuildContext context, {
    required IconData icon,
    required String value,
    required Color color,
  }) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: _surfaceColor(
          context,
        ).withOpacity(theme.brightness == Brightness.dark ? 0.36 : 0.72),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.13)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateTimeBubble(
    BuildContext context, {
    required String title,
    required DateTime? value,
    required IconData icon,
    required Color color,
    required double width,
  }) {
    final theme = Theme.of(context);

    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: _softFill(context, color),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withOpacity(0.16)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(icon, color: color, size: 21),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.textTheme.bodySmall?.color?.withOpacity(
                        0.76,
                      ),
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildDateTimePart(
                  context,
                  icon: Icons.calendar_month_rounded,
                  value: _formatDate(value),
                  color: color,
                ),
                _buildDateTimePart(
                  context,
                  icon: Icons.access_time_rounded,
                  value: _formatTime(value),
                  color: color,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildStatusDateBubbles(
    BuildContext context,
    TransactionModel tx,
    double width,
  ) {
    if (widget.account.type.isCompany &&
        tx.companyMovementType?.isCancelled == true) {
      return [
        _buildDateTimeBubble(
          context,
          title: 'تاريخ الإلغاء',
          value: tx.cancelledAt,
          icon: Icons.cancel_rounded,
          color: Colors.red,
          width: width,
        ),
      ];
    }
    switch (tx.status) {
      case TransactionStatus.received:
        return [
          _buildDateTimeBubble(
            context,
            title: 'تاريخ التسليم',
            value: tx.receivedAt,
            icon: Icons.verified_rounded,
            color: Colors.green,
            width: width,
          ),
        ];
      case TransactionStatus.cancelled:
        return [
          _buildDateTimeBubble(
            context,
            title: 'تاريخ الإلغاء',
            value: tx.cancelledAt,
            icon: Icons.cancel_rounded,
            color: Colors.red,
            width: width,
          ),
        ];
      case TransactionStatus.added:
        return const [];
    }
  }

  Widget _buildAddedStatusBubble(BuildContext context, TransactionModel tx) {
    if (widget.account.type.isCompany) return const SizedBox.shrink();
    if (tx.status != TransactionStatus.added) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _buildInfoBubble(
        context,
        title: 'حالة الحركة',
        value: 'الحركة ما زالت مضافة ولم يتم تسليمها أو إلغاؤها بعد',
        icon: Icons.schedule_rounded,
        color: Colors.blue,
      ),
    );
  }

  Widget _buildAmountsSection(BuildContext context, TransactionModel tx) {
    final theme = Theme.of(context);
    final amountCards = <Widget>[];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 430;
        final itemWidth = isWide
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;

        amountCards
          ..clear()
          ..add(
            _buildAmountCard(
              context,
              title: 'المبلغ الأول',
              value: '${_formatAmount(tx.amount)} ${tx.currency}',
              icon: Icons.payments_outlined,
              color: theme.colorScheme.primary,
              width: itemWidth,
            ),
          );

        if (tx.hasSecondAmount) {
          amountCards.add(
            _buildAmountCard(
              context,
              title: 'المبلغ الثاني',
              value: '${_formatAmount(tx.secondAmount!)} ${tx.currency}',
              icon: Icons.payments_outlined,
              color: Colors.deepPurple,
              width: itemWidth,
            ),
          );
        }

        return Wrap(spacing: 12, runSpacing: 12, children: amountCards);
      },
    );
  }

  Widget _buildInfoSection(BuildContext context, TransactionModel tx) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'معلومات الحركة',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final canShowTwoInRow = constraints.maxWidth >= 320;
              final itemWidth = canShowTwoInRow
                  ? (constraints.maxWidth - 12) / 2
                  : constraints.maxWidth;

              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _buildDateTimeBubble(
                    context,
                    title: 'تاريخ إرسال الحركة',
                    value: tx.date,
                    icon: Icons.event_note_rounded,
                    color: theme.colorScheme.primary,
                    width: itemWidth,
                  ),
                  ..._buildStatusDateBubbles(context, tx, itemWidth),
                ],
              );
            },
          ),
          _buildAddedStatusBubble(context, tx),
          if (tx.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildInfoBubble(
              context,
              title: 'ملاحظات',
              value: tx.notes,
              icon: Icons.note_alt_outlined,
              color: Colors.orange,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildExportCard(BuildContext context, TransactionModel tx) {
    final theme = Theme.of(context);
    final statusColor = _movementColor(context, tx);

    return RepaintBoundary(
      key: _shotKey,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: _canvasColor(context),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: statusColor.withOpacity(0.18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(
                theme.brightness == Brightness.dark ? 0.24 : 0.08,
              ),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        padding: const EdgeInsets.all(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _surfaceColor(context),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: theme.dividerColor.withOpacity(0.10)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: _softFill(context, statusColor),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      _movementIcon(tx),
                      color: statusColor,
                      size: 23,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'تفاصيل الحركة',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _buildHeaderCard(context, tx),
              const SizedBox(height: 14),
              _buildAmountsSection(context, tx),
              const SizedBox(height: 14),
              _buildInfoSection(context, tx),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: DatabaseService.transactionsBox.listenable(),
      builder: (context, Box<TransactionModel> box, _) {
        final tx = box.get(widget.transactionHiveKey);

        if (tx == null) {
          return const Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(body: Center(child: Text('الحركة لم تعد موجودة'))),
          );
        }

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('تفاصيل الحركة'),
              centerTitle: true,
              elevation: 0,
              scrolledUnderElevation: 0,
              actions: [
                IconButton(
                  tooltip: 'سجل التعديلات',
                  onPressed: () => openTransactionHistory(context, tx),
                  icon: const Icon(Icons.history_rounded),
                ),
                IconButton(
                  tooltip: _busy ? 'جارٍ الحفظ...' : 'حفظ كصورة',
                  onPressed: _busy
                      ? null
                      : () => _saveAndMaybeShare(tx: tx, alsoShare: false),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded),
                ),
                IconButton(
                  tooltip: _busy ? 'جارٍ التصدير...' : 'حفظ ومشاركة',
                  onPressed: _busy
                      ? null
                      : () => _saveAndMaybeShare(tx: tx, alsoShare: true),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share_rounded),
                ),
              ],
            ),
            body: AbsorbPointer(
              absorbing: _busy,
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _maxExportWidth,
                      ),
                      child: _buildExportCard(context, tx),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
