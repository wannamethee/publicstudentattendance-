import 'package:flutter/material.dart';

/// Form fields side by side (with flex weights) when there is room; stacked full-width on phones
/// so labels and selected values are never cut off.
class ResponsiveFieldsRow extends StatelessWidget {
  final List<Widget> children;
  final List<int> flexes;
  final double spacing;
  final double breakpoint;

  const ResponsiveFieldsRow({
    super.key,
    required this.children,
    required this.flexes,
    this.spacing = 12,
    this.breakpoint = 700,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < breakpoint) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < children.length; i++) ...[
              if (i > 0) SizedBox(height: spacing),
              children[i],
            ],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(width: spacing),
            Expanded(flex: i < flexes.length ? flexes[i] : 1, child: children[i]),
          ],
        ],
      );
    });
  }
}
