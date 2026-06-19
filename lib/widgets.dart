import 'package:flutter/material.dart';

import 'theme.dart';

/// Translucent status pill for the live views (camera + monitor). A colored dot
/// plus a short label, floating over the video.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.text, this.color = warmSeed});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Round control button for the live-view control bars. Supports a normal tap
/// or press-and-hold (push-to-talk) when [onPressStart]/[onPressEnd] are given.
class LiveControlButton extends StatelessWidget {
  const LiveControlButton({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.onPressStart,
    this.onPressEnd,
    this.active = false,
    this.enabled = true,
    this.big = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onPressStart;
  final VoidCallback? onPressEnd;
  final bool active;
  final bool enabled;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final size = big ? 76.0 : 60.0;
    final bg = active ? warmSeed : Colors.white.withValues(alpha: 0.16);
    final fg = enabled
        ? (active ? Colors.white : Colors.white)
        : Colors.white.withValues(alpha: 0.35);

    final circle = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: enabled ? bg : Colors.white.withValues(alpha: 0.06),
        shape: BoxShape.circle,
        border: Border.all(
          color: active ? warmSeed : Colors.white.withValues(alpha: 0.22),
          width: 1.5,
        ),
      ),
      child: Icon(icon, color: fg, size: big ? 34 : 26),
    );

    // Push-to-talk uses raw pointer events (Listener) instead of tap gestures:
    // a tap recognizer cancels the moment the finger drifts past the touch
    // slop, which would silently cut the mic off mid-sentence on a held button.
    final Widget hit = (onPressStart != null || onPressEnd != null)
        ? Listener(
            onPointerDown: enabled ? (_) => onPressStart?.call() : null,
            onPointerUp: enabled ? (_) => onPressEnd?.call() : null,
            onPointerCancel: enabled ? (_) => onPressEnd?.call() : null,
            child: circle,
          )
        : GestureDetector(onTap: enabled ? onTap : null, child: circle);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        hit,
        const SizedBox(height: 6),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: enabled ? 0.85 : 0.4),
                fontSize: 12,
                fontWeight: FontWeight.w500)),
      ],
    );
  }
}

/// The rounded translucent bar that holds a row of [LiveControlButton]s.
class ControlBar extends StatelessWidget {
  const ControlBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // mainAxisSize.min + explicit gaps: the bar hugs its buttons (centered by
    // the caller) so it never overflows on a narrow phone, and the same widget
    // works compact in a corner.
    final spaced = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) spaced.add(const SizedBox(width: 18));
      spaced.add(children[i]);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: spaced),
    );
  }
}
