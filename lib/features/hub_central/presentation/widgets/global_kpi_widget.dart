import 'package:flutter/material.dart';

class GlobalKpiWidget extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;
  const GlobalKpiWidget({super.key, required this.label, required this.value, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color),
      const SizedBox(height: 8),
      Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
    ])),
  );
}
