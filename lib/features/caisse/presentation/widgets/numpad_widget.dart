import 'package:flutter/material.dart';

class NumpadWidget extends StatelessWidget {
  final Function(String) onInput;
  final VoidCallback onClear;
  final VoidCallback onConfirm;
  const NumpadWidget({super.key, required this.onInput, required this.onClear, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    const keys = ['1','2','3','4','5','6','7','8','9','.',  '0', '⌫'];
    return GridView.count(
      crossAxisCount: 3, shrinkWrap: true, childAspectRatio: 2,
      children: keys.map((k) => TextButton(
        onPressed: () => k == '⌫' ? onClear() : onInput(k),
        child: Text(k, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      )).toList(),
    );
  }
}
