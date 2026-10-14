import 'package:drop_link/core/theme.dart';
import 'package:flutter/material.dart';
import '../providers/connection_provider.dart' as connection_provider;

class PulsingConnectionIndicator extends StatefulWidget {
  const PulsingConnectionIndicator({
    super.key,
    required this.child,
    required this.connection,
  });

  final Widget child;
  final connection_provider.LinkState connection;

  @override
  State<PulsingConnectionIndicator> createState() =>
      _PulsingConnectionIndicatorState();
}

class _PulsingConnectionIndicatorState extends State<PulsingConnectionIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(seconds: 2),
  )..repeat(reverse: true);

  late final Animation<double> _animation = Tween<double>(
    begin: 1.0,
    end: 3.0,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.linear));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.connection.isConnected
                    ? AppColors.phone.withValues(alpha: 0.5)
                    : AppColors.danger.withValues(alpha: 0.5),
                blurRadius: _animation.value * 0.5,
                spreadRadius: _animation.value,
              ),
            ],
          ),
          child: widget.child,
        );
      },
      child: widget.child,
    );
  }
}
