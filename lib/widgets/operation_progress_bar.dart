// lib/widgets/operation_progress_bar.dart
// شريط تقدم سفلي يظهر أثناء تنفيذ العمليات مع النسبة المئوية.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../utils/chunked_task.dart';

class OperationProgressBar extends StatelessWidget {
  final ValueListenable<OperationProgress?> progress;
  final Color? color;

  /// هامش يُطبَّق فقط عندما يكون الشريط ظاهرًا
  final EdgeInsetsGeometry padding;

  const OperationProgressBar({
    super.key,
    required this.progress,
    this.color,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<OperationProgress?>(
      valueListenable: progress,
      builder: (context, p, _) {
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: p == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: padding,
                  child: _ProgressContent(progress: p, color: color),
                ),
        );
      },
    );
  }
}

class _ProgressContent extends StatelessWidget {
  final OperationProgress progress;
  final Color? color;

  const _ProgressContent({required this.progress, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = color ?? cs.primary;
    final fraction = progress.fraction;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.10),
          cs.surfaceContainerHigh,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  progress.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (progress.total > 0) ...[
                Text(
                  '${progress.done}/${progress.total}',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${progress.percent}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: fraction ?? 0),
              duration: const Duration(milliseconds: 180),
              builder: (context, value, _) => LinearProgressIndicator(
                value: fraction == null ? null : value,
                minHeight: 7,
                color: accent,
                backgroundColor: accent.withValues(alpha: 0.16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
