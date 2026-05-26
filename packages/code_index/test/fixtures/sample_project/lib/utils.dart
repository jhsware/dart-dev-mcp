/// Utility helpers used by the sample project.
library;

/// Capitalizes the first letter of [input].
String capitalize(String input) {
  if (input.isEmpty) return input;
  return input[0].toUpperCase() + input.substring(1);
}

/// A private helper — should be filtered by layer 4.
String _internalNormalize(String s) => s.trim().toLowerCase();

/// Wraps [_internalNormalize] for public use.
String normalize(String s) => _internalNormalize(s);

final version = '0.0.1';
