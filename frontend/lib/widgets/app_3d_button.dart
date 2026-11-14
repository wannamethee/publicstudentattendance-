import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/app_theme.dart';

enum App3DButtonVariant {
  primary,   // Deep Royal Purple (ม่วงเข้ม) with Gold Border & Deep Rim
  gold,      // Rich Royal Gold / Yellow (ทอง/เหลือง) with Amber Rim
  secondary, // Pure White Surface with Gold Outline & Golden Rim
  success,   // Emerald Green with Dark Green Rim
  danger,    // Crimson Red with Dark Red Rim
}

/// A tactile 3D Button with physical elevation and responsive depression on press.
/// ปุ่มกดนูน 3 มิติ เวลากดให้เห็นว่ามีการยุบลงไปตามหลักสรีรศาสตร์และสัมผัสเชิงกายภาพ
class App3DButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget? child;
  final String? label;
  final IconData? icon;
  final App3DButtonVariant variant;
  final double depth;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final bool fullWidth;
  final bool isLoading;

  const App3DButton({
    super.key,
    required this.onPressed,
    this.child,
    this.label,
    this.icon,
    this.variant = App3DButtonVariant.primary,
    this.depth = 3.5,
    this.borderRadius = 10,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
    this.fullWidth = false,
    this.isLoading = false,
  });

  factory App3DButton.primary({
    Key? key,
    required VoidCallback? onPressed,
    Widget? child,
    String? label,
    IconData? icon,
    double depth = 3.5,
    double borderRadius = 10,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
    bool fullWidth = false,
    bool isLoading = false,
  }) => App3DButton(
    key: key,
    onPressed: onPressed,
    label: label,
    icon: icon,
    variant: App3DButtonVariant.primary,
    depth: depth,
    borderRadius: borderRadius,
    padding: padding,
    fullWidth: fullWidth,
    isLoading: isLoading,
    child: child,
  );

  factory App3DButton.gold({
    Key? key,
    required VoidCallback? onPressed,
    Widget? child,
    String? label,
    IconData? icon,
    double depth = 3.5,
    double borderRadius = 10,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
    bool fullWidth = false,
    bool isLoading = false,
  }) => App3DButton(
    key: key,
    onPressed: onPressed,
    label: label,
    icon: icon,
    variant: App3DButtonVariant.gold,
    depth: depth,
    borderRadius: borderRadius,
    padding: padding,
    fullWidth: fullWidth,
    isLoading: isLoading,
    child: child,
  );

  factory App3DButton.secondary({
    Key? key,
    required VoidCallback? onPressed,
    Widget? child,
    String? label,
    IconData? icon,
    double depth = 3.0,
    double borderRadius = 10,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
    bool fullWidth = false,
    bool isLoading = false,
  }) => App3DButton(
    key: key,
    onPressed: onPressed,
    label: label,
    icon: icon,
    variant: App3DButtonVariant.secondary,
    depth: depth,
    borderRadius: borderRadius,
    padding: padding,
    fullWidth: fullWidth,
    isLoading: isLoading,
    child: child,
  );

  factory App3DButton.success({
    Key? key,
    required VoidCallback? onPressed,
    Widget? child,
    String? label,
    IconData? icon,
    double depth = 3.5,
    double borderRadius = 10,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
    bool fullWidth = false,
    bool isLoading = false,
  }) => App3DButton(
    key: key,
    onPressed: onPressed,
    label: label,
    icon: icon,
    variant: App3DButtonVariant.success,
    depth: depth,
    borderRadius: borderRadius,
    padding: padding,
    fullWidth: fullWidth,
    isLoading: isLoading,
    child: child,
  );

  factory App3DButton.danger({
    Key? key,
    required VoidCallback? onPressed,
    Widget? child,
    String? label,
    IconData? icon,
    double depth = 3.5,
    double borderRadius = 10,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
    bool fullWidth = false,
    bool isLoading = false,
  }) => App3DButton(
    key: key,
    onPressed: onPressed,
    label: label,
    icon: icon,
    variant: App3DButtonVariant.danger,
    depth: depth,
    borderRadius: borderRadius,
    padding: padding,
    fullWidth: fullWidth,
    isLoading: isLoading,
    child: child,
  );

  @override
  State<App3DButton> createState() => _App3DButtonState();
}

class _App3DButtonState extends State<App3DButton> {
  bool _isPressed = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.isLoading;

    Color faceColor;
    Color rimColor;
    Color borderColor;
    Color textColor;

    switch (widget.variant) {
      case App3DButtonVariant.primary:
        faceColor = enabled
            ? (_isHovered ? AppColors.purpleLight : AppColors.purplePrimary)
            : Colors.grey.shade400;
        rimColor = enabled ? AppColors.purpleDeeper : Colors.grey.shade500;
        borderColor = enabled ? AppColors.gold : Colors.grey.shade400; // Gold trim!
        textColor = Colors.white;
        break;

      case App3DButtonVariant.gold:
        faceColor = enabled
            ? (_isHovered ? const Color(0xFFFBBF24) : AppColors.yellowDark)
            : Colors.grey.shade400;
        rimColor = enabled ? const Color(0xFF92400E) : Colors.grey.shade500;
        borderColor = enabled ? const Color(0xFFB45309) : Colors.grey.shade400;
        textColor = const Color(0xFF451A03);
        break;

      case App3DButtonVariant.secondary:
        faceColor = enabled
            ? (_isHovered ? const Color(0xFFFFFBEB) : Colors.white)
            : Colors.grey.shade200;
        rimColor = enabled ? AppColors.goldWarm : Colors.grey.shade400;
        borderColor = enabled ? AppColors.gold : Colors.grey.shade300; // Gold outline!
        textColor = AppColors.purplePrimary;
        break;

      case App3DButtonVariant.success:
        faceColor = enabled
            ? (_isHovered ? const Color(0xFF10B981) : const Color(0xFF059669))
            : Colors.grey.shade400;
        rimColor = enabled ? const Color(0xFF064E3B) : Colors.grey.shade500;
        borderColor = enabled ? const Color(0xFF34D399) : Colors.grey.shade400;
        textColor = Colors.white;
        break;

      case App3DButtonVariant.danger:
        faceColor = enabled
            ? (_isHovered ? const Color(0xFFEF4444) : const Color(0xFFDC2626))
            : Colors.grey.shade400;
        rimColor = enabled ? const Color(0xFF7F1D1D) : Colors.grey.shade500;
        borderColor = enabled ? const Color(0xFFF87171) : Colors.grey.shade400;
        textColor = Colors.white;
        break;
    }

    // When pressed, translate downward and collapse the bottom extrusion rim
    final double activeDepth = enabled ? (_isPressed ? 0.8 : widget.depth) : 1.0;
    final double topShift = enabled ? (_isPressed ? (widget.depth - 0.8) : 0.0) : 0.0;

    Widget content;
    if (widget.isLoading) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: textColor),
          ),
          if (widget.label != null) ...[
            const SizedBox(width: 8),
            Text(
              widget.label!,
              style: TextStyle(
                fontFamily: 'Sarabun',
                color: textColor,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ],
      );
    } else if (widget.child != null) {
      content = widget.child!;
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 18, color: textColor),
            const SizedBox(width: 7),
          ],
          if (widget.label != null)
            Text(
              widget.label!,
              style: TextStyle(
                fontFamily: 'Sarabun',
                color: textColor,
                fontWeight: FontWeight.bold,
                fontSize: 14,
                letterSpacing: 0.2,
              ),
            ),
        ],
      );
    }

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (enabled && mounted) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (enabled && mounted) setState(() => _isHovered = false);
      },
      child: Listener(
        onPointerDown: (_) {
          if (enabled && mounted) {
            setState(() => _isPressed = true);
            HapticFeedback.lightImpact();
          }
        },
        onPointerUp: (_) {
          if (enabled && mounted) {
            setState(() => _isPressed = false);
            widget.onPressed?.call();
          }
        },
        onPointerCancel: (_) {
          if (enabled && mounted) setState(() => _isPressed = false);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 60),
          curve: Curves.easeOutQuad,
          margin: EdgeInsets.only(top: topShift),
          width: widget.fullWidth ? double.infinity : null,
          decoration: BoxDecoration(
            color: faceColor,
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(color: borderColor, width: 1.2),
            boxShadow: [
              // Solid 3D extrusion rim (shelf)
              BoxShadow(
                color: rimColor,
                offset: Offset(0, activeDepth),
                blurRadius: 0,
                spreadRadius: 0,
              ),
              // Soft ambient drop shadow underneath
              BoxShadow(
                color: Colors.black.withValues(alpha: enabled ? (_isPressed ? 0.04 : 0.12) : 0.02),
                offset: Offset(0, activeDepth + 1.5),
                blurRadius: 3.5,
                spreadRadius: 0,
              ),
            ],
          ),
          padding: widget.padding,
          child: content,
        ),
      ),
    );
  }
}
